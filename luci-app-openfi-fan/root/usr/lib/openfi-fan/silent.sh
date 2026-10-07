#!/bin/sh
#
# OpenFi 6C 物理开关(pio 0)与「静默模式」的共用逻辑。
#
# 背景:
#   * 设备上那个拨动开关接在 pio 0,设备树里是 gpio-keys 的 func 节点,
#     linux,code = <KEY_CONFIG>。
#   * gpio-button-hotplug 用 keycode 查内置映射表:KEY_CONFIG → "config",
#     于是 procd 会执行 /etc/rc.button/config —— 注意**不是**按设备树里的
#     label 取名(label 叫 func,只影响 debugfs 里显示的名字)。
#   * 所以事件入口固定是 /etc/rc.button/config,跟 label 无关。
#
# 「静默模式」= 风扇停转 + 四盏状态灯全灭。
# 状态不写 UCI,只用一个运行时标志文件 /var/run/openfi-silent,
# 因此拨回正常档会自动恢复用户原本保存的风扇曲线与灯光设置。

# 开关哪一档算「静默」:1 = 高电平档,0 = 低电平档。
# 取值优先级:环境变量 > UCI openfi.fan.silent_when_hi > 默认 1。
# 厂商 op_switch.sh 的注释写的是 "swich low: led on...; high: led off..."，
# 即高电平对应「关灯」那一档,故默认取 1。
if [ -z "$OPENFI_SILENT_WHEN_HI" ]; then
	OPENFI_SILENT_WHEN_HI=$(uci -q get openfi.fan.silent_when_hi 2>/dev/null)
	case "$OPENFI_SILENT_WHEN_HI" in
		0|1) ;;
		*)   OPENFI_SILENT_WHEN_HI=1 ;;
	esac
fi

OPENFI_GPIO_DBG=${OPENFI_GPIO_DBG:-/sys/kernel/debug/gpio}
OPENFI_SILENT_FLAG=${OPENFI_SILENT_FLAG:-/var/run/openfi-silent}

# 安全兜底:静默模式下 CPU 温度达到该值就强制把风扇打开,避免过热。
OPENFI_SILENT_MAX_TEMP=${OPENFI_SILENT_MAX_TEMP:-75}

# 读物理开关电平,输出 hi / lo / unknown
openfi_switch_level() {
	[ -r "$OPENFI_GPIO_DBG" ] || { echo unknown; return; }

	# debugfs 里那一行长这样:
	#  gpio-455 (                    |func                ) in  hi IRQ
	local line
	line=$(grep -E '\|[[:space:]]*func[[:space:]]*\)' "$OPENFI_GPIO_DBG" 2>/dev/null | head -1)
	[ -n "$line" ] || { echo unknown; return; }

	case "$line" in
		*" hi "*) echo hi ;;
		*" lo "*) echo lo ;;
		*)        echo unknown ;;
	esac
}

# 开关是否处于静默档:输出 1 / 0 / 2(2 = 读不到)
openfi_switch_silent() {
	local lvl
	lvl=$(openfi_switch_level)

	case "$lvl" in
		hi) [ "$OPENFI_SILENT_WHEN_HI" = "1" ] && echo 1 || echo 0 ;;
		lo) [ "$OPENFI_SILENT_WHEN_HI" = "1" ] && echo 0 || echo 1 ;;
		*)  echo 2 ;;
	esac
}

openfi_silent_active() {
	[ -e "$OPENFI_SILENT_FLAG" ]
}

openfi_silent_set() {
	if [ "$1" = "1" ]; then
		: > "$OPENFI_SILENT_FLAG"
	else
		rm -f "$OPENFI_SILENT_FLAG"
	fi
}

# 按物理开关同步运行时标志;有变化返回 0,没变化返回 1。
# 读不到开关电平(unknown)时保持现状,不动标志。
openfi_silent_sync() {
	local was=0 now
	openfi_silent_active && was=1

	now=$(openfi_switch_silent)
	[ "$now" = "2" ] && return 1

	openfi_silent_set "$now"
	[ "$was" != "$now" ]
}

# 读某个热区温度(℃,整数);读不到输出空
openfi_read_temp() {
	local f="${1:-/sys/class/thermal/thermal_zone0/temp}"
	[ -r "$f" ] || return 1
	awk '$1 ~ /^[0-9]+$/ && $1 <= 150000 {printf "%d\n", $1/1000}' "$f" 2>/dev/null
}
