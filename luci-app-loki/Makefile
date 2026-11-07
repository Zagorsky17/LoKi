# Modified for LoKi on 2026-11-04: include the unchanged project license.
# Modified for LoKi on 2026-11-06: preserve bundled YACD dependency notices.
# Modified for LoKi on 2026-10-31: identify the independently maintained package.
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-loki

LOKI_SOURCE_VERSION:=$(or $(LOKI_PACKAGE_VERSION),$(LOKI_VERSION))
LOKI_HAS_RELEASE_VERSION:=$(if $(filter dev,$(LOKI_SOURCE_VERSION)),,$(LOKI_SOURCE_VERSION))
LOKI_COMPILED_VERSION:=$(if $(LOKI_HAS_RELEASE_VERSION),$(LOKI_SOURCE_VERSION),$(or $(LOKI_SOURCE_VERSION),dev))
LOKI_RELEASE_VERSION_VALID:=$(if $(LOKI_HAS_RELEASE_VERSION),$(shell printf '%s\n' '$(LOKI_SOURCE_VERSION)' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' && printf '1'),1)

ifeq ($(LOKI_RELEASE_VERSION_VALID),)
$(error LOKI_PACKAGE_VERSION and LOKI_VERSION must use x.y.z format)
endif

PKG_VERSION:=$(or $(LOKI_HAS_RELEASE_VERSION),0.0.0)
PKG_RELEASE:=
PKG_PO_VERSION:=$(PKG_VERSION)

LUCI_TITLE:=LuCI LoKi app
LUCI_DEPENDS:=+luci-base +loki
LUCI_EXTRA_DEPENDS:=loki (>=$(PKG_VERSION))
LUCI_URL:=https://github.com/Zagorsky17/LoKi
LUCI_PKGARCH:=all
LUCI_LANG.ru:=Русский (Russian)
LUCI_LANG.en:=English
LUCI_MAINTAINER:=Zagorsky17
LUCI_DESCRIPTION:=Web interface for LoKi
# shortcut: Preserve esbuild output; recheck SDK jsmin before enabling a second minifier.
LUCI_MINIFY_JS:=0

PKG_LICENSE:=GPL-2.0-or-later AND MIT AND Apache-2.0 AND 0BSD AND OFL-1.1 AND ISC
# LuCI's automatic locale packages write luci.languages.*; LoKi owns its locale.
override LUCI_LANGUAGES :=

define Build/Prepare/$(PKG_NAME)
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/share/licenses/luci-app-loki
	$(INSTALL_DATA) ../LICENSE $(PKG_BUILD_DIR)/root/usr/share/licenses/luci-app-loki/LICENSE
	$(INSTALL_DATA) ../yacd-loki/LICENSE $(PKG_BUILD_DIR)/root/usr/share/licenses/luci-app-loki/YACD-LICENSE
	$(INSTALL_DATA) ../yacd-loki/licenses/inter-OFL.txt $(PKG_BUILD_DIR)/root/usr/share/licenses/luci-app-loki/INTER-OFL
	$(INSTALL_DATA) ../yacd-loki/licenses/roboto-mono-OFL.txt $(PKG_BUILD_DIR)/root/usr/share/licenses/luci-app-loki/ROBOTO-MONO-OFL
	$(INSTALL_DATA) ../yacd-loki/licenses/THIRD_PARTY_NOTICES.txt $(PKG_BUILD_DIR)/root/usr/share/licenses/luci-app-loki/YACD-THIRD-PARTY-NOTICES
	$(INSTALL_DATA) ../yacd-loki/licenses/THIRD_PARTY_INVENTORY.json $(PKG_BUILD_DIR)/root/usr/share/licenses/luci-app-loki/YACD-THIRD-PARTY-INVENTORY
	$(INSTALL_DATA) ../fe-app-loki/licenses/lucide-LICENSE.txt $(PKG_BUILD_DIR)/root/usr/share/licenses/luci-app-loki/LUCIDE-LICENSE
	$(INSTALL_DATA) ../fe-app-loki/licenses/lucide-provenance.json $(PKG_BUILD_DIR)/root/usr/share/licenses/luci-app-loki/LUCIDE-PROVENANCE
	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(LOKI_COMPILED_VERSION)/g' $(PKG_BUILD_DIR)/htdocs/luci-static/resources/view/loki/main.js
endef

# The SDK's uci-defaults runner commits every pending UCI package.
define Package/luci-app-loki/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/usr/bin/loki luci_postinst >/dev/null 2>&1
endef

define Package/luci-app-loki/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/usr/bin/loki luci_prerm >/dev/null 2>&1
endef

include $(TOPDIR)/feeds/luci/luci.mk

# The locale belongs to LoKi; installing it must not edit shared LuCI settings.
define Package/luci-i18n-loki-ru
	SECTION:=luci
	CATEGORY:=LuCI
	TITLE:=LoKi - Russian translation
	HIDDEN:=1
	DEPENDS:=luci-app-loki
	EXTRA_DEPENDS:=luci-app-loki (>=$(PKG_PO_VERSION))
	LICENSE:=GPL-2.0-or-later
	URL:=https://github.com/Zagorsky17/LoKi
	MAINTAINER:=Zagorsky17
	VERSION:=$(PKG_PO_VERSION)
	PKGARCH:=all
endef

define Package/luci-i18n-loki-ru/description
	Russian translation for the LoKi page
endef

define Package/luci-i18n-loki-ru/install
	$(INSTALL_DIR) $(1)$(LUCI_LIBRARYDIR)/i18n
	po2lmo $(CURDIR)/po/ru/loki.po $(1)$(LUCI_LIBRARYDIR)/i18n/loki.ru.lmo
	$(INSTALL_DIR) $(1)/usr/share/licenses/luci-i18n-loki-ru
	$(INSTALL_DATA) ../LICENSE $(1)/usr/share/licenses/luci-i18n-loki-ru/LICENSE
endef

$(eval $(call BuildPackage,luci-i18n-loki-ru))

# call BuildPackage - OpenWrt buildroot signature
