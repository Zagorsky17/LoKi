# Modified for LoKi on 2026-11-04: include the unchanged project license.
# Modified for LoKi on 2026-10-31: use the project release repository.
include $(TOPDIR)/rules.mk

# Optional core additions do not raise the backend's compatibility minimum.
LOKI_CORE_MIN_VERSION:=$(shell sed -n 's/^[[:space:]]*SB_REQUIRED_VERSION: "\([^"]*\)".*/\1/p' ./files/usr/lib/core/constants.uc | awk 'NR == 1 { value=$$0 } END { if (NR == 1 && value ~ /^[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$$/) print value }')
ifeq ($(LOKI_CORE_MIN_VERSION),)
$(error Cannot read SB_REQUIRED_VERSION from backend constants)
endif

PKG_NAME:=loki

LOKI_SOURCE_VERSION:=$(or $(LOKI_PACKAGE_VERSION),$(LOKI_VERSION))
LOKI_HAS_RELEASE_VERSION:=$(if $(filter dev,$(LOKI_SOURCE_VERSION)),,$(LOKI_SOURCE_VERSION))
LOKI_COMPILED_VERSION:=$(if $(LOKI_HAS_RELEASE_VERSION),$(LOKI_SOURCE_VERSION),$(or $(LOKI_SOURCE_VERSION),dev))
LOKI_RELEASE_VERSION_VALID:=$(if $(LOKI_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(LOKI_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' && printf '1'),1)

ifeq ($(LOKI_RELEASE_VERSION_VALID),)
$(error LOKI_PACKAGE_VERSION and LOKI_VERSION must use x.y.z format)
endif

PKG_VERSION:=$(or $(LOKI_HAS_RELEASE_VERSION),0.0.0)
PKG_RELEASE:=

PKG_MAINTAINER:=Zagorsky17
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/loki
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+ca-bundle +ucode +ucode-mod-fs +ucode-mod-resolv +ucode-mod-socket +ucode-mod-ubus +ucode-mod-uloop +ucode-mod-uci +uclient-fetch +kmod-nft-tproxy +nftables +kmod-nft-nat +ip +loki-core
	EXTRA_DEPENDS:=loki-core (>=$(LOKI_CORE_MIN_VERSION))
	TITLE:=LoKi backend service
	URL:=https://github.com/Zagorsky17/LoKi
	PKGARCH:=all
endef

define Package/loki/description
	Rule-based traffic routing for OpenWrt
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/loki/prerm
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0
# The SDK prepends the wrapper path to the package action arguments.
/usr/bin/loki package_prerm "$${2:-remove}" >/dev/null 2>&1
endef

ifeq ($(CONFIG_USE_APK),y)
define Package/loki/preinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ "$${PKG_UPGRADE}" = "1" ] || exit 0
/usr/bin/loki package_prerm upgrade >/dev/null 2>&1
endef
endif

define Package/loki/postinst
#!/bin/sh

[ -n "$${IPKG_INSTROOT}" ] && exit 0
LOKI_LIB=/usr/lib/loki ucode -L /usr/lib/loki /usr/lib/loki/config/migration.uc migrate || exit $$?
LOKI_BYTECODE_VALIDATION_TTL=0 /usr/bin/loki package_postinst
endef

define Package/loki/conffiles
/etc/config/loki
endef

define Package/loki/install
	$(INSTALL_DIR) $(1)/usr/share/licenses/loki
	$(INSTALL_DATA) ../LICENSE $(1)/usr/share/licenses/loki/LICENSE

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/loki $(1)/etc/init.d/loki
	$(INSTALL_BIN) ./files/etc/init.d/loki-state $(1)/etc/init.d/loki-state

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/loki $(1)/etc/config/loki
	$(INSTALL_DIR) $(1)/usr/share/loki
	$(INSTALL_DATA) ./files/etc/config/loki $(1)/usr/share/loki/default-config
	$(INSTALL_DATA) ../install.sh $(1)/usr/share/loki/install.sh
	$(INSTALL_DATA) ../component-update.sh $(1)/usr/share/loki/component-update.sh
	$(INSTALL_DATA) ../component-update.uc $(1)/usr/share/loki/component-update.uc
	$(INSTALL_DATA) ../uninstall.sh $(1)/usr/share/loki/uninstall.sh

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/loki $(1)/usr/bin/loki
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/loki-gateway $(1)/usr/libexec/loki-gateway

	$(INSTALL_DIR) $(1)/usr/lib/loki
	$(CP) ./files/usr/lib/. $(1)/usr/lib/loki/

	$(INSTALL_DIR) $(1)/usr/share/nftables.d/chain-pre/input
	$(INSTALL_DATA) ./files/usr/share/nftables.d/chain-pre/input/loki.nft $(1)/usr/share/nftables.d/chain-pre/input/loki.nft

	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/loki $(1)/lib/upgrade/keep.d/loki

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(LOKI_COMPILED_VERSION)/g' $(1)/usr/lib/loki/core/constants.uc
endef

$(eval $(call BuildPackage,loki))
