#!/bin/sh
#
# OpenFi 6C —— 5G 模块 AT 串口公共函数库
#
# 由 openfi-modem-info / openfi-modem-switch 用
#     . /usr/lib/openfi-modem/at.sh
# 加载。两份脚本共用一套端口探测和收发逻辑，避免各写一份。
#
# ── 串口读法（重要，别改回去）────────────────────────────────
#   stty 设成 min 0 time N 之后，串口空闲 N×0.1 秒时 read() 返回 0，
#   cat 把它当 EOF 自然退出。所以 `timeout 2 cat /dev/ttyUSBx` 就够，
#   不需要「后台 cat + sleep + kill」那种会漏数据、可能留僵尸进程的写法。
#
# ── 只读原则 ────────────────────────────────────────────────
#   本库只负责收发，不决定发什么。查询脚本只发 ATxxx? 这类只读指令。
#
# 依赖：busybox 的 stty / timeout / cat / sed / grep / awk / tr。

# 自动探测出来的 / 显式指定的 AT 口
AT_PORT=""
AT_BAUD=""
AT_ERR=""

# ------------------------------------------------------------------ 小工具
omod_uci() {
	uci -q get "$1" 2>/dev/null
}

omod_json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r'
}

# ------------------------------------------------------------------ 找 AT 口
# 1) 用户用 uci 指定了就用它
# 2) 按 sysfs 里的接口名找（移远模组的 AT 口一般叫 "Quectel USB AT Port"）
# 3) 退而求其次，按 ttyUSB3..0 的常见顺序试
omod_find_port() {
	local p name

	p="$(omod_uci openfi_modem.modem.at_port)"
	[ -n "$p" ] && [ -c "$p" ] && { echo "$p"; return 0; }

	for p in /sys/class/tty/ttyUSB*; do
		[ -e "$p/device/interface" ] || continue
		name="$(cat "$p/device/interface" 2>/dev/null)"
		case "$name" in
			*"AT Port"*|*"AT port"*)
				echo "/dev/${p##*/}"
				return 0
				;;
		esac
	done

	for p in /dev/ttyUSB3 /dev/ttyUSB2 /dev/ttyUSB1 /dev/ttyUSB0 \
	         /dev/ttyACM1 /dev/ttyACM0; do
		[ -c "$p" ] && { echo "$p"; return 0; }
	done

	return 1
}

# ------------------------------------------------------------------ 打开串口
omod_open() {
	AT_ERR=""

	AT_PORT="${1:-$(omod_find_port)}"
	if [ -z "$AT_PORT" ] || [ ! -c "$AT_PORT" ]; then
		AT_ERR="no_at_port"
		return 1
	fi

	AT_BAUD="$(omod_uci openfi_modem.modem.baud)"
	AT_BAUD="${AT_BAUD:-115200}"

	# 配串口标志。**波特率设不上不算失败** ——
	# 实测(RM500U-CN + option 驱动):这块板子的 USB 串口【拒绝 SET_LINE_CODING】,
	# `stty -F /dev/ttyUSBn 115200` 会报 "unable to perform all requested operations",
	# 只有设成当前值(9600)这种空操作才会"成功"。
	# 但 USB 串口的实际速率跟这个波特率参数无关(走的是 USB 包),收发完全正常,
	# 所以这里逐级降级:带波特率 → 不带波特率 → 换重定向写法,
	# 只要能把 raw/min/time 设上就算成功。
	# (同时也不能因为 stty 整个不存在就放弃 —— 见 omod_read 的 timeout 兜底。)
	if ! stty -F "$AT_PORT" "$AT_BAUD" raw -echo -crtscts min 0 time 5 2>/dev/null; then
		stty -F "$AT_PORT" raw -echo -crtscts min 0 time 5 2>/dev/null ||
		stty "$AT_BAUD" raw -echo -crtscts min 0 time 5 < "$AT_PORT" 2>/dev/null ||
		stty raw -echo -crtscts min 0 time 5 < "$AT_PORT" 2>/dev/null || {
			# 连 raw 都设不上:不判死,继续用默认 termios 收发(可能仍可用)
			AT_ERR="stty_warn"
		}
	fi

	return 0
}

omod_close() {
	return 0
}

# ------------------------------------------------------------------ 收发
omod_write() {
	printf '%s\r' "$1" > "$AT_PORT" 2>/dev/null
}

# 累积读：每轮 timeout 2 秒兜底，串口空闲 0.5 秒 cat 就返回；
# 连续读到空就认为收完了，最多 8 轮。
omod_read() {
	local out="" chunk i=0

	while [ "$i" -lt 8 ]; do
		chunk="$(timeout 2 cat "$AT_PORT" 2>/dev/null)"
		[ -n "$chunk" ] || break
		out="${out}${chunk}
"
		i=$((i + 1))
	done

	printf '%s' "$out"
}

# 一次性把多条只读指令发下去，模块按顺序回。
# 比一条一条发（每条都要等一个空闲超时）快好几倍。
omod_query() {
	local cmd

	for cmd in "$@"; do
		omod_write "$cmd"
	done

	omod_read
}

# ------------------------------------------------------------------ 解析
# 取某条指令的响应段（不含回显行和结尾的 OK/ERROR）。
# 依赖模块回显（ATE1，出厂默认）；回声关掉时返回空，调用方需自行兜底。
#   $1 = 整段原始输出   $2 = 指令原文
omod_sec() {
	printf '%s\n' "$1" | tr -d '\r' | awk -v cmd="$2" '
		$0 == cmd { inside = 1; next }
		inside && ($0 == "OK" || $0 == "ERROR" || $0 ~ /^\+CME ERROR/) { exit }
		inside { print }
	'
}

# 在整段输出里取第一条含指定子串的行（$1 = 原始输出，$2 = 子串，固定串匹配）
omod_line() {
	printf '%s\n' "$1" | tr -d '\r' | grep -F "$2" | head -1
}

# 在整段输出里取第一条匹配正则的行
omod_line_re() {
	printf '%s\n' "$1" | tr -d '\r' | grep -E "$2" | head -1
}

# 取 +XXX: 之后的内容
omod_after_colon() {
	printf '%s' "$1" | sed 's/.*:[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

# 取字符串里第一个整数（可带负号）
omod_first_int() {
	printf '%s' "$1" | grep -oE '\-?[0-9]+' | head -1
}
