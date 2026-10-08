# luci-app-openfi-modem

OpenFi 6C 的 **独立** LuCI 插件。顶层菜单 **移动网络**，下面三页：

| 页面 | 路径 | 内容 |
| --- | --- | --- |
| 模组信息与卡槽 | `openfi/modem` | 型号/固件/IMEI/ICCID/IMSI/注册状态/SIM 状态/卡槽/运营商/制式/信号/温度 + **服务小区表**（AT+QCAINFO）+ 切卡 + 软重启 |
| 信号与流量 | `openfi/signal` | **信号历史曲线**（CSQ/RSRP/RSSI 可切换，跟随主题的 SVG）+ 连接状态（IP/网关/DNS/在线时长）+ 流量统计（累计 + 页面侧算的实时速率） |
| AT 终端 | `openfi/at` | 直接发任意 AT 指令，14 个常用指令一键发送，带黑名单保护 |

## 后端脚本

| 脚本 | 作用 |
| --- | --- |
| `usr/sbin/openfi-modem-info` | 只读查询（`ATI`/`AT+CGMM`/`AT+CGSN`/`AT+CPIN?`/`AT+CSQ`/`AT+QRSRP`/`AT+COPS?`/`AT+QNWINFO`/`AT+QTEMP`/`AT+QCCID`/`AT+CIMI`/`AT+CREG?`/`AT+CEREG?`/`AT+QCAINFO`/`AT+QUIMSLOT?`），输出一行 JSON |
| `usr/sbin/openfi-modem-switch` | 切卡 `AT+QUIMSLOT=n`、软重启 `AT+CFUN=1,1` |
| `usr/sbin/openfi-modem-link` | 连接状态与流量（`ifstatus` + `jsonfilter` + `/sys/class/net/usb0/statistics`） |
| `usr/sbin/openfi-modem-at` | AT 终端后端（单行/限长/黑名单过滤） |
| `usr/sbin/openfi-modem-signal` | 信号采样（`sample`/`clear`/`daemon`）+ 历史查询 |
| `etc/init.d/openfi-signal` | procd 拉起采样守护，改配置保存后自动 HUP 重载 |

## AT 终端的安全边界

`openfi-modem-at` 有意做了三层限制，**别去掉**：

1. 单行、可打印 ASCII、必须以 `AT` 开头、长度 ≤ 200 —— 否则一条命令能夹带任意多条指令
2. 换行/回车直接删掉（多行输入会被拼成一条无效指令，而不是变成两条）
3. **黑名单**：`AT+QCFG="usbnet"`（改 USB 模式，立刻失联）、`QFASTBOOT`/`QDOWNLOAD`（进下载模式）、`QFOTADL`/`QUPDATE`（固件升级，失败即变砖）、`AT+QRST`/`AT+QPRTPARA`（恢复出厂）、`EFS` 操作、`AT&F`。这些发错要拆机才能救。

## 信号历史存在哪

`/tmp/openfi-signal.log`（一行一个样本：`epoch|csq|dbm|rsrp|network`）。

**故意放 /tmp**：那是 tmpfs，不写 flash。互斥写 flash 会折寿，而"看最近几小时信号"这个需求不需要持久化。
环缓冲默认保留 **288 条**（`keep`），`interval` 默认 **60 秒** → 约 4.8 小时。重启后清空。

## 隐私提示

ICCID 与 IMSI 是能定位到卡和用户的标识。页面只在本机显示，但**截图/日志里带上它们要留意**。

## 为什么是独立插件

之前那份实现把 Modem Info 直接塞进了 `luci-app-openfi` 的状态页
（`htdocs/.../view/status/include/15_modem.js`），那样有几个问题：

- 必须重刷整个固件才能改一行显示
- 和厂商自带插件、状态页耦合，升级底座时容易被覆盖
- 想装到已经刷好的机器上没门

现在改成独立的 `luci-app-openfi-modem`：

- 随固件编译时，LuCI 里多出一个顶层菜单 **移动网络**
- 单独编译时，产物是一个 `.apk`，可以直接装到已经刷好的机器上（不用重刷固件）

## 页面内容

顶层菜单 **移动网络 → 模组信息与卡槽**：

| 分组 | 内容 |
| --- | --- |
| 模组信息 | 设备型号、厂商、模块固件、IMEI、AT 串口、SIM 状态、当前卡槽、支持卡槽、运营商、网络制式、信号（CSQ / dBm / RSRP）、模块温度 |
| SIM 卡槽 | 切到其它卡槽（`AT+QUIMSLOT=n`）、软重启模块（`AT+CFUN=1,1`）、手动刷新 |

## 实现要点

- **只读优先**：信息查询只发 `ATI` / `AT+xxx?` 这类查询指令，
  一条写指令都不发，所以刷新页面不会打断模块当前的数据连接。
- **依赖 `coreutils-stty` + `coreutils-timeout`**（**必需**，已写进 Makefile 的
  `LUCI_DEPENDS`）。**别以为 busybox 一定有这两个 applet** —— 实测多份自编固件
  的 busybox 里 `stty` / `timeout` 都是**关掉**的：
  `stty -F` 直接 `not found`，`busybox timeout` 报 `applet not found`，
  连 `busybox --list` 都没有。缺了就会 `stty_failed` / 读不到数据，
  模组页一片空白。走 coreutils 而不是去改 busybox 配置，是为了让这个包
  **在任何固件上都装得上**。
  不需要 `sms_tool`、`picocom`、`atinout`。
- **波特率设不上不算失败**：实测 RM500U-CN + `option` 驱动会**拒绝改波特率**
  （`stty -F /dev/ttyUSBn 115200` → `unable to perform all requested operations`，
  只有设成当前值 9600 这种空操作才会"成功"）。但 USB 串口的实际速率跟这个参数
  无关（走 USB 包），收发完全正常。所以 `omod_open` 逐级降级：
  带波特率 → 不带波特率 → 换重定向写法，**只要 raw/min/time 设上就算成功**。
- **顺带给风扇提供模组温度**：`openfi-modem-signal` 每轮采样会在 `AT+QTEMP` 后把
  「时间戳 温度」写进 `/var/run/openfi-modem.temp`，供 `luci-app-openfi-fan`
  做三路温度联动用。写时间戳而不是靠 mtime —— 这块板子的 busybox 没有 `stat`。
- **不调用 QModem**：QModem 的「拨号 + 硬件流量卸载」组合会把机器搞重启
  （FUjr/QModem discussions #214），本插件只用 AT 口读状态和切卡。
- **串口读法**：`stty ... min 0 time 5` 之后，串口空闲 0.5 秒 `read()` 返回 0，
  `cat` 当作 EOF 自然退出。比「后台 `cat` + `sleep` + `kill`」那种写法
  更不容易漏数据，也不会留下僵尸进程。
- **AT 口自动探测**：先按 `uci openfi_modem.modem.at_port`，再按 sysfs 里的
  接口名，最后按 `ttyUSB3..0` 顺序兜底。
  > 注意：`$p/device/interface` 这个 sysfs 路径**在很多设备上并不存在**
  > （MTK 平台实测就没有 `interface` 文件，只有 `bInterfaceClass` 等），
  > 所以实际生效的通常就是最后的 `ttyUSB3..0` 兜底顺序。
  > OpenFi 6C 上实测 **ttyUSB3 就是正确的 AT 口**。
- **流量统计只认 WAN 口的计数器**：`openfi-modem-link` 取的是
  `uci get network.wan.device`（= `usb0`）的 `statistics/rx_bytes`，
  **这是准的**。
  > 实测踩过的坑：开了 HNAT 硬件加速之后，**局域网侧网卡**（`br-lan`）的
  > `statistics` 会**少算很多** —— HNAT 把转发流量直接硬件转发掉，不经过
  > 内核网络栈，网卡层软件计数器根本看不到。实测同一时刻
  > `usb0 rx = 2.48 GB` 而 `br-lan rx+tx` 只有 `631 MB`，差 4 倍。
  > 所以：**要算总流量就用 WAN 口（usb0）的计数器**，别用 br-lan。
  >
  > 单个客户端的用量则是走 conntrack：`nf_conntrack_acct=1` 已开，
  > 且 MTK 的 HNAT 驱动（`hnat_nf_hook.c` 的 keepalive）会把硬件计数
  > **回写**到 conntrack 和 iptables 的计数器里，所以基于
  > `/proc/net/nf_conntrack` 的统计是准的。

## 文件

```
Makefile
htdocs/luci-static/resources/view/openfi/modem.js   # 页面
root/etc/config/openfi_modem                        # uci 配置（AT 口 / 波特率 / 刷新间隔）
root/usr/lib/openfi-modem/at.sh                     # AT 串口公共函数
root/usr/sbin/openfi-modem-info                     # 只读查询，输出 JSON
root/usr/sbin/openfi-modem-switch                   # 切卡 / 软重启
root/usr/share/luci/menu.d/luci-app-openfi-modem.json
root/usr/share/rpcd/acl.d/luci-app-openfi-modem.json
```

## 配置

`/etc/config/openfi_modem`

```
config modem 'modem'
	option at_port ''      # 留空 = 自动探测
	option baud '115200'

config switch 'switch'
	option restart_after_switch '0'   # 切完卡是否自动软重启模块

config view 'view'
	option poll '15'       # 页面自动刷新间隔（秒）
```

## 命令行排障

```sh
openfi-modem-info            # 看 JSON
openfi-modem-info --raw      # 看 AT 口和模块原始回显
openfi-modem-switch 2        # 切到 SIM 2
openfi-modem-switch restart  # 软重启模块
```

## 已知限制

- 双卡单待：同一时刻只有一张卡在线，切卡要重新搜网。
- 模块必须处在能通过 DHCP 上网的 USB 模式（ECM / RNDIS），
  本插件不会去改模块的 USB 模式，也不负责拨号。
- `AT+QTEMP` / `AT+QRSRP` / `AT+QNWINFO` 是移远（含展锐平台）的私有指令，
  换其它厂商模组时这几项会为空，其余字段仍可用。

## USB 数据模式自动探测（openfi-usbmode）

模组的 `usbnet` 模式决定"模组怎么把数据交给 CPU"，速度和结构差别很大：

| 模式 | 值 | 速度 | 内部 NAT | 说明 |
|---|---|---|---|---|
| **MBIM** | 2 | ⭐⭐⭐ | **无** | 主机直接拿运营商 IP，少一跳，理论上最好 |
| **NCM** | 5 | ⭐⭐⭐ | 有 | 多包聚合，比 RNDIS 快一档 |
| **RNDIS** | 3 | ⭐ | 有 | 兼容性最好、速度最差（模组默认） |

开机时按 **MBIM → NCM → RNDIS** 逐个试，哪个**真的拿到 IP 并且 ping 得通**就用哪个，
结果记在 `/etc/openfi-usbmode`，以后开机直接用（不再折腾）。

**为什么不用 RMNET/QMI**：RM500U-CN 是展锐平台，RMNET/QMI 是高通那套原生模式，
在这颗芯片上基本没实现 —— 试它们只会白白多几次 USB 重新枚举。

### 安全设计

这块出错就没网，所以：

* **RNDIS 兜底** —— 全失败时回到和出厂完全一样的状态
* **只有真通才算成功** —— 网卡出现不算（没插卡/欠费/模组假死时网卡照样在、IP 也照样有）
* **最多切 6 次** —— 防止在几个模式之间来回死循环
* **驱动不在就跳过** —— 不浪费一次重新枚举
* **结果持久化** —— 只在成功时写，之后开机秒过

### 控制

```sh
uci set openfi_modem.usbmode.mode='off'   # 关掉探测，保持现状
uci set openfi_modem.usbmode.mode='5'     # 钉死 NCM
uci set openfi_modem.usbmode.mode='auto'  # 恢复自动（默认）
uci commit openfi_modem

openfi-usbmode show     # 看上次探明了什么
openfi-usbmode reset    # 清掉记录，下次开机会重新探测
```

### 注意

* 切换模式会让模组**重新枚举**（USB 拔插一次），WAN 断十几秒
* **首次开机**可能要试两三次，最长一两分钟 —— 只发生一次，之后就快了
* 需要固件带 `cdc_ncm` / `cdc_mbim` 驱动 + `umbim`（defconfig 已含）
