let t = require("t");
let fixture = require("fixture");
let q = require("sbconfig");
let generator = require("singbox.generator");

function build(data) {
    fixture.seed(data);
    return generator.build({ service_address: "127.0.0.1" });
}

function runtime_tags_config() {
    return build({
        settings: { log_level: "warn", bittorrent_direct: "1" },
        section: [
            {
                ".name": "proxy", label: "Main", enabled: "1", action: "connection",
                outbound_jsons: [
                    "{\"type\":\"socks\",\"tag\":\"germany\",\"server\":\"127.0.0.1\",\"server_port\":1201}",
                    "{\"type\":\"socks\",\"tag\":\"austria\",\"server\":\"127.0.0.1\",\"server_port\":1203}",
                    "{\"type\":\"direct\",\"tag\":\"direct-out\"}",
                    "{\"type\":\"socks\",\"tag\":\"json-hop\",\"server\":\"127.0.0.1\",\"server_port\":1202}",
                    "{\"type\":\"selector\",\"tag\":\"json-group\",\"outbounds\":[\"json-hop\",\"direct-out\"],\"default\":\"json-hop\"}",
                    "{\"type\":\"direct\",\"tag\":\"service-mixed-in\"}"
                ],
                destinations: "example.org"
            },
            {
                ".name": "backup", label: "Backup", enabled: "1", action: "connection",
                outbound_jsons: [ "{\"type\":\"socks\",\"tag\":\"json-hop\",\"server\":\"127.0.0.1\",\"server_port\":1301}" ],
                destinations: "backup.example.org"
            }
        ],
        connection_link: fixture.links("proxy", [ "socks://127.0.0.1:1080#manual" ]),
        subscription_url: [ { ".name": "sub_dup", section: "proxy", url: "https://duplicate.example/sub", tag: "sub1" } ],
        section_interface: [ { ".name": "cfg-interface", section: "proxy", name: "wg0", display_name: "NL Amsterdam" } ],
        urltest: [
            { ".name": "ut_name", section: "proxy", name: "By name", server_filter_mode: "include", include_outbounds: [ "germany", "NL Amsterdam", "json-hop" ] },
            { ".name": "ut_regex", section: "proxy", name: "By regex", server_filter_mode: "include", include_regex: "^germany$" }
        ],
        fallback_group: [ { ".name": "pg_main", section: "proxy", name: "Fallback" } ],
        fallback_level: [ { ".name": "pl_main", group: "pg_main", name: "All", order: "0", server_filter_mode: "all" } ]
    });
}

t.test("every outbound runs under its section and its own name", () => {
    let config = runtime_tags_config();
    let seen = {};
    for (let item in config.outbounds) {
        t.ok(!seen[item.tag], "duplicate generated tag " + item.tag);
        seen[item.tag] = true;
    }
    for (let tag in [
        "direct-out", "Main", "Backup",
        "Main/manual", "Main/NL Amsterdam",
        "Main/germany", "Main/austria", "Main/direct-out", "Main/json-hop",
        "Main/json-group", "Main/service-mixed-in", "Backup/json-hop",
        "Main/By name", "Main/By regex", "Main/Fallback"
    ])
        t.ok(seen[tag], "missing allocated tag " + tag);
});

t.test("BitTorrent goes direct when the setting asks for it", () => {
    let torrent = q.route_rule(runtime_tags_config(), (r) => r.protocol == "bittorrent");
    t.eq([ torrent.action, torrent.outbound ], [ "route", "direct-out" ]);
    t.ok(q.has(torrent.inbound, "tproxy-in") && q.has(torrent.inbound, "tproxy6-in"));
});

t.test("the section selector lists its groups first, then its own nodes, and its own subscriptions", () => {
    let config = runtime_tags_config();
    let manual = q.outbound(config, "Main/manual");
    t.eq(manual, { type: "socks", tag: "Main/manual", server: "127.0.0.1", server_port: 1080, version: "5" });
    let selector = q.outbound(config, "Main");
    t.eq(selector.providers, [ "Main/sub1" ]);
    t.eq(selector.outbounds, [
        "Main/By name", "Main/By regex", "Main/Fallback", "Main/manual",
        "Main/NL Amsterdam", "Main/germany", "Main/austria",
        "Main/direct-out", "Main/json-hop", "Main/json-group", "Main/service-mixed-in"
    ]);
});

t.test("references inside a JSON outbound are rewritten to the allocated tags", () => {
    let group = q.outbound(runtime_tags_config(), "Main/json-group");
    t.eq(group.outbounds, [ "Main/json-hop", "Main/direct-out" ]);
    t.eq(group.default, "Main/json-hop");
});

t.test("group filters match nodes by their display name", () => {
    let config = runtime_tags_config();
    let by_name = q.outbound(config, "Main/By name");
    t.eq(sort([ ...by_name.outbounds ]), sort([ "Main/germany", "Main/NL Amsterdam", "Main/json-hop" ]));
    t.eq(q.outbound(config, "Main/By regex").outbounds, [ "Main/germany" ]);
    t.eq(by_name.providers, [ "Main/sub1" ]);
    t.contains(by_name.include, "germany", "the native provider filter is attached to the group");
    let level = q.outbound(config, "Main/Fallback").groups[0];
    t.eq([ level.tag, level.providers ], [ null, [ "Main/sub1" ] ]);
});

t.test("manual link names stay the same across standard and parser outbounds", () => {
    let config = build({
        settings: {},
        section: [ {
            ".name": "links", label: "Links", enabled: "1", action: "connection"
        } ],
        connection_link: fixture.links("links", [
            "anytls://secret@example.com:443#AnyTLS%20Node",
            "naive+https://user:pass@example.com:443#Naive+Node",
            "https://user:pass@example.com:443#HTTP%20Node",
            "hysteria://example.com:443#Hysteria%20Node",
            "hy2://secret@example.com:443#Hysteria2%20Node",
            "mierus://user:pass@example.com?profile=default#Mieru+Node",
            "socks5://user:pass@example.com:1080#SOCKS%20Node",
            "ss://YWVzLTEyOC1nY206cGFzcw@example.com:8388#SS%20Node",
            "trojan://secret@example.com:443#Trojan%20Node",
            "tuic://uuid:password@example.com:443#TUIC%20Node",
            "vless://00000000-0000-4000-8000-000000000001@example.com:443#VLESS%20Node",
            "vmess://eyJ2IjoiMiIsInBzIjoiVk1lc3MgV1MiLCJhZGQiOiIxMjcuMC4wLjEiLCJwb3J0IjoiNDQzIiwiaWQiOiIyMjIyMjIyMi0yMjIyLTQyMjItODIyMi0yMjIyMjIyMjIyMjIiLCJhaWQiOiI0Iiwic2N5IjoiYXV0byIsIm5ldCI6IndzIiwidHlwZSI6Im5vbmUiLCJob3N0Ijoidm1lc3MuZXhhbXBsZSIsInBhdGgiOiIvdm1lc3MiLCJ0bHMiOiJ0bHMiLCJzbmkiOiJ2bWVzcy5leGFtcGxlIiwiYWxwbiI6ImgyLGh0dHAvMS4xIiwiZnAiOiJjaHJvbWUifQ==",
            "vmess://{\"ps\":\"Raw VMess\",\"add\":\"127.0.0.1\",\"port\":\"1080\",\"id\":\"00000000-0000-4000-8000-000000000000\",\"net\":\"ws\",\"path\":\"/ws?ed=2048#inside\"}",
            "trojan://secret@example.com:443"
        ])
    });
    t.eq(q.tags(filter(config.outbounds, (o) => o.type == "parser" || o.type == "http" || o.type == "socks")), [
        "Links/AnyTLS Node", "Links/Naive+Node", "Links/HTTP Node",
        "Links/Hysteria Node", "Links/Hysteria2 Node", "Links/Mieru+Node",
        "Links/SOCKS Node", "Links/SS Node", "Links/Trojan Node",
        "Links/TUIC Node", "Links/VLESS Node", "Links/VMess WS", "Links/Raw VMess", "Links/Node #14"
    ]);
});

t.test("a manual link is filtered by the protocol of its scheme", () => {
    let config = build({
        settings: {},
        section: [ {
            ".name": "links", label: "Links", enabled: "1", action: "connection"
        } ],
        connection_link: fixture.links("links", [
            "hy://example.com:443?auth=secret#Hysteria",
            "socks5h://user:pass@example.com:1080#SOCKS",
            "vless://00000000-0000-4000-8000-000000000001@example.com:443#VLESS"
        ]),
        urltest: [ { ".name": "ut_types", section: "links", name: "Filtered", server_filter_mode: "exclude", exclude_types: [ "hysteria", "socks" ] } ]
    });
    t.eq(q.find(config.outbounds, (o) => o.type == "urltest").outbounds, [ "Links/VLESS" ]);
});

t.done();
