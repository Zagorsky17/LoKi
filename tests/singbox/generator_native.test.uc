let t = require("t");
let fixture = require("fixture");
let q = require("sbconfig");
let generator = require("singbox.generator");

const OPENVPN = {
    type: "openvpn-client", mode: "static_key", server: "127.0.0.1", server_port: 1194,
    network: "udp", address: [ "10.44.0.2/30" ], peer_address: "10.44.0.1",
    cipher: "AES-256-CBC", auth: "SHA256",
    static_key: [ "-----BEGIN OpenVPN Static key V1-----", "0123456789abcdef0123456789abcdef", "-----END OpenVPN Static key V1-----" ],
    ping_interval: "10s", ping_restart: "60s"
};

function openvpn_fixture(settings) {
    return {
        settings: { dns_server: [ "1.1.1.1" ], bootstrap_dns_server: [ "1.1.1.1" ], service_listen_address: "127.0.0.1", ...(settings ?? {}) },
        section: [ { ".name": "vpn", enabled: "1", action: "connection", user_domains: "example.test" } ],
        tunnel: [ { ".name": "openvpn", section: "vpn", kind: "openvpn-client", name: "OpenVPN", endpoint_json: sprintf("%J", OPENVPN) } ]
    };
}

t.test("an OpenVPN tunnel reaches the core as the endpoint it was written as", () => {
    fixture.seed(openvpn_fixture());
    let config = generator.build({ service_address: "127.0.0.1" });
    t.eq(config.endpoints[0], { ...OPENVPN, tag: "vpn/OpenVPN" });
    t.contains(q.outbound(config, "vpn").outbounds, "vpn/OpenVPN");
});

const OPENCONNECT = {
    type: "openconnect", server: "vpn.example.com:8443/staff", flavor: "anyconnect",
    username: "alice", password: "secret", external_auth_disabled: true,
    tls: { peer_fingerprint: [ "pin-sha256:svnty/laZqBAdkrdaiQxUb+x8kHPG7QJjSPRjA20WhU=" ] }
};

function openconnect_fixture(endpoint, tunnel) {
    return {
        settings: { dns_server: [ "1.1.1.1" ], bootstrap_dns_server: [ "1.1.1.1" ], service_listen_address: "127.0.0.1" },
        section: [
            { ".name": "vpn", enabled: "1", action: "connection", user_domains: "example.test" },
            { ".name": "proxy", enabled: "1", action: "connection", user_domains: "proxy.test" }
        ],
        connection_link: fixture.links("proxy", [ "vless://u@a.example:443#A" ]),
        tunnel: [ { ".name": "work", section: "vpn", kind: "openconnect", name: "Work",
            endpoint_json: sprintf("%J", endpoint ?? OPENCONNECT), ...(tunnel ?? {}) } ]
    };
}

t.test("an OpenConnect tunnel reaches the core as written and keeps reconnecting", () => {
    fixture.seed(openconnect_fixture());
    let config = generator.build({ service_address: "127.0.0.1" });
    let endpoint = filter(config.endpoints, (item) => item.type == "openconnect")[0];
    t.eq(endpoint, { ...OPENCONNECT, tag: "vpn/Work", reconnect_timeout: "876000h" });
    t.contains(q.outbound(config, "vpn").outbounds, "vpn/Work");

    fixture.seed(openconnect_fixture({ ...OPENCONNECT, reconnect_timeout: "10m" }));
    config = generator.build({ service_address: "127.0.0.1" });
    t.eq(filter(config.endpoints, (item) => item.type == "openconnect")[0].reconnect_timeout, "10m",
        "a timeout the endpoint names is its own");
});

t.test("an OpenConnect tunnel reaches its server through the section it cascades through", () => {
    fixture.seed(openconnect_fixture(null, { detour_section: "proxy" }));
    let config = generator.build({ service_address: "127.0.0.1" });
    t.eq(filter(config.endpoints, (item) => item.type == "openconnect")[0].detour, "proxy");
});

t.done();
