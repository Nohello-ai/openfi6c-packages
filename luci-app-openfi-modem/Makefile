#
# luci-app-openfi-modem —— OpenFi 6C 的 5G 模块信息 + SIM 卡槽切换
#
# 这是一个**独立**的 LuCI 插件，不再往固件自带的 luci-app-openfi / 状态页里塞东西：
#   * 随固件一起编译时，会在 LuCI 里多出一个顶层菜单「移动网络」
#   * 单独编译时，产物是一个 .apk，可以直接装到已经刷好的机器上
#
# 只读查询 + 卡槽切换都走模块自己的 AT 口，AT 读写只用 busybox 的
# stty / timeout / cat，不依赖 sms_tool、picocom、atinout，
# 也不调用 QModem（QModem 的拨号 + 硬件流量卸载有已知重启问题）。
#
include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/package.mk

PKG_NAME:=luci-app-openfi-modem
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=OpenFi 6C community port
LUCI_MAINTAINER:=OpenFi 6C community port

LUCI_TITLE:=LuCI app for OpenFi 6C 5G modem info and SIM slot switch
# coreutils-stty / coreutils-timeout 是【必需】的，别删：
#   at.sh 靠 stty 把串口设成 raw + min 0 time 5（空闲即返回，cat 才能自然结束），
#   靠 timeout 兜底（没配成功时 cat 会一直阻塞）。
#   实测多份自编固件的 busybox 里【没有】这两个 applet
#   （`stty -F` → not found；`busybox timeout` → applet not found），
#   缺了就会报 stty_failed / 读不到数据，模组页一片空白。
#   走 coreutils 而不改 busybox 配置，是为了让这个包在任何固件上都能装得上。
LUCI_DEPENDS:=+kmod-usb-serial-option +kmod-usb-serial-wwan +jsonfilter +coreutils-stty +coreutils-timeout +flock
LUCI_PKGARCH:=all
LUCI_DESCRIPTION:=OpenFi 6C 5G 模组：信息/卡槽切换、信号历史与流量、AT 终端。

# 关掉 luci.mk 的 jsmin：本插件只有几百行 JS，不值得为了省几 KB
# 去冒 minifier 解析失败、整次固件编译中断的风险。
LUCI_MINIFY_JS:=0

define Package/luci-app-openfi-modem/conffiles
/etc/config/openfi_modem
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
