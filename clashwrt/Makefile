# SPDX-License-Identifier: GPL-3.0-or-later
include $(TOPDIR)/rules.mk

PKG_NAME:=clashwrt
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=mrFrok <mrFrok228@proton.me>

include $(INCLUDE_DIR)/package.mk

define Package/clashwrt
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=ClashWrt - transparent proxy firewall for mihomo
  URL:=https://github.com/mrFrok/clashwrt
  DEPENDS:=+nftables +ip-full +kmod-nft-nat +kmod-nft-tproxy +kmod-tun
  PKGARCH:=all
endef

define Package/clashwrt/description
  Drives mihomo (Clash Meta) as a transparent proxy on OpenWrt, with four
  selectable interception modes -- full TPROXY, TPROXY for TCP plus a tun
  device for UDP, full tun, or a NAT redirect for TCP plus a tun device for
  UDP -- so a working combination exists even on kernels where TPROXY is
  broken. Configuration lives in UCI; the nftables ruleset and policy routing
  are generated from it.
endef

define Package/clashwrt/conffiles
/etc/config/clashwrt
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/clashwrt/install
	$(INSTALL_DIR) $(1)/usr/libexec/clashwrt
	$(INSTALL_BIN) ./files/usr/libexec/clashwrt/fw.sh $(1)/usr/libexec/clashwrt/fw.sh
	$(INSTALL_BIN) ./files/usr/libexec/clashwrt/selftest.sh $(1)/usr/libexec/clashwrt/selftest.sh
	$(INSTALL_BIN) ./files/usr/libexec/clashwrt/confctl.sh $(1)/usr/libexec/clashwrt/confctl.sh
	$(INSTALL_BIN) ./files/usr/libexec/clashwrt/filectl.sh $(1)/usr/libexec/clashwrt/filectl.sh
	$(INSTALL_BIN) ./files/usr/libexec/clashwrt/uictl.sh $(1)/usr/libexec/clashwrt/uictl.sh
	$(INSTALL_BIN) ./files/usr/libexec/clashwrt/logctl.sh $(1)/usr/libexec/clashwrt/logctl.sh

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/clashwrt $(1)/etc/init.d/clashwrt

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/clashwrt $(1)/etc/config/clashwrt

	$(INSTALL_DIR) $(1)/etc/hotplug.d/net
	$(INSTALL_DATA) ./files/etc/hotplug.d/net/30-clashwrt $(1)/etc/hotplug.d/net/30-clashwrt

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-clashwrt $(1)/etc/uci-defaults/99-clashwrt
endef

define Package/clashwrt/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/clashwrt enable
exit 0
endef

define Package/clashwrt/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/clashwrt stop
/etc/init.d/clashwrt disable
exit 0
endef

$(eval $(call BuildPackage,clashwrt))
