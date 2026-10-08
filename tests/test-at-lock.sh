#!/bin/sh
#
# AT 串口互斥测试
#
# 背景：一共有 6 个脚本会碰同一根串口（info / link / signal / switch / at / at.sh），
# 之前完全没有加锁 —— 在网页 AT 终端敲指令时，信号守护进程正好轮询，
# 两个进程同时写 /dev/ttyUSB3，指令互相插话、回复串台。
#
# 不需要真设备：用 /dev/null 当假串口（它是字符设备，读写都是空操作）。
# 两个坑（第一版测试就踩了）：
#   1. 端口必须【当参数传】给 omod_open —— 它用 ${1:-$(omod_find_port)} 取值，
#      环境变量 AT_PORT 会被直接覆盖掉。
#   2. 要把 flock 藏起来得用绝对路径 /bin/sh 启动，否则连外层 sh 都找不到了。
#
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../luci-app-openfi-modem/root/usr/lib/openfi-modem/at.sh"
FAKE=/dev/null

[ -f "$LIB" ] || { echo "  ❌ 找不到 $LIB"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
ok()  { printf '  ✅ %s\n' "$1"; }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }

# 一个「没有 flock」的 PATH：把要用的工具软链进去，就是不链 flock
mkdir -p "$TMP/nolock"
for t in sh sleep mkdir rm cat kill basename dirname; do
	p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$TMP/nolock/$t" 2>/dev/null
done

# ─────────────────────────────────────────────── 1. 基本互斥
echo "  -- 基本互斥 --"
L1="$TMP/lock1"; O1="$TMP/o1"
OPENFI_AT_LOCK="$L1" OPENFI_AT_LOCK_WAIT=1 \
	/bin/sh -c ". '$LIB'; omod_open '$FAKE' && { echo A_HELD; sleep 3; }; omod_close" > "$O1" 2>&1 &
BG=$!
sleep 1
OPENFI_AT_LOCK="$L1" OPENFI_AT_LOCK_WAIT=1 \
	/bin/sh -c ". '$LIB'; if omod_open '$FAKE'; then echo B_HELD; else echo B_BUSY:\$AT_ERR; fi" > "$TMP/o1b" 2>&1
wait $BG 2>/dev/null

grep -q A_HELD "$O1" && ok "A 拿到了锁" || bad "A 没拿到锁：$(cat "$O1")"
if grep -q 'B_BUSY:busy' "$TMP/o1b"; then
	ok "A 持锁期间 B 被挡住，且 AT_ERR=busy"
elif grep -q B_HELD "$TMP/o1b"; then
	bad "B 和 A 同时持锁（互斥失败）"
else
	bad "B 的返回不对：$(cat "$TMP/o1b")"
fi

# ─────────────────────────────────────────────── 2. 退出后自动释放
echo "  -- 退出自动释放 --"
L2="$TMP/lock2"; O2="$TMP/o2"
OPENFI_AT_LOCK="$L2" OPENFI_AT_LOCK_WAIT=1 \
	/bin/sh -c ". '$LIB'; omod_open '$FAKE' && echo first_ok" > "$O2" 2>&1
OPENFI_AT_LOCK="$L2" OPENFI_AT_LOCK_WAIT=3 \
	/bin/sh -c ". '$LIB'; omod_open '$FAKE' && echo second_ok || echo second_fail:\$AT_ERR" >> "$O2" 2>&1
grep -q second_ok "$O2" && ok "上个进程退出后锁自动释放" || bad "锁没释放：$(cat "$O2")"

# ─────────────────────────────────────────────── 3. 被 kill 也要释放
echo "  -- 被 kill 也要释放 --"
L3="$TMP/lock3"; O3="$TMP/o3"
OPENFI_AT_LOCK="$L3" OPENFI_AT_LOCK_WAIT=1 \
	/bin/sh -c ". '$LIB'; omod_open '$FAKE' && { echo holder_up; sleep 30; }" > "$O3" 2>&1 &
HP=$!
sleep 1
# 先杀子进程再杀壳：flock 的锁挂在 fd 上，最后一个持有该 fd 的进程退出才释放。
# 真实场景里子进程是 `timeout 2 cat`，最多几秒就退，不会把锁卡住；
# 这里的 sleep 30 是人造的，得连它一起杀才符合「进程树整体消失」的语义。
pkill -9 -P "$HP" 2>/dev/null
kill -9 "$HP" 2>/dev/null
wait "$HP" 2>/dev/null
sleep 1
OPENFI_AT_LOCK="$L3" OPENFI_AT_LOCK_WAIT=3 \
	/bin/sh -c ". '$LIB'; omod_open '$FAKE' && echo after_kill_ok || echo after_kill_fail:\$AT_ERR" >> "$O3" 2>&1
grep -q after_kill_ok "$O3" && ok "持有者（连子进程）被 kill -9 后锁释放" || bad "被 kill 后锁没释放：$(cat "$O3")"

# ─────────────────────────────────────────────── 4. 没有 flock 的 mkdir 退化
echo "  -- 没有 flock 的退化路径 --"
L4="$TMP/lock4"; O4="$TMP/o4"
if PATH="$TMP/nolock" /bin/sh -c 'command -v flock >/dev/null 2>&1'; then
	echo "  ⏭  造不出「没有 flock」的环境，跳过"
else
	PATH="$TMP/nolock" OPENFI_AT_LOCK="$L4" OPENFI_AT_LOCK_WAIT=1 \
		/bin/sh -c ". '$LIB'; omod_open '$FAKE' && { echo mkdir_held; sleep 3; }" > "$O4" 2>&1 &
	MGP=$!
	sleep 1
	PATH="$TMP/nolock" OPENFI_AT_LOCK="$L4" OPENFI_AT_LOCK_WAIT=1 \
		/bin/sh -c ". '$LIB'; if omod_open '$FAKE'; then echo mkdir_second_held; else echo mkdir_second_busy:\$AT_ERR; fi" >> "$O4" 2>&1
	wait $MGP 2>/dev/null
	if grep -q mkdir_second_busy "$O4"; then
		ok "没有 flock 时 mkdir 锁也能互斥"
	elif grep -q mkdir_second_held "$O4"; then
		bad "没有 flock 时互斥失效（两个都拿到了）"
	else
		bad "退化路径返回异常：$(cat "$O4")"
	fi
fi

# ─────────────────────────────────────────────── 5. 陈旧 mkdir 锁清理
echo "  -- 陈旧锁清理 --"
L5="$TMP/lock5"; mkdir -p "$L5.d"; echo 999999 > "$L5.d/pid"
O5="$TMP/o5"
PATH="$TMP/nolock" OPENFI_AT_LOCK="$L5" OPENFI_AT_LOCK_WAIT=3 \
	/bin/sh -c ". '$LIB'; omod_open '$FAKE' && echo stale_cleaned || echo stale_stuck:\$AT_ERR" > "$O5" 2>&1
grep -q stale_cleaned "$O5" && ok "持有人已死的陈旧锁被清理，能重新拿到" || bad "陈旧锁把串口锁死了：$(cat "$O5")"

# ─────────────────────────────────────────────── 6. 错误码
echo "  -- 错误码 --"
O6="$TMP/o6"
OPENFI_AT_LOCK="$TMP/lock6" \
	/bin/sh -c ". '$LIB'; omod_open /dev/definitely-not-here || echo err:\$AT_ERR" > "$O6" 2>&1
grep -q 'err:no_at_port' "$O6" && ok "AT 口不存在 → AT_ERR=no_at_port" || bad "错误码不对：$(cat "$O6")"

# ─────────────────────────────────────────────── 7. 单进程正常路径不受影响
echo "  -- 单进程正常路径 --"
O7="$TMP/o7"
OPENFI_AT_LOCK="$TMP/lock7" OPENFI_AT_LOCK_WAIT=2 \
	/bin/sh -c ". '$LIB'; omod_open '$FAKE' && echo single_ok && omod_close && echo closed_ok" > "$O7" 2>&1
if grep -q single_ok "$O7" && grep -q closed_ok "$O7"; then
	ok "单进程 open/close 正常"
else
	bad "单进程路径被影响了：$(cat "$O7")"
fi

echo
if [ "$FAIL" -eq 0 ]; then
	echo "  AT 锁：全部通过"
	exit 0
fi
echo "  AT 锁：$FAIL 项失败"
exit 1
