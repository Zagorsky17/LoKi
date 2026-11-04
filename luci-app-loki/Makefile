# Modified for LoKi on 2026-11-04: include the unchanged project license.
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
LUCI_PKGARCH:=all
LUCI_LANG.ru:=Русский (Russian)
LUCI_LANG.en:=English
LUCI_MAINTAINER:=Zagorsky17
LUCI_DESCRIPTION:=Web interface for LoKi
# shortcut: Preserve esbuild output; recheck SDK jsmin before enabling a second minifier.
LUCI_MINIFY_JS:=0

PKG_LICENSE:=GPL-2.0-or-later
LUCI_LANGUAGES:=en ru

define Build/Prepare/$(PKG_NAME)
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/share/licenses/luci-app-loki
	$(INSTALL_DATA) ../LICENSE $(PKG_BUILD_DIR)/root/usr/share/licenses/luci-app-loki/LICENSE
	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(LOKI_COMPILED_VERSION)/g' $(PKG_BUILD_DIR)/htdocs/luci-static/resources/view/loki/main.js
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
