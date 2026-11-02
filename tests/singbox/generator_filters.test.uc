let t = require("t");
let fixture = require("fixture");
let q = require("sbconfig");
let generator = require("singbox.generator");

function build(data) {
    fixture.seed(data);
    return generator.build({ service_address: "127.0.0.1" });
}

const SETTINGS = { dns_server: [ "1.1.1.1" ], bootstrap_dns_server: [ "1.1.1.1" ], service_listen_address: "127.0.0.1" };

t.test("type filters reach providers natively and manual nodes through the generator", () => {
    let config = build({
        settings: SETTINGS,
        section: [ {
            ".name": "proxy", enabled: "1", action: "connection"
        } ],
        connection_link: fixture.links("proxy", [
            "vless://11111111-1111-1111-1111-111111111111@vless.example:443?security=tls#VLESS node",
            "socks5://socks.example:1080#SOCKS node",
            "ss://YWVzLTI1Ni1nY206cGFzcw@ss.example:8388#SS node"
        ]),
        subscription_url: [ {
            ".name": "source", section: "proxy", url: "https://example.com/subscription", tag: "sub1",
            server_filter_mode: "exclude", exclude_types: [ "shadowsocks", "Trojan" ]
        } ],
        section_interface: [ { ".name": "lte", section: "proxy", name: "wwan0", display_name: "LTE" } ],
        urltest: [ { ".name": "fast", section: "proxy", name: "Fast", server_filter_mode: "exclude", exclude_types: [ "socks", "direct" ] } ],
        fallback_group: [ { ".name": "backup", section: "proxy", name: "Backup" } ],
        fallback_level: [ {
            ".name": "level", group: "backup", name: "Primary", server_filter_mode: "exclude",
            exclude_types: [ "vless" ], include_groups: [ "Fast" ]
        } ]
    });

    t.eq(q.provider(config, "proxy/sub1").exclude_types, [ "shadowsocks", "trojan" ], "the provider gets the normalized type filter");

    let fast = q.outbound(config, "proxy/Fast");
    t.eq(fast.exclude_types, [ "socks" ]);
    t.excludes(fast.outbounds, "proxy/SOCKS node");
    t.excludes(fast.outbounds, "proxy/LTE", "an interface is filtered locally, never sent as a provider type");
    t.contains(fast.outbounds, "proxy/VLESS node");
    t.contains(fast.outbounds, "proxy/SS node");
    t.excludes(fast.outbounds, "proxy/Backup", "a URLTest never holds another group");

    let backup = q.outbound(config, "proxy/Backup");
    t.eq(length(backup.groups), 1);
    t.eq(backup.groups[0].exclude_types, [ "vless" ]);
    t.excludes(backup.groups[0].outbounds, "proxy/VLESS node");
    t.contains(backup.groups[0].outbounds, "proxy/Fast", "a fallback level includes the URLTest it names");
    t.contains(backup.groups[0].outbounds, "proxy/LTE", "the remaining interface still belongs to its fallback level");

    let selector = q.outbound(config, "proxy");
    t.contains(selector.outbounds, "proxy/Fast");
    t.contains(selector.outbounds, "proxy/Backup");
});

t.test("a group without members is dropped, and so is one that only pointed at it", () => {
    let config = build({
        settings: SETTINGS,
        section: [ { ".name": "proxy", enabled: "1", action: "connection" } ],
        connection_link: fixture.links("proxy", [ "socks5://socks.example:1080#Node" ]),
        urltest: [
            { ".name": "empty", section: "proxy", name: "Empty", server_filter_mode: "include" },
            { ".name": "real", section: "proxy", name: "Real", server_filter_mode: "all" }
        ],
        fallback_group: [ { ".name": "dangling", section: "proxy", name: "Dangling" } ],
        fallback_level: [ { ".name": "level", group: "dangling", name: "Only empty", server_filter_mode: "include", include_groups: [ "Empty" ] } ]
    });
    t.eq(q.outbound(config, "proxy/Empty"), null);
    t.eq(q.outbound(config, "proxy/Dangling"), null);
    t.ok(q.outbound(config, "proxy/Real") != null);
    t.excludes(q.outbound(config, "proxy").outbounds, "proxy/Dangling");
});

t.done();
