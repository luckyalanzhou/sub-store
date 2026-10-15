include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-sub-store
PKG_VERSION:=$(SUB_STORE_VERSION)
PKG_RELEASE:=1
PKG_MAINTAINER:=Sub-Store project maintainers
PKGARCH:=all

ifeq ($(strip $(PKG_VERSION)),)
$(error SUB_STORE_VERSION is required, for example SUB_STORE_VERSION=0.0.1)
endif

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-sub-store
  SECTION:=luci
  CATEGORY:=LuCI
  TITLE:=LuCI app for the official Sub-Store Docker service
  URL:=https://github.com/luckyalanzhou/sub-store
  DEPENDS:=+luci-base +luci-lib-base +luci-lib-jsonc +lua +rpcd-mod-file +curl +jsonfilter +docker +dockerd
  PKGARCH:=all
endef

define Package/luci-app-sub-store/description
 LuCI management interface and OpenWrt service integration for the official
 xream/sub-store Docker image. The Docker image and its data are managed on the device.
endef

define Package/luci-app-sub-store/conffiles
/etc/config/sub-store
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)/root
	$(CP) $(SUB_STORE_SOURCE_ROOT)/run/payload/root/. $(PKG_BUILD_DIR)/root/
	$(INSTALL_DATA) $(SUB_STORE_SOURCE_ROOT)/openwrt/luci-app-sub-store/files/etc/config/sub-store $(PKG_BUILD_DIR)/sub-store.config
	$(INSTALL_BIN) $(SUB_STORE_SOURCE_ROOT)/openwrt/luci-app-sub-store/files/etc/uci-defaults/99-sub-store $(PKG_BUILD_DIR)/99-sub-store
endef

define Build/Configure
endef

define Build/Compile
endef

define Build/Install
endef

define Package/luci-app-sub-store/install
	$(CP) $(PKG_BUILD_DIR)/root/. $(1)/
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/sub-store $(1)/etc/uci-defaults
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/sub-store.config $(1)/etc/config/sub-store
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/99-sub-store $(1)/etc/uci-defaults/99-sub-store
	printf '%s\n' '$(PKG_VERSION)' > $(1)/etc/sub-store/version
	printf '%s\n' '$(SUB_STORE_PACKAGE_FORMAT)' > $(1)/etc/sub-store/package-format
	chmod 755 $(1)/etc/init.d/sub-store \
		$(1)/usr/bin/sub-storectl \
		$(1)/usr/lib/sub-store/job.sh \
		$(1)/usr/lib/sub-store/plugin-update \
		$(1)/usr/lib/sub-store/status \
		$(1)/etc/uci-defaults/99-sub-store
	chmod 644 $(1)/etc/config/sub-store $(1)/etc/sub-store/version $(1)/etc/sub-store/package-format \
		$(1)/usr/lib/sub-store/cron.sh \
		$(1)/usr/lib/sub-store/healthcheck.js \
		$(1)/usr/lib/sub-store/permissions.sh \
		$(1)/usr/share/luci/menu.d/luci-app-sub-store.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-sub-store.json \
		$(1)/www/luci-static/resources/view/sub-store/manage.js
endef

define Package/luci-app-sub-store/postinst
#!/bin/sh
set -e
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
[ -x /etc/uci-defaults/99-sub-store ] || exit 1
/etc/uci-defaults/99-sub-store
rm -f /etc/uci-defaults/99-sub-store
endef

$(eval $(call BuildPackage,luci-app-sub-store))
