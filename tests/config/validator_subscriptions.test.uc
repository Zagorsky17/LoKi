let t = require("t");
let v = require("validation");
let fixture = require("fixture");

t.test("invalid rename pattern", () => {
    v.refuses({
        "settings": {
            "dns_server": [
                "1.1.1.1"
            ],
            "bootstrap_dns_server": [
                "1.1.1.1"
            ],
            "service_listen_address": "127.0.0.1"
        },
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "subscription_url": [
            {
                ".name": "source",
                "section": "proxy",
                "url": "https://example.com/subscription",
                "tag": "sub1",
                "override_rename": [
                    "([ => x"
                ]
            }
        ]
    }, "Invalid rename pattern");
});

t.test("rename rule without a replacement", () => {
    v.refuses({
        "settings": {
            "dns_server": [
                "1.1.1.1"
            ],
            "bootstrap_dns_server": [
                "1.1.1.1"
            ],
            "service_listen_address": "127.0.0.1"
        },
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "subscription_url": [
            {
                ".name": "source",
                "section": "proxy",
                "url": "https://example.com/subscription",
                "tag": "sub1",
                "override_rename": [
                    "^HK-(.*)$"
                ]
            }
        ]
    }, "must be written as 'pattern => replacement'");
});

t.test("group reference followed by a letter", () => {
    v.refuses({
        "settings": {
            "dns_server": [
                "1.1.1.1"
            ],
            "bootstrap_dns_server": [
                "1.1.1.1"
            ],
            "service_listen_address": "127.0.0.1"
        },
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "subscription_url": [
            {
                ".name": "source",
                "section": "proxy",
                "url": "https://example.com/subscription",
                "tag": "sub1",
                "override_rename": [
                    "^HK-(.*)$ => $1mbps"
                ]
            }
        ]
    }, "must write '${1}' where a letter follows the group number");
});

t.test("unambiguous rename replacements", () => {
    v.accepts({
        "settings": {
            "dns_server": [
                "1.1.1.1"
            ],
            "bootstrap_dns_server": [
                "1.1.1.1"
            ],
            "service_listen_address": "127.0.0.1"
        },
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "subscription_url": [
            {
                ".name": "source",
                "section": "proxy",
                "url": "https://example.com/subscription",
                "tag": "sub1",
                "override_rename": [
                    "^HK-(.*)$ => ${1}mbps",
                    "^US-(.*)$ => $12",
                    "^JP-(.*)$ => $$1x",
                    "^SG-(.*)$ => $1-fast",
                    "^DE-(.*)$ => "
                ]
            }
        ]
    });
});

t.test("invalid patch JSON", () => {
    v.refuses({
        "settings": {
            "dns_server": [
                "1.1.1.1"
            ],
            "bootstrap_dns_server": [
                "1.1.1.1"
            ],
            "service_listen_address": "127.0.0.1"
        },
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "subscription_url": [
            {
                ".name": "source",
                "section": "proxy",
                "url": "https://example.com/subscription",
                "tag": "sub1",
                "override_patch": "not json"
            }
        ]
    }, "not valid JSON");
});

t.test("patch that is not an object", () => {
    v.refuses({
        "settings": {
            "dns_server": [
                "1.1.1.1"
            ],
            "bootstrap_dns_server": [
                "1.1.1.1"
            ],
            "service_listen_address": "127.0.0.1"
        },
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "subscription_url": [
            {
                ".name": "source",
                "section": "proxy",
                "url": "https://example.com/subscription",
                "tag": "sub1",
                "override_patch": "[1,2]"
            }
        ]
    }, "must be a JSON object");
});

t.test("patch setting the cascade detour", () => {
    v.refuses({
        "settings": {
            "dns_server": [
                "1.1.1.1"
            ],
            "bootstrap_dns_server": [
                "1.1.1.1"
            ],
            "service_listen_address": "127.0.0.1"
        },
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "subscription_url": [
            {
                ".name": "source",
                "section": "proxy",
                "url": "https://example.com/subscription",
                "tag": "sub1",
                "override_patch": "{\"detour\":\"hop\"}"
            }
        ]
    }, "must not set 'detour': the cascade connection of the subscription fills it in");
});

t.test("patch reaching a field with no control of its own", () => {
    v.accepts({
        "settings": {
            "dns_server": [
                "1.1.1.1"
            ],
            "bootstrap_dns_server": [
                "1.1.1.1"
            ],
            "service_listen_address": "127.0.0.1"
        },
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "subscription_url": [
            {
                ".name": "source",
                "section": "proxy",
                "url": "https://example.com/subscription",
                "tag": "sub1",
                "override_patch": "{\"tcp_fast_open\":true,\"connect_timeout\":\"5s\",\"tls\":{\"insecure\":true,\"server_name\":\"example.org\",\"alpn\":[\"h2\"]},\"multiplex\":{\"enabled\":true,\"protocol\":\"h2mux\",\"max_streams\":8}}"
            }
        ]
    });
});

t.test("a complete override passes", () => {
    v.accepts({
        "settings": {
            "dns_server": [
                "1.1.1.1"
            ],
            "bootstrap_dns_server": [
                "1.1.1.1"
            ],
            "service_listen_address": "127.0.0.1"
        },
        "section": [
            {
                ".name": "hop",
                "enabled": "1",
                "action": "connection"
            },
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection",
                "outbound_detour_enabled": "1",
                "outbound_detour_section": "hop"
            }
        ],
        "connection_link": fixture.links("hop", [
            "socks5://127.0.0.1:1080#Hop"
        ]),
        "subscription_url": [
            {
                ".name": "source",
                "section": "proxy",
                "url": "https://example.com/subscription",
                "tag": "sub1",
                "override_prefix": "[Premium] ",
                "override_suffix": " *",
                "override_rename": [
                    "^HK-(.*)$ => Hong Kong $1",
                    "-([0-9]+)$ => #$1"
                ],
                "override_patch": "{\"packet_encoding\":\"xudp\",\"tls\":{\"insecure\":true},\"multiplex\":{\"enabled\":true,\"protocol\":\"h2mux\"}}"
            }
        ]
    });
});

t.test("subscription request profiles, filters and a local source pass", () => {
    v.accepts({
        "settings": {
            "dns_server": [
                "1.1.1.1"
            ],
            "bootstrap_dns_server": [
                "1.1.1.1"
            ]
        },
        "section": [
            {
                ".name": "hop",
                "enabled": "1",
                "action": "connection",
                "outbound_jsons": [
                    "{\"type\":\"socks\",\"tag\":\"hop-node\",\"server\":\"127.0.0.1\",\"server_port\":1080}"
                ]
            },
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection",
                "outbound_detour_enabled": "1",
                "outbound_detour_section": "hop"
            }
        ],
        "connection_link": fixture.links("proxy", [
            "vless://id@example.com:443?security=tls#Manual"
        ]),
        "subscription_url": [
            {
                ".name": "source",
                "section": "proxy",
                "url": "https://example.com/subscription",
                "header": [
                    "User-Agent: Happ",
                    "X-HWID: router-hwid",
                    "X-Device-OS: OpenWrt Linux",
                    "X-Test: one",
                    "x-test: two",
                    "X-Empty:"
                ],
                "subscription_update_enabled": "0",
                "download_via_proxy_enabled": "1",
                "download_via_proxy_section": "hop",
                "tag": "premium",
                "server_filter_mode": "include",
                "include_regex": "^(US|DE)",
                "exclude_regex": "expired"
            },
            {
                ".name": "source_auto",
                "section": "proxy",
                "url": "https://example.com/auto",
                "tag": "sub2",
                "header": [
                    "X-HWID: configured-hwid"
                ]
            },
            {
                ".name": "source_without_hwid",
                "section": "proxy",
                "url": "https://example.com/no-hwid",
                "tag": "sub3"
            },
            {
                ".name": "source_local",
                "section": "proxy",
                "url": "/etc/loki/local-subscription.txt",
                "subscription_update_enabled": "1",
                "subscription_update_interval": "invalid",
                "download_via_proxy_enabled": "1",
                "download_via_proxy_section": "proxy",
                "header": [
                    "Broken Header"
                ],
                "show_dashboard_metadata": "1",
                "tag": "local",
                "server_filter_mode": "include",
                "include_regex": "^Local",
                "exclude_regex": "Expired"
            }
        ],
        "urltest": [
            {
                ".name": "fast",
                "section": "proxy",
                "name": "Fastest",
                "server_filter_mode": "include",
                "include_regex": "🇺🇸",
                "exclude_regex": "slow"
            }
        ]
    });
});

t.test("a section may hold one subscription twice", () => {
    v.accepts({
        section: [ { ".name": "proxy", label: "Main", enabled: "1", action: "connection" } ],
        subscription_url: [
            { ".name": "one", section: "proxy", url: "https://one.example/sub", tag: "sub1" },
            { ".name": "two", section: "proxy", url: "https://one.example/sub", tag: "sub2" }
        ]
    });
});

t.done();
