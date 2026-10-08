#!/bin/sh
#
# SMS PDU 解码回归测试
#
# 夹具 tests/fixtures/pdus-real.txt 是从真机 AT+CMGL=4 抓下来的真实 PDU
# （全是运营商通知，没有隐私内容）。
#
# 覆盖当初踩到的坑：无 UDH 的普通短信 / 有 UDH 的拼接短信 /
# 两种长度单位的地址字段 / UCS2 中文 / 时区的 BCD 十进制 / 十六进制解析。
#
# 说明：PDU 是内联进 ucode 程序的，不走 readfile ——
# 不同 ucode 构建里 fs 模块可能没编进去，内联最稳。
#
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PDU="$HERE/../luci-app-openfi-sms/root/usr/lib/openfi-sms/pdu.uc"
FIX="$HERE/fixtures/pdus-real.txt"
PKG_LIB="$HERE/../luci-app-openfi-sms/root/usr/lib/openfi-sms"
FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

if ! command -v ucode >/dev/null 2>&1; then
	echo "  ⏭  本机没有 ucode，跳过"
	echo "     （想跑的话：从 https://github.com/jow-/ucode 构建，或装发行版包）"
	exit 0
fi
[ -f "$FIX" ] || { echo "  ❌ 找不到夹具 $FIX"; exit 1; }

# 把夹具内联成 ucode 数组
ARR="$(sed 's/.*/"&",/' "$FIX" | sed 's/^/\t/')"
PROG="$(mktemp)"
trap 'rm -f "$PROG"' EXIT
{
  echo "import { decodePdu } from '$PDU';"
  echo "let raw = ["
  printf '%s\n' "$ARR"
  echo "];"
  cat <<'UCEOF'
for (let i = 0; i < length(raw); i++) {
	let f = split(raw[i], ',');
	if (length(f) < 5) continue;
	let m = decodePdu(f[4]);
	print(f[0] + "|" + (m.error ? ("ERR " + m.error) : m.body) + "\n");
}
UCEOF
} > "$PROG"

OUT="$(ucode "$PROG" 2>&1)"
N="$(printf '%s\n' "$OUT" | grep -c '|' || true)"
ERRS="$(printf '%s\n' "$OUT" | grep -c 'ERR ' || true)"

# 先确认真的解出东西了 —— 0 条解出必须算失败（以前这写过假通过）
if [ "$N" -eq 0 ]; then
	bad "一条都没解出来，测试本身有问题"
	printf '%s\n' "$OUT" | head -5 | sed 's/^/      /'
	echo; echo "  PDU：失败"; exit 1
fi

# 逐条抽查关键字
printf '%s\n' '1|303326' '1|中国移动' '2|区域流量使用80%' '2|动感地带' \
               '3|dx.10086.cn' '3|中国移动' '15|238775' '15|验证码' > /tmp/_exp.$$
while IFS='|' read -r idx want; do
	[ -z "$idx" ] && continue
	got="$(printf '%s\n' "$OUT" | grep "^$idx|" | head -1)"
	case "$got" in
		*"$want"*) ok "#$idx 含「$want」" ;;
		*)         bad "#$idx 缺「$want」（实际: $(printf '%.70s' "$got")）" ;;
	esac
done < /tmp/_exp.$$
rm -f /tmp/_exp.$$

# 断言:每条都必须解出非空正文
printf '%s\n' "$OUT" | while IFS='|' read -r idx body; do
	[ -z "$idx" ] && continue
	[ -n "$body" ] || printf '  ❌ #%s 正文为空\n' "$idx"
done

# ── 编码往返：发出去的短信，编码后再解开必须一致（全程本地，不发短信）
ENC="$(ucode -L "$PKG_LIB" -e "
import { encodeSubmit, decodeSubmit } from 'pdu';
let cases = [['13870212951','OpenFi 6C 测试短信'],['10086','hello'],['+8613800138000','中文 mixed 123']];
let bad = 0;
for (let i = 0; i < length(cases); i++) {
	let e = encodeSubmit(cases[i][0], cases[i][1]);
	let d = decodeSubmit(e.pdu);
	if (d.to != cases[i][0] || d.body != cases[i][1]) { print('MISMATCH ' + cases[i][0] + ' -> ' + d.to + ' / ' + d.body); bad++; }
}
print(bad ? ('ENC_FAIL ' + bad) : 'ENC_OK');
" 2>&1)"
case "$ENC" in
	*ENC_OK*) ok "编码→解码 往返一致（中文 / 国际号码 / 短号）" ;;
	*)        bad "编码往返失败：$ENC" ;;
esac


printf '\n  解出 %s 条，解码报错 %s 条\n' "$N" "$ERRS"
[ "$ERRS" -eq 0 ] || FAIL=$((FAIL+1))

echo
[ "$FAIL" -eq 0 ] && { echo "  PDU：全部通过"; exit 0; }
echo "  PDU：$FAIL 项失败"; exit 1
