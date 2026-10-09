#!/bin/sh
#
# 逐个测试模组的 USB 数据模式 —— 从兼容性最强的开始:3(RNDIS) → 5(NCM) → 2(MBIM)
#
# 【这个脚本会改模组的 usbnet 模式,每次切换会断网十几到几十秒】
# 【所以必须手动、一个一个跑,跑完一个看清楚再决定下一个】
#
# 用法:
#   sh tests/mode-test.sh 3      # 测 RNDIS(基线,现在就在用)
#   sh tests/mode-test.sh 5      # 测 NCM
#   sh tests/mode-test.sh 2      # 测 MBIM
#   sh tests/mode-test.sh back   # 切回 3(兜底)
#   sh tests/mode-test.sh status # 只看当前状态,不改任何东西
#
# 设计原则:
#   · 一次只切一个,绝不自动连续切
#   · 每个模式都完整测四项:联网 / 速率 / 延迟 / 模组后台可达性
#   · 退出时一定告诉你怎么回滚
#   · status 是纯只读
#
set -u
TARGET="${1:-status}"
S="ssh root@192.168.6.1"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

remote() { ssh -o ConnectTimeout=20 -o StrictHostKeyChecking=no root@192.168.6.1 "$@"; }

case "$TARGET" in
status)
	say "① 当前模式(只读)"
	remote '. /usr/lib/openfi-modem/at.sh
		omod_open >/dev/null 2>&1 || { echo "  AT 打不开"; exit 1; }
		omod_write "AT+QCFG=\"usbnet\""; sleep 1
		timeout 3 cat "$AT_PORT" 2>/dev/null | tr -d "\r" | grep usbnet
		omod_close
		echo "  网卡: $(ls /sys/class/net | grep -E "^(usb|wwan)[0-9]+$" | tr "\n" " ")"
		echo "  默认路由: $(ip route | awk "/^default/{print \$3\" dev \"\$5; exit}")"
		echo "  WAN: $(ping -c1 -W3 223.5.5.5 >/dev/null 2>&1 && echo 通 || echo 不通)"
		echo "  模组后台: $(ping -c1 -W2 192.168.100.1 >/dev/null 2>&1 && echo 可达 || echo 不可达)"'
	;;
back)
	say "切回 RNDIS(3)—— 兜底"
	remote '. /usr/lib/openfi-modem/at.sh
		omod_open >/dev/null 2>&1 || exit 1
		omod_write "AT+QCFG=\"usbnet\",3"; sleep 1
		timeout 3 cat "$AT_PORT" 2>/dev/null | tr -d "\r" | grep -E "OK|ERROR"
		omod_close'
	echo "  等 30 秒重新枚举…"; sleep 30
	sh "$0" status
	;;
3|5|2)
	say "② 切到 $TARGET 模式"
	remote ". /usr/lib/openfi-modem/at.sh
		omod_open >/dev/null 2>&1 || exit 1
		echo '  切换前: '\$(omod_query 'AT+QCFG=\"usbnet\"' | grep usbnet)
		omod_write 'AT+QCFG=\"usbnet\",$TARGET'; sleep 1
		timeout 3 cat \"\$AT_PORT\" 2>/dev/null | tr -d '\r' | grep -E 'OK|ERROR'
		omod_close"
	echo "  等 40 秒重新枚举 + 驻网…"; sleep 40
	say "③ 联网"
	remote 'echo "  网卡: $(ls /sys/class/net | grep -E "^(usb|wwan)[0-9]+$" | tr "\n" " ")"
		echo "  默认路由: $(ip route | awk "/^default/{print \$3\" dev \"\$5; exit}")"
		echo "  ping 223.5.5.5: $(ping -c3 -W3 223.5.5.5 >/dev/null 2>&1 && echo 通 || echo 不通)"
		echo "  DNS 解析: $(nslookup www.baidu.com 223.5.5.5 >/dev/null 2>&1 && echo 通 || echo 不通)"
		echo "  模组后台 192.168.100.1: $(ping -c2 -W2 192.168.100.1 >/dev/null 2>&1 && echo 可达 || echo 不可达)"
		echo "  延迟: $(ping -c5 -W3 223.5.5.5 2>/dev/null | tail -1)"'
	say "④ 速率(3 个源各 8 秒,取最快)"
	remote 'best=0
	for src in "https://speed.cloudflare.com/__down?bytes=200000000" \
	           "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ls-lR.gz" \
	           "https://mirrors.ustc.edu.cn/ubuntu/ls-lR.gz"; do
	  rm -f /tmp/dl.bin; t0=$(date +%s)
	  timeout 8 wget -q -O /tmp/dl.bin "$src" 2>/dev/null
	  t1=$(date +%s); dt=$((t1-t0)); [ "$dt" -lt 1 ] && dt=1
	  b=$(stat -c%s /tmp/dl.bin 2>/dev/null || echo 0)
	  m=$((b/dt/125000))
	  printf "    %-50s %5d KB/s  (%d Mbps)\n" "$(echo $src | cut -c1-48)" "$((b/dt/1024))" "$m"
	  [ "$m" -gt "$best" ] && best=$m
	done
	rm -f /tmp/dl.bin; echo "    ★ 最快: ${best} Mbps"'
	say "⑤ 信号(AT,和数据模式无关,作为对照)"
	remote '. /usr/lib/openfi-modem/at.sh
		omod_open >/dev/null 2>&1 && { omod_write "AT+QCAINFO"; sleep 1
		timeout 3 cat "$AT_PORT" 2>/dev/null | tr -d "\r" | grep QCAINFO | sed "s/^/    /"; omod_close; }'
	say "⑥ 回滚提示"
	echo "  不满意就:  sh $0 back"
	;;
*)
	echo "用法: $0 {status|3|5|2|back}" >&2; exit 1
	;;
esac
