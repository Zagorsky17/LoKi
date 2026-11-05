const DNS_SERVER_TAG = "dns-server";
const FAKEIP_DNS_SERVER_TAG = "fakeip-server";
const BOOTSTRAP_DNS_SERVER_TAG = "bootstrap-dns-server";
const DNSMASQ_DNS_SERVER_TAG = "dnsmasq-server";
const HOSTS_DNS_SERVER_TAG = "hosts-server";
const FAKEIP_DNS_RULE_TAG = "fakeip-dns-rule-tag";
const FAKEIP_RULESET_DNS_RULE_TAG = "fakeip-ruleset-dns-rule-tag";
const SERVICE_FAKEIP_DNS_RULE_TAG = "service-fakeip-dns-rule-tag";

const TPROXY_INBOUND_TAG = "tproxy-in";
const TPROXY_INBOUND_ADDRESS = "0.0.0.0";
const TPROXY_INBOUND6_TAG = "tproxy6-in";
const TPROXY_INBOUND6_ADDRESS = "::1";
const TPROXY_INBOUND_PORT = 1602;
const DNS_INBOUND_TAG = "dns-in";
const DNS_INBOUND_ADDRESS = "127.0.0.42";
const DNS_INBOUND_PORT = 53;
const SOURCE_DNS_INBOUND_TAG = "source-dns-in";
const SOURCE_DNS_INBOUND_ADDRESS = "::";
const SOURCE_DNS_INBOUND_PORT = 1603;
const SYSTEM_TPROXY_INBOUND_TAG = "system-in";
const SYSTEM_TPROXY_INBOUND6_TAG = "system6-in";
const SYSTEM_TPROXY_INBOUND_PORT = 1604;
const SYSTEM_DNS_INBOUND_TAG = "system-dns-in";
const SYSTEM_DNS_INBOUND_ADDRESS = "::";
const SYSTEM_DNS_INBOUND_PORT = 1605;

const DIRECT_OUTBOUND_TAG = "direct-out";
const CLASH_API_CONTROLLER_SOCKET = "/tmp/loki/controller.sock";
const HTTPS_GATEWAY_PORT = 9091;
// The mark loki-core puts on its own traffic is the one the nft table lets pass.
const OUTBOUND_MARK = hex(require("core.constants").NFT_OUTBOUND_MARK);
// The cache file keeps a name for every address until the range wraps, about 170 bytes each in
// tmpfs, hence 65536 addresses a family.
const FAKEIP_INET4_RANGE = "198.18.0.0/16";
const FAKEIP_INET6_RANGE = "fc00::/112";

const URLTEST_DEFAULT_IDLE_TIMEOUT = "30m";
const CHECK_PROXY_IP_DOMAIN = "ip.podkop.fyi";
const FAKEIP_TEST_DOMAIN = "fakeip.podkop.fyi";
const TMP_SING_BOX_FOLDER = "/tmp/loki-core";

// Providers build nodes from outbounds only, so endpoint protocols and refused types are absent.
const FILTERABLE_PROVIDER_TYPES = [
    "vless", "vmess", "trojan", "shadowsocks",
    "hysteria2", "hysteria", "tuic", "anytls",
    "naive", "mieru", "snell", "shadowtls", "trusttunnel",
    "ssh", "tor", "socks", "http"
];

// Groups also hold the section's interface connections.
const FILTERABLE_GROUP_TYPES = [
    ...FILTERABLE_PROVIDER_TYPES,
    "direct"
];

// A manual link is parsed at runtime, so its outbound is typed by the link's scheme. These are
// the schemes ParseSubscriptionLink accepts; a missing one leaves the node without a protocol.
const LINK_SCHEME_OUTBOUND_TYPES = {
    "ss": "shadowsocks",
    "vmess": "vmess",
    "vless": "vless",
    "trojan": "trojan",
    "tuic": "tuic",
    "anytls": "anytls",
    "hy": "hysteria",
    "hysteria": "hysteria",
    "hy2": "hysteria2",
    "hysteria2": "hysteria2",
    "mieru": "mieru",
    "mierus": "mieru",
    "naive+https": "naive",
    "naive+quic": "naive",
    "http2": "naive",
    "http3": "naive",
    "http": "http",
    "https": "http",
    "socks": "socks",
    "socks4": "socks",
    "socks4a": "socks",
    "socks5": "socks",
    "socks5h": "socks",
    "tt": "trusttunnel"
};

// A JSON outbound must not restore protocols removed from the application.
const REMOVED_VPN_TYPES = [ "wireguard", "amneziawg", "warp", "tailscale", "openvpn", "openvpn-client", "openvpn-server", "openconnect" ];

// A subscription sets every imported server's detour from its cascade, so a patch may not.
const RESERVED_OVERRIDE_PATCH_PATHS = [ "detour" ];

const RESERVED_TAGS = {
    [DNS_SERVER_TAG]: true,
    [FAKEIP_DNS_SERVER_TAG]: true,
    [BOOTSTRAP_DNS_SERVER_TAG]: true,
    [DNSMASQ_DNS_SERVER_TAG]: true,
    [HOSTS_DNS_SERVER_TAG]: true,
    [FAKEIP_DNS_RULE_TAG]: true,
    [FAKEIP_RULESET_DNS_RULE_TAG]: true,
    [SERVICE_FAKEIP_DNS_RULE_TAG]: true,
    [TPROXY_INBOUND_TAG]: true,
    [TPROXY_INBOUND6_TAG]: true,
    [DNS_INBOUND_TAG]: true,
    [SOURCE_DNS_INBOUND_TAG]: true,
    [SYSTEM_TPROXY_INBOUND_TAG]: true,
    [SYSTEM_TPROXY_INBOUND6_TAG]: true,
    [SYSTEM_DNS_INBOUND_TAG]: true,
    [DIRECT_OUTBOUND_TAG]: true
};

function as_string(value) {
    return value == null ? "" : "" + value;
}

function removed_vpn_type(value) {
    return index(REMOVED_VPN_TYPES, lc(trim(as_string(value)))) >= 0;
}

function tag(base, postfix) {
    let candidate = as_string(base) + "-" + as_string(postfix);
    return RESERVED_TAGS[candidate] ? candidate + "-1" : candidate;
}

function outbound_tag(section_name) {
    return as_string(section_name);
}

function child_tag(section_name, display_name) {
    return as_string(section_name) + "/" + as_string(display_name);
}

function domain_resolver_tag(section_name) {
    return tag(section_name, "domain-resolver");
}

return {
    DNS_SERVER_TAG,
    FAKEIP_DNS_SERVER_TAG,
    BOOTSTRAP_DNS_SERVER_TAG,
    DNSMASQ_DNS_SERVER_TAG,
    HOSTS_DNS_SERVER_TAG,
    TPROXY_INBOUND_TAG,
    TPROXY_INBOUND_ADDRESS,
    TPROXY_INBOUND6_TAG,
    TPROXY_INBOUND6_ADDRESS,
    TPROXY_INBOUND_PORT,
    DNS_INBOUND_TAG,
    DNS_INBOUND_ADDRESS,
    DNS_INBOUND_PORT,
    SOURCE_DNS_INBOUND_TAG,
    SOURCE_DNS_INBOUND_ADDRESS,
    SOURCE_DNS_INBOUND_PORT,
    SYSTEM_TPROXY_INBOUND_TAG,
    SYSTEM_TPROXY_INBOUND6_TAG,
    SYSTEM_TPROXY_INBOUND_PORT,
    SYSTEM_DNS_INBOUND_TAG,
    SYSTEM_DNS_INBOUND_ADDRESS,
    SYSTEM_DNS_INBOUND_PORT,
    DIRECT_OUTBOUND_TAG,
    CLASH_API_CONTROLLER_SOCKET,
    HTTPS_GATEWAY_PORT,
    OUTBOUND_MARK,
    FAKEIP_INET4_RANGE,
    FAKEIP_INET6_RANGE,
    URLTEST_DEFAULT_IDLE_TIMEOUT,
    CHECK_PROXY_IP_DOMAIN,
    FAKEIP_TEST_DOMAIN,
    TMP_SING_BOX_FOLDER,
    FILTERABLE_PROVIDER_TYPES,
    FILTERABLE_GROUP_TYPES,
    REMOVED_VPN_TYPES,
    removed_vpn_type,
    RESERVED_OVERRIDE_PATCH_PATHS,
    LINK_SCHEME_OUTBOUND_TYPES,
    RESERVED_TAGS,
    tag,
    outbound_tag,
    child_tag,
    domain_resolver_tag
};
