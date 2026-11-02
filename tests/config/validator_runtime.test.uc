let t = require("t");
let v = require("validation");
let fixture = require("fixture");

t.test("accepts valid", () => {
    v.accepts({
        "settings": {
            "list_update_enabled": "1",
            "update_interval": "1d",
            "latency_test_url": "https://latency.example/generate_204",
            "dns_server": [
                "https://dns.google/dns-query",
                "tls://cloudflare-dns.com",
                "quic://dns.adguard-dns.com",
                "h3://dns.google/dns-query",
                "tcp://8.8.8.8",
                "1.1.1.1"
            ],
            "bootstrap_dns_server": [
                "https://1.1.1.1/dns-query",
                "tcp://8.8.8.8"
            ],
            "dns_main_fallback_strategy": "sequential",
            "dns_bootstrap_fallback_strategy": "parallel",
            "dns_strategy": "prefer_ipv6",
            "dns_detour_enabled": "1",
            "dns_detour_section": "proxy",
            "download_lists_via_proxy": "1",
            "download_lists_via_proxy_section": "proxy"
        },
        "section": [
            {
                ".name": "detour",
                "enabled": "1",
                "action": "connection",
                "outbound_jsons": [ "{\"type\":\"direct\",\"tag\":\"Direct\"}" ],
                "destinations": "detour.example"
            },
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection",
                "ports": [
                    "80",
                    "1000-2000"
                ],
                "destinations": "commented.example # keep this note\nfull:exact-comment.example // and this note\nkeyword:clip\n" +
                    "example.org\nсайт.рф\nfull:exact.example\nfull:full:legacy.example\nfull:пример.испытание\n" +
                    "keyword:video\nkeyword:пример\nregex:^api[.]example$\nregex:^сайт[.]рф$\n" +
                    "text.example\nmünich.example\nkeyword:stream",
                "community_lists": [
                    "discord"
                ],
                "rule_set": [
                    "https://example.com/rules.srs"
                ],
                "rule_set_with_subnets": [
                    "/tmp/local.json",
                    "https://example.com/mixed.lst"
                ],
                "outbound_detour_enabled": "1",
                "outbound_detour_section": "detour"
            },
            {
                ".name": "bypass",
                "enabled": "1",
                "action": "bypass",
                "destinations": "bypass.example"
            },
            {
                ".name": "custom_dns",
                "enabled": "1",
                "action": "dns",
                "dns_server": [
                    "tls://9.9.9.9:5353",
                    "https://1.1.1.1/dns-query"
                ],
                "dns_fallback_strategy": "sequential",
                "dns_detour_enabled": "1",
                "dns_detour_section": "proxy",
                "destinations": "dns.example",
                "rule_set": [
                    "https://example.com/domain-only.srs",
                    "https://example.com/domains.lst"
                ]
            },
            {
                ".name": "device_dns",
                "enabled": "1",
                "action": "dns",
                "dns_server": [
                    "1.1.1.1"
                ],
                "fully_routed_ips": [
                    "192.0.2.2/32"
                ]
            }
        ],
        "subscription_url": [
            {
                ".name": "proxy_subscription",
                "section": "proxy",
                "url": "https://example.com/sub.txt",
                "tag": "sub1",
                "header": [
                    "User-Agent: Agent/1.0"
                ],
                "subscription_update_enabled": "1",
                "subscription_update_interval": "12h"
            }
        ],
        "urltest": [
            {
                ".name": "proxy_fastest",
                "section": "proxy",
                "name": "Fastest",
                "check_interval": "3m",
                "server_filter_mode": "include",
                "tolerance": "10000",
                "testing_url": "https://urltest.example/generate_204",
                "include_regex": "🇺🇸",
                "exclude_regex": "bad.*"
            }
        ],
        "section_interface": [
            {
                ".name": "resolver_interface",
                "section": "detour",
                "name": "wg0",
                "domain_resolver_enabled": "1",
                "domain_resolver_dns_server": [
                    "https://dns.google/dns-query",
                    "tls://1.1.1.1"
                ],
                "domain_resolver_dns_fallback_strategy": "sequential",
                "domain_resolver_dns_detour_enabled": "1",
                "domain_resolver_dns_detour_section": "proxy"
            }
        ],
    });
});

t.test("leaves the contents of proxy JSON outbounds to sing-box", () => {
    v.accepts({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection",
                "outbound_jsons": [
                    "{\"type\":\"SOCKS \",\"tag\":\"proxy\",\"server\":\"127.0.0.1\"}",
                    "{\"type\":\"a-type-from-a-newer-core\",\"tag\":\"new\"}"
                ]
            }
        ],
    });
});

t.test("refuses a JSON outbound that is not an object", () => {
    v.refuses({
        "settings": {},
        "section": [ { ".name": "proxy", "enabled": "1", "action": "connection", "outbound_jsons": [ "[1]" ] } ]
    }, "has a JSON outbound that is not a JSON object");
});

t.test("bad DNS fallback strategy", () => {
    v.refuses({
        "settings": {
            "dns_server": [
                "1.1.1.1",
                "8.8.8.8"
            ],
            "bootstrap_dns_server": [
                "77.88.8.8"
            ],
            "dns_main_fallback_strategy": "random"
        },
        "section": []
    }, "Unsupported value 'random' of 'Main DNS Query Mode' in Settings");
});

t.test("bad DNS server", () => {
    v.refuses({
        "settings": {
            "dns_server": [
                "1.1.1.1",
                "bad value"
            ],
            "bootstrap_dns_server": [
                "77.88.8.8"
            ]
        },
        "section": []
    }, "Invalid main DNS server");
});

t.test("domain Bootstrap DNS", () => {
    v.refuses({
        "settings": {
            "dns_server": [
                "1.1.1.1"
            ],
            "bootstrap_dns_server": [
                "bootstrap.example.com"
            ]
        },
        "section": []
    }, "must use an IP address");
});

t.test("bad DNS strategy", () => {
    v.refuses({
        "settings": {
            "dns_strategy": "auto"
        },
        "section": []
    }, "Unsupported DNS strategy 'auto'");
});

t.test("empty main DNS list", () => {
    v.refuses({
        "settings": {
            "dns_server": [],
            "bootstrap_dns_server": [
                "77.88.8.8"
            ]
        },
        "section": []
    }, "At least one main DNS server is required");
});

t.test("empty Bootstrap DNS list", () => {
    v.refuses({
        "settings": {
            "dns_server": [
                "77.88.8.8"
            ],
            "bootstrap_dns_server": []
        },
        "section": []
    }, "At least one Bootstrap DNS server is required");
});

t.test("DNS detour bypass", () => {
    v.refuses({
        "settings": {
            "dns_detour_enabled": "1",
            "dns_detour_section": "bypass"
        },
        "section": [
            {
                ".name": "bypass",
                "enabled": "1",
                "action": "bypass"
            }
        ]
    }, "whose action is 'bypass'");
});

t.test("bad direct action", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "old",
                "enabled": "1",
                "action": "direct"
            }
        ]
    }, "unsupported action 'direct'");
});

t.test("a Connection section without servers is accepted and skipped with a warning", () => {
    let result = v.accepts({
        "settings": {},
        "section": [
            {
                ".name": "empty",
                "enabled": "1",
                "action": "connection"
            }
        ]
    });
    t.contains(result.logs, "[warn] Section 'empty' has no servers and is skipped");
});

t.test("bad DNS rule server", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "dns",
                "enabled": "1",
                "action": "dns",
                "dns_server": "bad value",
                "destinations": "example.org"
            }
        ]
    }, "invalid DNS server");
});

t.test("bad DNS rule protocol", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "dns",
                "enabled": "1",
                "action": "dns",
                "dns_server": [
                    "http://9.9.9.9/dns-query"
                ],
                "destinations": "example.org"
            }
        ]
    }, "unsupported DNS server URI scheme; use udp, tcp, tls, quic, https or h3");
});

t.test("bad DNS rule fallback strategy", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "dns",
                "enabled": "1",
                "action": "dns",
                "dns_server": [
                    "9.9.9.9",
                    "1.1.1.1"
                ],
                "dns_fallback_strategy": "random",
                "destinations": "example.org"
            }
        ]
    }, "unsupported DNS query mode 'random'");
});

t.test("DNS rule without domain matchers", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "dns",
                "enabled": "1",
                "action": "dns",
                "dns_server": "9.9.9.9"
            }
        ]
    }, "needs a domain, a built-in list, a rule set or a device");
});

t.test("a DNS section names the address it cannot match", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "dns",
                "enabled": "1",
                "action": "dns",
                "dns_server": "9.9.9.9",
                "destinations": "example.org\n192.0.2.0/24"
            }
        ]
    }, "Section 'dns' matches DNS queries by domain only, so it cannot use the address '192.0.2.0/24'");
});

t.test("a routing section takes domains and addresses side by side", () => {
    v.accepts({
        "settings": {},
        "section": [
            {
                ".name": "bypass",
                "enabled": "1",
                "action": "bypass",
                "destinations": "example.org, 192.0.2.0/24 2001:db8::/32\nfull:exact.example # note"
            }
        ]
    });
});

t.test("an entry that is neither a domain nor an address is named", () => {
    for (let entry in [ "192.0.2", "example.123", "bad:example.org", "2001:db8::/129" ])
        v.refuses({
            "settings": {},
            "section": [
                {
                    ".name": "bypass",
                    "enabled": "1",
                    "action": "bypass",
                    "destinations": "example.org\n" + entry
                }
            ]
        }, "Invalid condition '" + entry + "' in section 'bypass'");
});

t.test("DNS rule subnet extraction", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "dns",
                "enabled": "1",
                "action": "dns",
                "dns_server": "9.9.9.9",
                "rule_set_with_subnets": [
                    "https://example.com/mixed.srs"
                ]
            }
        ]
    }, "domain-only rule sets");
});

t.test("DNS rule unsupported detour", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "dns",
                "enabled": "1",
                "action": "dns",
                "dns_server": "9.9.9.9",
                "dns_detour_enabled": "1",
                "dns_detour_section": "bypass",
                "destinations": "example.org"
            },
            {
                ".name": "bypass",
                "enabled": "1",
                "action": "bypass",
                "destinations": "bypass.example"
            }
        ]
    }, "whose action is 'bypass'");
});

t.test("bad interface resolver server", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "vpn",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "section_interface": [
            {
                ".name": "iface",
                "section": "vpn",
                "name": "wg0",
                "domain_resolver_enabled": "1",
                "domain_resolver_dns_server": [
                    "http://dns.example"
                ]
            }
        ]
    }, "unsupported DNS server URI scheme; use udp, tcp, tls, quic, https or h3");
});

t.test("bad interface resolver query mode", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "vpn",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "section_interface": [
            {
                ".name": "iface",
                "section": "vpn",
                "name": "wg0",
                "domain_resolver_enabled": "1",
                "domain_resolver_dns_server": [
                    "1.1.1.1",
                    "8.8.8.8"
                ],
                "domain_resolver_dns_fallback_strategy": "random"
            }
        ]
    }, "unsupported DNS query mode 'random'");
});

t.test("interface resolver detour without a section", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "vpn",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "section_interface": [
            {
                ".name": "iface",
                "section": "vpn",
                "name": "wg0",
                "domain_resolver_enabled": "1",
                "domain_resolver_dns_server": [
                    "1.1.1.1"
                ],
                "domain_resolver_dns_detour_enabled": "1"
            }
        ]
    }, "routes DNS through a section, but no section is selected");
});

t.test("interface resolver detour through its own section", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "vpn",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "section_interface": [
            {
                ".name": "iface",
                "section": "vpn",
                "name": "wg0",
                "domain_resolver_enabled": "1",
                "domain_resolver_dns_server": [
                    "1.1.1.1"
                ],
                "domain_resolver_dns_detour_enabled": "1",
                "domain_resolver_dns_detour_section": "vpn"
            }
        ]
    }, "cannot send DNS through its own section");
});

t.test("interface resolver detour with an unsupported action", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "vpn",
                "enabled": "1",
                "action": "connection"
            },
            {
                ".name": "bypass",
                "enabled": "1",
                "action": "bypass",
                "destinations": "bypass.example"
            }
        ],
        "section_interface": [
            {
                ".name": "iface",
                "section": "vpn",
                "name": "wg0",
                "domain_resolver_enabled": "1",
                "domain_resolver_dns_server": [
                    "1.1.1.1"
                ],
                "domain_resolver_dns_detour_enabled": "1",
                "domain_resolver_dns_detour_section": "bypass"
            }
        ]
    }, "whose action is 'bypass'");
});

t.test("bad port", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection",
                "ports": [
                    "70000"
                ]
            }
        ]
    }, "Invalid port condition '70000'");
});

t.test("bad subscription", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "subscription_url": [
            {
                ".name": "proxy_sub_1",
                "section": "proxy",
                "url": "https://example.com/a| Agent",
                "tag": "sub1"
            }
        ]
    }, "set the User-Agent in the subscription headers instead");
});

t.test("bad local subscription", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "subscription_url": [
            {
                ".name": "proxy_sub_1",
                "section": "proxy",
                "url": "relative/subscription.txt",
                "tag": "sub1"
            }
        ]
    }, "absolute local path");
});

t.test("bad subscription header", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "subscription_url": [
            {
                ".name": "proxy_sub_1",
                "section": "proxy",
                "url": "https://example.com/sub.txt",
                "tag": "sub1",
                "header": [
                    "Broken Header: value"
                ]
            }
        ]
    }, "invalid header 1");
});

t.test("bad latency URL", () => {
    v.refuses({
        "settings": {
            "latency_test_url": "ftp://example.com/ping"
        },
        "section": []
    }, "'Latency test URL' in Settings");
});

t.test("bad URLTest tolerance", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "urltest": [
            {
                ".name": "fast",
                "section": "proxy",
                "name": "Fast",
                "tolerance": "10001"
            }
        ]
    }, "Use a number from 0 to 10000");
});

t.test("bad URLTest expected status", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "urltest": [
            {
                ".name": "fast",
                "section": "proxy",
                "name": "Fast",
                "expected_status": "600"
            }
        ]
    }, "Invalid 'Expected status'");
});

t.test("URLTest interval longer than idle timeout", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "urltest": [
            {
                ".name": "fast",
                "section": "proxy",
                "name": "Fast",
                "check_interval": "31m"
            }
        ]
    }, "is longer than its idle timeout");
});

t.test("a URLTest interval that is not a duration names its option", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "urltest": [
            {
                ".name": "fast",
                "section": "proxy",
                "name": "Fast",
                "check_interval": "soon"
            }
        ]
    }, "'Check interval' of URLTest 'Fast' in section 'proxy'");
});

t.test("bad detour", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "first",
                "enabled": "1",
                "action": "connection"
            },
            {
                ".name": "second",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "connection_link": [
            ...fixture.links("first", [ "socks://127.0.0.1:1080#first" ], { detour_section: "second" }),
            ...fixture.links("second", [ "socks://127.0.0.1:1081#second" ], { detour_section: "first" })
        ]
    }, "loops back through section");
});

t.test("bad list reference", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection",
                "rule_set": [
                    "ftp://example.com/list.lst"
                ]
            }
        ]
    }, "is neither an http(s) URL nor an absolute path");
});

t.test("bad filter regex", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "urltest": [
            {
                ".name": "fast",
                "section": "proxy",
                "name": "Fast",
                "server_filter_mode": "include",
                "include_regex": "["
            }
        ]
    }, "Invalid regular expression");
});

t.test("bad filter mode", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "urltest": [
            {
                ".name": "bad",
                "section": "proxy",
                "name": "Bad mode",
                "server_filter_mode": "direct"
            }
        ]
    }, "Invalid server filter mode 'direct'");
});


// sing-box check accepts both, and the endpoint then fails to start.
t.test("unsupported server records are not interpreted or included in validation logs", () => {
    let result = v.accepts({
        section: [ { ".name": "main", enabled: "1", action: "connection" } ],
        connection_link: fixture.links("main", [ "socks://127.0.0.1:1080#local" ]),
        server: [ { ".name": "private-server-name", label: "private-server-label", enabled: "1", protocol: "json_inbound",
            inbound_json: "invalid-private-json", listen_port: "not-a-port", reality_private_key: "private-key" } ],
        server_client: [ { ".name": "private-account", server: "private-server-name", password: "private-password" } ]
    });
    t.excludes(sprintf("%J", result.logs), "private-");
});

t.done();
