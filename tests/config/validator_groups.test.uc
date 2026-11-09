let t = require("t");
let v = require("validation");
let fixture = require("fixture");

t.test("accepts fixture", () => {
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
        "connection_link": fixture.links("proxy", [
            "vless://11111111-1111-1111-1111-111111111111@vless.example:443?security=tls#VLESS node",
            "socks5://socks.example:1080#SOCKS node",
            "ss://YWVzLTI1Ni1nY206cGFzcw@ss.example:8388#SS node"
        ]),
        "subscription_url": [
            {
                ".name": "source",
                "section": "proxy",
                "url": "https://example.com/subscription",
                "tag": "sub1",
                "server_filter_mode": "exclude",
                "exclude_types": [
                    "shadowsocks",
                    "Trojan"
                ]
            }
        ],
        "urltest": [
            {
                ".name": "fast",
                "section": "proxy",
                "name": "Fast",
                "server_filter_mode": "exclude",
                "exclude_types": [
                    "socks"
                ]
            }
        ],
        "fallback_group": [
            {
                ".name": "backup",
                "section": "proxy",
                "name": "Backup"
            }
        ],
        "fallback_level": [
            {
                ".name": "level",
                "group": "backup",
                "name": "Primary",
                "server_filter_mode": "exclude",
                "exclude_types": [
                    "vless"
                ],
                "include_groups": [
                    "Fast"
                ]
            }
        ]
    });
});

t.test("accepts prune", () => {
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
        "connection_link": fixture.links("proxy", [
            "socks5://socks.example:1080#Node"
        ]),
        "urltest": [
            {
                ".name": "empty",
                "section": "proxy",
                "name": "Empty",
                "server_filter_mode": "include"
            },
            {
                ".name": "real",
                "section": "proxy",
                "name": "Real",
                "server_filter_mode": "all"
            }
        ],
        "fallback_group": [
            {
                ".name": "dangling",
                "section": "proxy",
                "name": "Dangling"
            }
        ],
        "fallback_level": [
            {
                ".name": "level",
                "group": "dangling",
                "name": "Only empty",
                "server_filter_mode": "include",
                "include_groups": [
                    "Empty"
                ]
            }
        ]
    });
});

t.test("missing URLTest reference", () => {
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
        "connection_link": fixture.links("proxy", [
            "socks5://socks.example:1080#Node"
        ]),
        "fallback_group": [
            {
                ".name": "group",
                "section": "proxy",
                "name": "Group"
            }
        ],
        "fallback_level": [
            {
                ".name": "level",
                "group": "group",
                "name": "Level",
                "server_filter_mode": "include",
                "include_groups": [
                    "Nope"
                ]
            }
        ]
    }, "which does not exist");
});

t.test("nested fallback reference", () => {
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
        "connection_link": fixture.links("proxy", [
            "socks5://socks.example:1080#Node"
        ]),
        "fallback_group": [
            {
                ".name": "outer",
                "section": "proxy",
                "name": "Outer"
            },
            {
                ".name": "inner",
                "section": "proxy",
                "name": "Inner"
            }
        ],
        "fallback_level": [
            {
                ".name": "outer_level",
                "group": "outer",
                "name": "Level",
                "server_filter_mode": "include",
                "include_groups": [
                    "Inner"
                ]
            },
            {
                ".name": "inner_level",
                "group": "inner",
                "name": "Level",
                "server_filter_mode": "all"
            }
        ]
    }, "which does not exist");
});

t.test("unknown server type", () => {
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
        "connection_link": fixture.links("proxy", [
            "socks5://socks.example:1080#Node"
        ]),
        "urltest": [
            {
                ".name": "a",
                "section": "proxy",
                "name": "A",
                "server_filter_mode": "exclude",
                "exclude_types": [
                    "shadowsocksx"
                ]
            }
        ]
    }, "is not available in URLTest");
});

t.test("endpoint type in a subscription", () => {
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
        "connection_link": fixture.links("proxy", [
            "socks5://socks.example:1080#Node"
        ]),
        "subscription_url": [
            {
                ".name": "source",
                "section": "proxy",
                "url": "https://example.com/subscription",
                "tag": "sub1",
                "server_filter_mode": "exclude",
                "exclude_types": [
                    "direct"
                ]
            }
        ]
    }, "is not available in a subscription");
});

t.test("protocol loki-core removed", () => {
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
        "connection_link": fixture.links("proxy", [
            "socks5://socks.example:1080#Node"
        ]),
        "subscription_url": [
            {
                ".name": "source",
                "section": "proxy",
                "url": "https://example.com/subscription",
                "tag": "sub1",
                "server_filter_mode": "exclude",
                "exclude_types": [
                    "shadowsocksr"
                ]
            }
        ]
    }, "is not available in a subscription");
});

function fallback(group, levels) {
    return {
        section: [ { ".name": "proxy", label: "Proxy", enabled: "1", action: "connection" } ],
        fallback_group: [ { ".name": "pg", section: "proxy", name: "Fallback", ...group } ],
        fallback_level: levels ?? [ { ".name": "level", group: "pg", name: "Level" } ]
    };
}

t.test("a Fallback group with tuned health checks and every level kind passes", () => {
    v.accepts({
        section: [ {
            ".name": "proxy", enabled: "1", action: "connection",
            outbound_jsons: [
                "{\"type\":\"socks\",\"tag\":\"Alpha\",\"server\":\"127.0.0.1\",\"server_port\":1001}",
                "{\"type\":\"socks\",\"tag\":\"Beta\",\"server\":\"127.0.0.1\",\"server_port\":1002}",
                "{\"type\":\"fallback\",\"tag\":\"Nested\",\"outbounds\":[\"Alpha\"]}"
            ]
        } ],
        subscription_url: [ { ".name": "sub_main", section: "proxy", url: "https://example.com/sub", tag: "sub1", subscription_update_enabled: "1" } ],
        fallback_group: [ {
            ".name": "pg_main", section: "proxy", name: "Main fallback", health_check_url: "https://health.example/generate_204",
            health_check_interval: "12s", health_check_timeout: "4s", attempt_timeout: "9s", expected_status: "204/200-299",
            idle_timeout: "20m", interrupt_exist_connections: "1"
        } ],
        fallback_level: [
            { ".name": "pl_top", group: "pg_main", name: "Top", order: "0", server_filter_mode: "include", include_outbounds: [ "Beta" ] },
            { ".name": "pl_mixed", group: "pg_main", name: "Mixed", order: "1", server_filter_mode: "include", include_regex: "Alpha|Gamma", exclude_outbounds: [ "Gamma" ] },
            { ".name": "pl_direct", group: "pg_main", name: "Direct", order: "2", server_filter_mode: "direct" },
            { ".name": "pl_remaining", group: "pg_main", name: "Remaining", order: "3", server_filter_mode: "all" }
        ]
    });
});

t.test("a Fallback group refuses bad timings, statuses and server groups", () => {
    v.refuses(fallback({ attempt_timeout: "later" }), "'Connection timeout' of fallback group 'Fallback' in section 'Proxy'");
    for (let status in [ "200-bad", "99", "600", "299-200" ])
        v.refuses(fallback({ expected_status: status }), "Invalid 'Expected status' of fallback group 'Fallback'");
    v.refuses(fallback({ health_check_interval: "1m", idle_timeout: "10s" }), "longer than its idle timeout");
    v.refuses(fallback({}, []), "has no server groups");
    v.refuses(fallback({}, [
        { ".name": "primary", group: "pg", name: "Servers", server_filter_mode: "direct" },
        { ".name": "backup", group: "pg", name: "Servers", server_filter_mode: "all" }
    ]), "has more than one server group named 'Servers'");
});

t.done();
