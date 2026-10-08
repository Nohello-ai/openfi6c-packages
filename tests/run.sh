#!/bin/sh
#
# OpenFi 6C 包仓库 —— 测试总入口
#
#   sh tests/run.sh            跑全部
#   sh tests/run.sh at-lock    只跑某一组
#
# 设计原则：**不需要真设备**。所有跟硬件相关的调用都打桩，
# 这样在 GitHub Actions 的容器里就能跑，不用插一块 OpenFi 6C。
#
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ONLY="${1:-}"

TOTAL_FAIL=0
RAN=0

for t in "$HERE"/test-*.sh; do
	[ -f "$t" ] || continue
	name="$(basename "$t" .sh)"
	name="${name#test-}"

	if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then
		continue
	fi

	printf '\n══════ %s ══════\n' "$name"
	sh "$t"
	rc=$?
	RAN=$((RAN + 1))
	[ "$rc" -eq 0 ] || TOTAL_FAIL=$((TOTAL_FAIL + 1))
done

printf '\n════════════════════════════\n'
if [ "$RAN" -eq 0 ]; then
	echo "没有跑到任何测试"
	exit 1
fi
if [ "$TOTAL_FAIL" -eq 0 ]; then
	printf '全部通过（%d 组）\n' "$RAN"
	exit 0
fi
printf '有 %d/%d 组失败\n' "$TOTAL_FAIL" "$RAN"
exit 1
