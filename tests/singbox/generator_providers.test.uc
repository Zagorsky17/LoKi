let t = require("t");
let fixture = require("fixture");
let q = require("sbconfig");
let generator = require("singbox.generator");

function providers_config() {
    fixture.seed({
        settings: { dns_server: [ "1.1.1.1" ], bootstrap_dns_server: [ "1.1.1.1" ] },
        section: [
            { ".name": "hop", enabled: "1", action: "connection", outbound_jsons: [ "{\"type\":\"socks\",\"tag\":\"hop-node\",\"server\":\"127.0.0.1\",\"server_port\":1080}" ] },
            { ".name": "proxy", enabled: "1", action: "connection" }
        ],
        connection_link: fixture.links("proxy", [ "vless://id@example.com:443?security=tls#Manual" ], { detour_section: "hop" }),
        subscription_url: [
            {
                ".name": "source", section: "proxy", url: "https://example.com/subscription", detour_section: "hop",
                header: [ "User-Agent: Happ", "X-HWID: router-hwid", "X-Device-OS: OpenWrt Linux", "X-Test: one", "x-test: two", "X-Empty:" ],
                subscription_update_enabled: "0", download_via_proxy_enabled: "1", download_via_proxy_section: "hop",
                tag: "premium", server_filter_mode: "include",
                include_regex: "^(US|DE)", exclude_regex: "expired"
            },
            { ".name": "source_auto", section: "proxy", url: "https://example.com/auto", tag: "sub2", header: [ "X-HWID: configured-hwid" ] },
            { ".name": "source_without_hwid", section: "proxy", url: "https://example.com/no-hwid", tag: "sub3" },
            {
                ".name": "source_local", section: "proxy", url: "/etc/loki/local-subscription.txt",
                subscription_update_enabled: "1", subscription_update_interval: "invalid",
                download_via_proxy_enabled: "1", download_via_proxy_section: "proxy",
                header: [ "Broken Header" ], show_dashboard_metadata: "1",
                tag: "local", server_filter_mode: "include", include_regex: "^Local", exclude_regex: "Expired",
                detour_section: "hop"
            }
        ],
        urltest: [ { ".name": "fast", section: "proxy", name: "Fastest", server_filter_mode: "include", include_regex: "🇺🇸", exclude_regex: "slow" } ]
    });
    return generator.build({ controller_secret: fixture.CONTROLLER_SECRET, service_address: "127.0.0.1" });
}

const REMOVED_PARAMETER_FILTERS = [ "include_types", "include_transports", "include_securities", "exclude_types", "exclude_transports", "exclude_securities" ];

t.test("remote subscriptions become providers carrying their own request profile", () => {
    let config = providers_config();
    t.eq(q.tags(config.providers), [ "proxy/premium", "proxy/sub2", "proxy/sub3", "proxy/local" ]);

    let remote = q.provider(config, "proxy/premium");
    t.eq(remote.url, "https://example.com/subscription");
    t.eq(remote.headers["User-Agent"], [ "Happ" ]);
    t.eq([ remote.headers["X-HWID"], remote.headers["X-Device-OS"] ], [ [ "router-hwid" ], [ "OpenWrt Linux" ] ]);
    t.eq(remote.headers["X-Test"], [ "one", "two" ], "repeated headers combine case-insensitively");
    t.eq(remote.headers["X-Empty"], [ "" ], "an empty header value stays valid");
    t.eq(remote.user_agent, null);
    t.eq([ remote.download_detour, remote.override.detour ], [ "hop", "hop" ]);
    t.eq(remote.update_interval, null, "disabled updates omit the interval");
    t.eq(remote.tag_prefix, null);
    t.eq([ remote.include, remote.exclude ], [ "(?:(?:^(US|DE)))", "(?:(?:expired))" ]);
    for (let key in REMOVED_PARAMETER_FILTERS)
        t.eq(remote[key], null, key);

    let automatic = q.provider(config, "proxy/sub2");
    t.eq([ automatic.user_agent, automatic.headers["User-Agent"], automatic.headers["X-HWID"] ], [ null, null, [ "configured-hwid" ] ],
        "an unset User-Agent is not materialized");
    t.eq(automatic.update_interval, "1h");
    t.eq(q.provider(config, "proxy/sub3").headers["X-HWID"], null, "no stored HWID, no header");
});

t.test("a local subscription is read from its path with remote-only options left out", () => {
    let local = q.provider(providers_config(), "proxy/local");
    t.eq([ local.type, local.path ], [ "local", "/etc/loki/local-subscription.txt" ]);
    t.eq([ local.url, local.headers, local.update_interval, local.download_detour ], [ null, null, null, null ]);
    t.eq([ local.override.detour, local.include, local.exclude ], [ "hop", "(?:(?:^Local))", "(?:(?:Expired))" ]);
});

t.test("a subscription override carries the name changes, the cascade and the patch", () => {
    fixture.seed({
        settings: { dns_server: [ "1.1.1.1" ], bootstrap_dns_server: [ "1.1.1.1" ], service_listen_address: "127.0.0.1" },
        section: [
            { ".name": "hop", enabled: "1", action: "connection" },
            { ".name": "proxy", enabled: "1", action: "connection" }
        ],
        connection_link: fixture.links("hop", [ "socks5://127.0.0.1:1080#Hop" ]),
        subscription_url: [ {
            ".name": "source", section: "proxy", url: "https://example.com/subscription", tag: "sub1", detour_section: "hop",
            override_prefix: "[Premium] ", override_suffix: " *",
            override_rename: [ "^HK-(.*)$ => Hong Kong $1", "-([0-9]+)$ => #$1" ],
            override_patch: "{\"packet_encoding\":\"xudp\",\"tls\":{\"insecure\":true},\"multiplex\":{\"enabled\":true,\"protocol\":\"h2mux\"}}"
        } ]
    });
    let provider = q.provider(generator.build({ controller_secret: fixture.CONTROLLER_SECRET, service_address: "127.0.0.1" }), "proxy/sub1");
    let override = provider.override;
    t.eq([ override.prefix, override.suffix ], [ "[Premium] ", " *" ]);
    t.eq(override.rename, [ { pattern: "^HK-(.*)$", target: "Hong Kong $1" }, { pattern: "-([0-9]+)$", target: "#$1" } ]);
    t.eq(override.detour, "hop", "the subscription's cascade reaches the override");
    t.eq(override.patch, { packet_encoding: "xudp", tls: { insecure: true }, multiplex: { enabled: true, protocol: "h2mux" } });
    for (let key in [ "tcp_fast_open", "tcp_multi_path", "udp_fragment", "connect_timeout", "tls", "outbound_detour", "remove_emojis" ])
        t.ok(override[key] == null && provider[key] == null, "removed provider option " + key);
});

t.test("two subscriptions of one address are two providers", () => {
    fixture.seed({
        settings: { dns_server: [ "1.1.1.1" ], bootstrap_dns_server: [ "1.1.1.1" ], service_listen_address: "127.0.0.1" },
        section: [
            { ".name": "hop", enabled: "1", action: "connection" },
            { ".name": "proxy", enabled: "1", action: "connection" }
        ],
        connection_link: fixture.links("hop", [ "socks5://127.0.0.1:1080#Hop" ]),
        subscription_url: [
            { ".name": "direct", section: "proxy", url: "https://example.com/sub", tag: "sub1", server_filter_mode: "include", include_regex: "^US" },
            { ".name": "cascaded", section: "proxy", url: "https://example.com/sub", tag: "sub2", detour_section: "hop", subscription_update_enabled: "0" }
        ]
    });
    let config = generator.build({ controller_secret: fixture.CONTROLLER_SECRET, service_address: "127.0.0.1" });
    t.eq(q.tags(config.providers), [ "proxy/sub1", "proxy/sub2" ]);
    let direct = q.provider(config, "proxy/sub1");
    let cascaded = q.provider(config, "proxy/sub2");
    t.eq([ direct.url, cascaded.url ], [ "https://example.com/sub", "https://example.com/sub" ]);
    t.eq([ direct.include, cascaded.include ], [ "(?:(?:^US))", null ]);
    t.eq([ direct.override, cascaded.override.detour ], [ null, "hop" ]);
    t.eq([ direct.update_interval, cascaded.update_interval ], [ "1h", null ]);
});

t.test("the section selector and its groups consume every provider", () => {
    let config = providers_config();
    let manual = q.outbound(config, "proxy/Manual");
    t.eq([ manual.type, manual.link, manual.detour ], [ "parser", "vless://id@example.com:443?security=tls#Manual", "hop" ]);
    let selector = q.outbound(config, "proxy");
    t.eq(length(selector.providers), 4);
    t.eq(selector.outbounds[1], "proxy/Manual");
    t.eq([ selector.exclude_provider_group_members, selector.exclude_provider_dependencies ], [ null, null ]);
    let urltest = q.outbound(config, "proxy/Fastest");
    t.eq(length(urltest.providers), 4);
    for (let key in REMOVED_PARAMETER_FILTERS)
        t.eq(urltest[key], null, key);
    t.contains(urltest.include, "🇺🇸");
    t.contains(urltest.exclude, "slow");
});

t.done();
