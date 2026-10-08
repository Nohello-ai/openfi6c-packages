#
# luci-app-openfi-sms —— OpenFi 6C 短信收发
#
# 依赖 luci-app-openfi-modem：AT 串口那套（含互斥锁）在它里面，
# 这里直接 source 复用，不重复实现一份 —— 也保证两个包用的是同一把锁，
# 否则短信和模组信息会同时抢串口。
#
# PDU 编解码用 ucode 写（usr/lib/openfi-sms/pdu.uc）：
# 解释型，所以本包仍然是 Architecture: all，CI 不需要交叉工具链。
#
include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/package.mk

PKG_NAME:=luci-app-openfi-sms
PKG_VERSION:=1.0.0
PKG_RELEASE:=$(shell date -u +%Y%m%d%H%M)

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=OpenFi 6C

# 标题里【不要放括号】：make 在某些上下文里会被 () 搞乱，
# 之前 fan/modem 的标题都没有括号，这里也保持一致。
LUCI_TITLE:=OpenFi 6C SMS - send receive view
LUCI_DESCRIPTION:=OpenFi 6C 短信：列表、弹窗看全文、发送、删除。PDU 编解码走 ucode，长短信按 UDH 自动拼接。
LUCI_MAINTAINER:=OpenFi 6C community port
LUCI_DEPENDS:=+luci-base +luci-app-openfi-modem +ucode
LUCI_PKGARCH:=all

# 和 luci-app-openfi-modem 一样关掉 jsmin。
# 不是"省不省几 KB"的问题：jsmin 解析失败会让【整次固件编译中断】，
# modem 包当初就因为这个踩过一次，注释留在那边了。
# 我们的 JS 只有几百行，压不压无所谓，不值得冒这个险。
LUCI_MINIFY_JS:=0

define Package/luci-app-openfi-sms/conffiles
/etc/config/openfi_sms
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
#
# 【这一行不能删】它看着像句废话，其实是 OpenWrt feed 扫描器的识别标记：
#   include/scan.mk 建索引时执行的是
#       find ... -name Makefile | xargs grep -aHE 'call (BuildPackage|KernelPackage|...)'
#   也就是说【只有 Makefile 里出现 "call BuildPackage" 这个字符串，这个目录才被当成包】。
#   连注释里的都算 —— fan 和 modem 的 Makefile 结尾都有这一行，SMS 当初漏了。
#
# 漏掉的后果非常隐蔽：
#   · 包 CI 是直接 cp 进 package/ 编译的，不走扫描器 → 【能过】
#   · 固件 CI 是通过 feed 拉的，必须过扫描器 → 【扫不到 → 装不上 → 配置符号变未知
#     → make defconfig 丢掉 → 断言失败】
#   两边行为不一致，所以排查了很久。
