#!/bin/sh
#
# 回归测试：openfi-modem-link 必须【按驱动】找蜂窝网卡，不能按名字猜。
#
# 为什么必须有：
#   原来那段的兜底是
#       ls /sys/class/net | grep -E '^(usb|wwan|eth)[0-9]+$' | head -1
#   这台机器上 /sys/class/net 里同时有：
#       eth0 —— gmac0，一条没接线的 2.5G 固定链路（永远零流量）
#       eth1 —— LAN
#       usb0 —— 模组的 RNDIS 数据口
#   按字母序 head -1 会选中 eth0，于是"模组流量"读到的是那个死口。
#
#   另外 proto mbim 时 uci 里的 device 是字符设备 /dev/cdc-wdmN，
#   拿去 /sys/class/net 下面找必然找不到，也会掉进同一个坑。
#
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
F="${OPENFI_MODEM_LINK:-$HERE/../luci-app-openfi-modem/root/usr/sbin/openfi-modem-link}"
[ -f "$F" ] || { echo "找不到 $F"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/net" "$T/drivers/mtk_eth" "$T/drivers/rndis_host" "$T/drivers/cdc_ncm"

# eth0 = 没接线的 2.5G 固定链路（名字排在 usb0 前面，专门用来验证不被误选）
# usb0 = RNDIS 数据口；wwan0 = NCM/MBIM 数据口
for n in eth0 eth1 usb0 wwan0; do
	mkdir -p "$T/net/$n/device" "$T/net/$n/statistics"
	echo 0 > "$T/net/$n/statistics/rx_bytes"
	echo 0 > "$T/net/$n/statistics/tx_bytes"
done
ln -sf "$T/drivers/mtk_eth"    "$T/net/eth0/device/driver"
ln -sf "$T/drivers/rndis_host" "$T/net/usb0/device/driver"
ln -sf "$T/drivers/cdc_ncm"    "$T/net/wwan0/device/driver"

# 抽出被测的那段（脚本其余部分依赖 uci/jsonfilter，测试环境里没有）
{
	printf '%s\n' 'uci() { return 1; }'      # 让 uci 查不到 → 走兜底分支
	sed -n '/^DEV="\$(uci -q get network.wan.device/,/^\[ -n "\$DEV" \] || DEV="usb0"/p' "$F"
	echo 'echo "$DEV"'
} > "$T/probe.sh"

sh -n "$T/probe.sh" 2>/dev/null || { bad "抽出的探测段语法错误"; exit 1; }
ok "抽出的探测段语法正常"

# ---------- 1. eth0/usb0/wwan0 并存时，必须选中模组的网卡 ----------
got="$(OPENFI_SYSFS_NET="$T/net" sh "$T/probe.sh" 2>/dev/null | tail -1)"
case "$got" in
	usb0|wwan0) ok "并存场景选中了模组网卡：$got（没被 eth0 抢走）" ;;
	eth0)       bad "选中了 eth0 —— 就是那个永远零流量的 2.5G 口（旧写法的 bug）" ;;
	*)          bad "选中了意料之外的 '$got'" ;;
esac

# ---------- 2. 只要 eth*，必须退回 usb0 兜底而不是选 eth ----------
rm -f "$T/net/usb0/device/driver" "$T/net/wwan0/device/driver"
got="$(OPENFI_SYSFS_NET="$T/net" sh "$T/probe.sh" 2>/dev/null | tail -1)"
if [ "$got" = "usb0" ]; then
	ok "没有蜂窝驱动时退回 usb0 兜底"
else
	bad "没有蜂窝驱动时选中了 '$got'，应该是 usb0 兜底"
fi

# ---------- 3. 关键：绝不能返回 eth0 ----------
if [ "$got" = "eth0" ]; then
	bad "兜底落到了 eth0 —— 会把 LAN/死口当成 WAN 统计"
else
	ok "兜底没有落到 eth0"
fi

# ---------- 4. uci 里是字符设备（MBIM）时也不能崩 ----------
{
	printf '%s\n' 'uci() { case "$*" in *"network.wan.device") echo "/dev/cdc-wdm0";; *) return 1;; esac; }'
	sed -n '/^DEV="\$(uci -q get network.wan.device/,/^\[ -n "\$DEV" \] || DEV="usb0"/p' "$F"
	echo 'echo "$DEV"'
} > "$T/probe2.sh"
ln -sf "$T/drivers/rndis_host" "$T/net/usb0/device/driver"
got="$(OPENFI_SYSFS_NET="$T/net" sh "$T/probe2.sh" 2>/dev/null | tail -1)"
if [ "$got" = "usb0" ] || [ "$got" = "wwan0" ]; then
	ok "MBIM（uci 里是 /dev/cdc-wdm0）时正确回退到真实网卡：$got"
else
	bad "MBIM 场景返回了 '$got'，应该回退到真实网卡名"
fi

echo
echo "════════════════════════════"
echo "  网卡探测测试：通过 $PASS 项，失败 $FAIL 项"
[ "$FAIL" -eq 0 ] || exit 1
