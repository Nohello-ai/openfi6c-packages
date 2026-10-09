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

# ── 串口互斥（重要）─────────────────────────────────────────
# 一共 6 个脚本会碰这根串口：info / link / signal / switch / at(网页终端)。
# 不加锁的话，你在网页 AT 终端敲指令时，信号守护进程正好轮询，
# 两个进程同时写 /dev/ttyUSB3 → 指令互相插话、回复串台。
# 这里用文件锁串行化，omod_open 拿锁、进程退出自动放锁。
#
# 优先 flock：锁挂在 fd 上，进程无论怎么退出（含被 kill -9）内核都会释放。
#   注意语义：是「最后一个持有该 fd 的进程退出」才释放 —— 子进程会继承 fd，
#   所以极短时间内子进程（timeout 2 cat 这种，本来就几秒退）还活着时锁不放开，
#   这是正常的、也是对的：那会儿串口确实还在被用。
# 没有 flock 就退化成 mkdir 原子锁 + PID 存活检查 + 陈旧锁清理。
OPENFI_AT_LOCK=${OPENFI_AT_LOCK:-/var/run/openfi-at.lock}
OPENFI_AT_LOCK_WAIT=${OPENFI_AT_LOCK_WAIT:-12}
AT_LOCK_FD=9
AT_LOCK_MODE=""

# ------------------------------------------------------------------ 小工具
omod_uci() {
	uci -q get "$1" 2>/dev/null
}

omod_json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r'
}

# ------------------------------------------------------------------ 串口锁
omod_lock() {
	local i=0 p

	# 已经在锁里就不再重复加（同一个 shell 里连续多次 omod_open 的情况）
	[ -n "$AT_LOCK_MODE" ] && return 0

	if command -v flock >/dev/null 2>&1; then
		eval "exec $AT_LOCK_FD>\"\$OPENFI_AT_LOCK\"" 2>/dev/null || {
			AT_LOCK_MODE=""
			return 0			# 连锁文件都开不了：不阻断功能，照旧收发
		}
		while [ "$i" -lt "$OPENFI_AT_LOCK_WAIT" ]; do
			if flock -n -x "$AT_LOCK_FD" 2>/dev/null; then
				AT_LOCK_MODE="flock"
				return 0
			fi
			sleep 1
			i=$((i + 1))
		done
		eval "exec $AT_LOCK_FD>&-" 2>/dev/null
		AT_LOCK_MODE=""
		return 1
	fi

	# 退化路径：mkdir 是原子的
	while [ "$i" -lt "$OPENFI_AT_LOCK_WAIT" ]; do
		if mkdir "$OPENFI_AT_LOCK.d" 2>/dev/null; then
			echo $$ > "$OPENFI_AT_LOCK.d/pid"
			AT_LOCK_MODE="mkdir"
			return 0
		fi
		# 持有人已经死了 → 清掉陈旧锁
		if [ -r "$OPENFI_AT_LOCK.d/pid" ]; then
			p="$(cat "$OPENFI_AT_LOCK.d/pid" 2>/dev/null)"
			if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then
				rm -rf "$OPENFI_AT_LOCK.d" 2>/dev/null
				continue
			fi
		fi
		sleep 1
		i=$((i + 1))
	done
	AT_LOCK_MODE=""
	return 1
}

omod_unlock() {
	case "$AT_LOCK_MODE" in
		mkdir)
			rm -rf "$OPENFI_AT_LOCK.d" 2>/dev/null
			;;
		flock)
			eval "exec $AT_LOCK_FD>&-" 2>/dev/null
			;;
	esac
	AT_LOCK_MODE=""
	return 0
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
# 注意：这里会先抢串口锁（见上面的 omod_lock）。抢不到就返回 busy，
# 让调用方报错而不是冲进去和别的进程抢串口。
omod_open() {
	AT_ERR=""

	AT_PORT="${1:-$(omod_find_port)}"
	if [ -z "$AT_PORT" ] || [ ! -c "$AT_PORT" ]; then
		AT_ERR="no_at_port"
		return 1
	fi

	if ! omod_lock; then
		AT_ERR="busy"
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
	# 放掉串口锁。即使调用方忘了调，flock 也会在进程退出时自动释放；
	# mkdir 那条路径靠 PID 存活检查兜底，不会把串口锁死。
	omod_unlock
	return 0
}

# ------------------------------------------------------------------ 收发
omod_write() {
	printf '%s\r' "$1" > "$AT_PORT" 2>/dev/null
}

# 累积读：每轮 timeout 2 秒兜底，串口空闲 0.5 秒 cat 就返回；
# 连续读到空就认为收完了，轮数上限只是防死循环，放宽到 32（多指令批量回复会被拆成多段，太小会静默截断）。
omod_read() {
	local out="" chunk i=0

	while [ "$i" -lt 32 ]; do
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

# ------------------------------------------------------------------ 发一条 PDU
# AT+CMGS 是【交互式】的，不能像查询那样"写完再读"：
#   ① 发 AT+CMGS=<TPDU 字节数>
#   ② 等模块回一个 "> " 提示符
#   ③ 再把 PDU 十六进制发过去，并以 Ctrl-Z(0x1A) 结尾
#   ④ 模块回 +CMGS: <消息参考号> 和 OK
# 这里靠 stty 的 min 0 time 5（空闲 0.5 秒 read 返回）来「等提示符」，
# 不 sleep 固定时间 —— 模块快就快、慢就多等一个周期。
omod_send_pdu() {
	local octets="$1" pdu="$2" resp

	printf 'AT+CMGS=%s\r' "$octets" > "$AT_PORT" 2>/dev/null

	resp="$(timeout 2 cat "$AT_PORT" 2>/dev/null)"
	case "$resp" in
		*'>'*) : ;;
		*) printf '%s' "$resp"; AT_ERR="no_prompt"; return 1 ;;
	esac

	printf '%s\032' "$pdu" > "$AT_PORT" 2>/dev/null

	resp="$(omod_read)"
	printf '%s' "$resp"
	case "$resp" in
		*+CMGS:*|*OK*) return 0 ;;
		*) AT_ERR="send_failed"; return 1 ;;
	esac
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
