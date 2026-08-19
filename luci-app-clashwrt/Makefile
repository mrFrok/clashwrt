# SPDX-License-Identifier: GPL-3.0-or-later
include $(TOPDIR)/rules.mk

PKG_VERSION:=0.1.0
PKG_RELEASE:=1

LUCI_TITLE:=LuCI interface for ClashWrt
LUCI_DESCRIPTION:=Web interface for the mihomo transparent proxy firewall, \
	including the four interception modes and their routing.
LUCI_DEPENDS:=+clashwrt
LUCI_PKGARCH:=all

PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=mrFrok <mrFrok228@proton.me>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
