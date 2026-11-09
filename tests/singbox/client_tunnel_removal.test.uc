let t = require("t");
let fixture = require("fixture");
let generator = require("singbox.generator");
let connections = require("config.connections");
let cli = require("service.cli");
let clash = require("singbox.clash_api");
let v = require("validation");
let stub = require("stub");

const KINDS = [ "wireguard", "amneziawg", "warp", "tailscale", "openvpn-client", "openconnect", "json" ];

function base() {
    return {
        settings: fixture.settings({ bootstrap_dns_server: "1.1.1.1" }),
        section: [ { ".name": "main", action: "connection", destinations: "example.test" } ],
        connection_link: fixture.links("main", [ "socks://user:synthetic-password@127.0.0.1:1080#Node" ])
    };
}

function build(data) {
    fixture.seed(data);
    return generator.build({ controller_secret: fixture.CONTROLLER_SECRET, service_address: "127.0.0.1" });
}

t.test("retired records and WARP switches cannot change a working proxy configuration", () => {
    let expected = build(base());
    for (let kind in KINDS) {
        let data = base();
        data.settings.warp_profiles_via_proxy = "1";
        data.settings.warp_profiles_via_proxy_section = "missing";
        data.tunnel = [ {
            ".name": "retired", section: "main", kind, name: "Node", accept_server_dns: "1",
            tailscale_auth_key: "synthetic-auth-key", private_key: "synthetic-private-key",
            endpoint_json: sprintf("%J", { type: "openvpn-server", tag: "Listener", listen_port: 1194 })
        } ];
        data.tunnel_peer = [ { ".name": "peer", tunnel: "retired", address: "127.0.0.1", port: "51820" } ];
        for (let repeat = 0; repeat < 2; repeat++) {
            let validation = v.accepts(data);
            t.excludes(join("\n", validation.logs), "synthetic-");
            t.eq(build(data), expected, kind);
        }
    }
    t.eq(expected.endpoints, null);
    t.eq(expected.experimental.cache_file.store_warp_config, null);
    for (let inbound in expected.inbounds)
        t.ok(inbound.listen_port != 4536, "no WARP service proxy");
});

t.test("a retired tunnel cannot make a section runnable or silently supply direct access", () => {
    let data = base();
    delete data.connection_link;
    for (let kind in KINDS) {
        data.tunnel = [ { ".name": "retired", section: "main", kind, name: "Retired" } ];
        fixture.seed(data);
        connections.load();
        t.eq(connections.has_connection_sources(data.section[0]), false, kind);
        t.eq(generator.runnable(), false, kind);
    }
});

t.test("retired control commands and Tailscale transport paths are unavailable", () => {
    t.eq(cli.COMMANDS.generate_warp_profile, null);
    stub.commands([ [ () => true, {} ] ]);
    for (let repeat = 0; repeat < 2; repeat++) {
        let result = stub.capture(() => cli.main([ "generate_warp_profile", "; echo synthetic-private-key" ], "/lib"));
        t.ok(result.result != 0);
        t.excludes(result.stdout + result.stderr, "synthetic-private-key");
    }
    for (let path in [ "/tailscale", "/tailscale/node/ping?address=127.0.0.1&timeout=5000" ])
        t.contains(t.throws(() => clash.request("GET", path, "")).message, "not allowlisted", path);
    let commands = stub.command_lines();
    stub.restore();
    t.eq(filter(commands, (line) => index(line, "logger ") != 0), []);
    t.excludes(join("\n", commands), "synthetic-private-key");
});

t.test("JSON outbounds cannot restore endpoint protocols or the legacy WireGuard outbound", () => {
    for (let kind in [ ...KINDS, "openvpn", "openvpn-server" ]) {
        if (kind == "json")
            continue;
        let data = base();
        data.section[0].outbound_jsons = sprintf("%J", { type: " " + uc(kind) + " ", tag: "Retired", private_key: "synthetic-private-key" });
        let validation = v.refuses(data, "VPN tunnel and server types are not supported");
        t.excludes(validation.error, "synthetic-private-key");
        let error = t.throws(() => build(data)).message;
        t.contains(error, "VPN tunnel and server types are not supported");
        t.excludes(error, "synthetic-private-key");
    }
});

t.test("malformed, oversized, disabled and orphaned tunnel records have no runtime effects", () => {
    let expected = build(base());
    for (let payload in [ "{broken-json", [ "not-an-endpoint" ], { type: "tailscale" }, join("", map([ 1, 2, 3, 4 ], () => sprintf("%65536s", "x"))) ]) {
        let data = base();
        data.tunnel = [ { ".name": "orphan", section: "missing", kind: "json", endpoint_json: payload },
            { ".name": "disabled", section: "main", enabled: "0", kind: "tailscale", tailscale_auth_key: "synthetic-auth-key" } ];
        data.tunnel_peer = [ { ".name": "orphan-peer", tunnel: "missing", private_key: "synthetic-private-key" } ];
        t.eq(build(data), expected);
    }
});

t.test("proxy JSON keeps authentication, transport and Reality parameters", () => {
    let data = base();
    let outbound = { type: "vless", tag: "JSON", server: "127.0.0.1", server_port: 443,
        uuid: "synthetic-uuid", transport: { type: "ws", path: "/proxy" },
        tls: { enabled: true, server_name: "example.test", reality: { enabled: true, public_key: "synthetic-public" } } };
    data.section[0].outbound_jsons = sprintf("%J", outbound);
    v.accepts(data);
    let config = build(data);
    t.eq(filter(config.outbounds, (item) => item.tag == "main/JSON")[0], { ...outbound, tag: "main/JSON" });
});

t.done();
