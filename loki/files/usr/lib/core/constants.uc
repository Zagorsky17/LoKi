// Modified for LoKi on 2026-10-31: use the project release repository.
// Loki's own names, paths and marks; the loki-core configuration's are in singbox/constants.uc.

return {
    LOKI_VERSION: "__COMPILED_VERSION_VARIABLE__",
    LOKI_CONFIG_NAME: "loki",
    LOKI_BIN: "/usr/bin/loki",
    LOKI_RPC_OBJECT: "loki",
    LOKI_RPC_DIRECTORY: "/var/run/loki/rpc",
    LOKI_SERVICE_INIT: "/etc/init.d/loki",
    // START in the init script, which names its rc.d links.
    LOKI_START_PRIORITY: "99",
    LOKI_RELEASE_REPO: "Zagorsky17/LoKi",
    LOKI_LUCI_VIEW_DIR: "/www/luci-static/resources/view/loki",
    LOKI_LUCI_I18N_DOMAIN: "loki",
    // Tags match at the start of a message, so a LuCI login on a Loki page stays out.
    LOKI_LOG_PATTERN: "^\\(loki\\|loki-core\\)\\|^procd: .*\\(loki\\|loki-core\\)",

    RT_TABLE_NAME: "loki",

    NFT_TABLE_NAME: "loki",
    NFT_LOCALV4_SET_NAME: "localv4",
    NFT_LOCALV6_SET_NAME: "localv6",
    NFT_INTERFACE_SET_NAME: "loki_interfaces",
    NFT_PAUSE_CHAIN_NAME: "capture_pause",
    NFT_FAKEIP_MARK: "0x04000000",
    NFT_OUTBOUND_MARK: "0x08000000",
    // What the router itself sends to loki-core: a mark of its own keeps rule 104 off its lookups.
    NFT_ROUTER_MARK: "0x10000000",
    // A redirect hooked earlier would take a query before Loki sees it.
    NFT_DNS_REDIRECT_PRIORITY: -101,
    NFT_SYSTEM_DNS_REDIRECT_PRIORITY: -100,

    SB_REQUIRED_VERSION: "1.14.4-r8"
};
