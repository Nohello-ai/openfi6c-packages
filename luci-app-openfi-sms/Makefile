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

LUCI_TITLE:=OpenFi 6C SMS (send / receive / view)
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
