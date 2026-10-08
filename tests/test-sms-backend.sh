#!/bin/sh
#
# openfi-sms 后端的端到端测试（本地，不碰真机）
#
# 用桩替换 AT 层：omod_query 直接吐出一份「真机 AT+CMGL=4 的原始输出」，
# 这份原始输出由 tests/fixtures/pdus-real.txt 生成（和真机格式一致：
# 回显行 + 每条两行 + OK）。
#
# 这样能验证整条链路：shell 后端 → ucode 解码 → JSON，
# 而完全不接触设备、也不改 SIM 上任何状态。
#
# 没有 ucode 就跳过（CI 里可以不装）。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$HERE/../luci-app-openfi-sms"
FIX="$HERE/fixtures/pdus-real.txt"
FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); }

if ! command -v ucode >/dev/null 2>&1; then
	echo "  ⏭  本机没有 ucode，跳过"
	exit 0
fi
[ -f "$FIX" ] || { echo "  ❌ 找不到夹具 $FIX"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 把夹具变成真机格式的 AT 输出
{
	echo 'AT+CMGL=4'
	while IFS=',' read -r idx st alpha len pdu; do
		[ -z "${idx:-}" ] && continue
		printf '+CMGL: %s,%s,%s,%s\n%s\n' "$idx" "$st" "$alpha" "$len" "$pdu"
	done < "$FIX"
	echo 'OK'
} > "$TMP/raw.txt"

# ── AT 层的桩
cat > "$TMP/at-mock.sh" <<'EOF'
omod_open()  { AT_ERR=""; return 0; }
omod_close() { return 0; }
omod_query() { cat "$MOCK_RAW"; }
EOF

# ── ucode 包装：本地构建的 fs 模块是插件，得加上模块搜索路径
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ucode" <<EOF
#!/bin/sh
# 本地构建的 ucode 模块是插件，得指到它们所在目录；
# 设备上装在 /usr/lib/ucode/，不需要这个。
exec "$(command -v ucode)" -L "$TMP/modules" "\$@"
EOF
chmod 755 "$TMP/bin/ucode"
mkdir -p "$TMP/modules"
# 把 fs.so 软链进去（本地构建产物的位置可能不同，找一下）
for cand in /tmp/ucode-src/build/fs.so /tmp/ucode-src/build/lib/fs.so; do
	[ -f "$cand" ] && ln -sf "$cand" "$TMP/modules/fs.so" && break
done

# ── 跑
export MOCK_RAW="$TMP/raw.txt"
export OPENFI_SMS_AT="$TMP/at-mock.sh"
export OPENFI_SMS_LIB="$PKG/root/usr/lib/openfi-sms"
export OPENFI_SMS_RUNDIR="$TMP"
export PATH="$TMP/bin:$PATH"

OUT="$(sh "$PKG/root/usr/sbin/openfi-sms" list 2>&1)"
printf '%s' "$OUT" > "$TMP/out.json"
if [ -n "${OPENFI_SMS_TEST_DEBUG:-}" ]; then
	echo "  [debug] 后端输出: $(printf '%.200s' "$OUT")"
	echo "  [debug] 包装: $(cat "$TMP/bin/ucode" 2>/dev/null | tail -1)"
	echo "  [debug] modules: $(ls "$TMP/modules" 2>/dev/null | tr '\n' ' ')"
fi

# 1) 必须是合法 JSON
if command -v python3 >/dev/null 2>&1; then
	python3 -c "import json,sys;json.load(open('$TMP/out.json'))" 2>/dev/null \
		&& ok "输出是合法 JSON" || bad "输出不是合法 JSON：$(head -c 120 "$TMP/out.json")"
fi

# 2) 逐项断言
expect() { # $1=描述 $2=python 表达式（可用 d）
	if python3 -c "
import json,sys
d=json.load(open('$TMP/out.json'))
assert $2
" 2>/dev/null; then
		ok "$1"
	else
		bad "$1"
	fi
}

expect "没有 error 字段" "d.get('error','')==''"
expect "解出 4 条（5 个样本里 #2/#3 是同一长短信的两段，拼成一条）" "len(d['messages'])==4"
expect "发件人有 10086" "any(m['sender']=='10086' for m in d['messages'])"
expect "长短信被拼起来了（含 80% 提醒开头）" \
	"any('区域流量使用80%提醒' in m['body'] for m in d['messages'])"
expect "拼接信息带在消息上" "any(m.get('parts',{}).get('total',0)>1 for m in d['messages'])"
expect "UCS2 中文没乱码" "any('中国移动' in m['body'] for m in d['messages'])"
expect "时间戳是 UTC+08:00" "all(m['time'].endswith('UTC+08:00') for m in d['messages'])"
expect "最新的排在最前面" "d['messages'][0]['idx'] == max(m['idx'] for m in d['messages'])"

# 3) 没接 AT 口时的错误路径（单独起一个进程，避免引号嵌套）
cat > "$TMP/err-mock.sh" <<'EOF'
omod_open()  { AT_ERR=no_at_port; return 1; }
omod_close() { return 0; }
omod_query() { return 1; }
EOF
ERR_OUT="$(MOCK_RAW="$TMP/raw.txt" OPENFI_SMS_AT="$TMP/err-mock.sh" \
	OPENFI_SMS_LIB="$PKG/root/usr/lib/openfi-sms" OPENFI_SMS_RUNDIR="$TMP" \
	sh "$PKG/root/usr/sbin/openfi-sms" list 2>&1)"
case "$ERR_OUT" in
	*no_at_port*) ok "AT 打不开时返回 error 而不是崩" ;;
	*)            bad "错误路径不对：$(printf '%.80s' "$ERR_OUT")" ;;
esac

echo
if [ "$FAIL" -eq 0 ]; then echo "  SMS 后端：全部通过"; exit 0; fi
echo "  SMS 后端：$FAIL 项失败"; exit 1
