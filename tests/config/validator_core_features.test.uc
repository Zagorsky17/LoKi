let t = require("t");
let v = require("validation");
let fixture = require("fixture");

const BASE = [ "badlinkname", "tfogo_checklinkname0", "with_anytls", "with_clash_api", "with_gvisor", "with_openvpn",
    "with_quic", "with_trusttunnel", "with_utls", "with_vmess", "with_wireguard" ];
const FULL = [ ...BASE, "with_snell", "with_ssh", "with_shadowtls", "with_tor", "with_tailscale", "with_naive",
    "with_openconnect", "with_mieru" ];

function without(tags, tag) {
    return filter(tags, (item) => item != tag);
}

function section(extra) {
    return { ".name": "proxy", label: "Proxy", enabled: "1", action: "connection", ...(extra ?? {}) };
}

function needs(data, tags, message) {
    v.refuses(data, message, { core_tags: tags });
    let result = v.run(data, { core_tags: FULL });
    t.ok(result.error == null || index(result.error, "this sing-box build lacks") < 0,
        "a core with every tag refused it: " + result.error);
}

t.test("a tunnel of a type the build lacks is refused by name", () => {
    for (let kind in [ "wireguard", "amneziawg", "warp" ])
        needs({ section: [ section() ], tunnel: [ { ".name": "tun", section: "proxy", kind, name: "Home" } ] },
            without(BASE, "with_gvisor"), "Section 'Proxy' has a " + kind + " tunnel 'Home', but this sing-box build lacks WireGuard, AmneziaWG and WARP (built without with_gvisor)");
    needs({ section: [ section() ], tunnel: [ { ".name": "tun", section: "proxy", kind: "tailscale", name: "Net" } ] },
        BASE, "has a tailscale tunnel 'Net'");
    needs({ section: [ section() ], tunnel: [ { ".name": "tun", section: "proxy", kind: "openvpn-client", name: "Office" } ] },
        without(BASE, "with_openvpn"), "has a openvpn-client tunnel 'Office'");
    needs({ section: [ section() ], tunnel: [ { ".name": "tun", section: "proxy", kind: "openconnect", name: "Work" } ] },
        BASE, "has a openconnect tunnel 'Work', but this sing-box build lacks OpenConnect (built without with_openconnect)");
});

t.test("a JSON endpoint is judged by the type it declares", () => {
    let json = (type) => ({
        section: [ section() ],
        tunnel: [ { ".name": "tun", section: "proxy", kind: "json", endpoint_json: "{\"type\":\"" + type + "\",\"tag\":\"raw\"}" } ]
    });
    needs(json("wireguard"), without(BASE, "with_gvisor"),
        "Section 'Proxy' has a JSON endpoint 'raw' of type wireguard, but this sing-box build lacks WireGuard, AmneziaWG and WARP (built without with_gvisor)");
    needs(json("tailscale"), BASE, "has a JSON endpoint 'raw' of type tailscale");
    let unknown = v.run(json("custom"), { core_tags: [ "with_clash_api" ] });
    t.ok(unknown.error == null || index(unknown.error, "this sing-box build lacks") < 0, "a type the table lacks is left to the core: " + unknown.error);
});

t.test("a link the build cannot dial is refused, without printing its secrets", () => {
    let hy2 = "hy2://secret-password@example.com:443?sni=example.com#Fast";
    needs({ section: [ section() ], connection_link: fixture.links("proxy", [ hy2 ]) }, without(BASE, "with_quic"),
        "Section 'Proxy' has a hy2:// link 'Fast', but this sing-box build lacks QUIC (built without with_quic)");
    let result = v.run({ section: [ section() ], connection_link: fixture.links("proxy", [ hy2 ]) }, { core_tags: without(BASE, "with_quic") });
    t.ok(index(result.error, "secret-password") < 0, "the refusal carries the password");

    needs({ section: [ section() ], connection_link: fixture.links("proxy", [ "naive+https://u:p@example.com:443#N" ]) }, BASE,
        "has a naive+https:// link 'N', but this sing-box build lacks NaiveProxy (built without with_naive)");
    needs({ section: [ section() ], connection_link: fixture.links("proxy", [ "vless://u@example.com:443?security=reality&pbk=key&sni=a.com#R" ]) },
        without(BASE, "with_utls"), "has a vless:// link 'R' that uses Reality or a TLS fingerprint");
    needs({ section: [ section() ], connection_link: fixture.links("proxy", [ "vless://u@example.com:443?security=tls&type=xhttp&alpn=h3#X" ]) },
        without(BASE, "with_quic"),
        "Section 'Proxy' has a vless:// link 'X' that uses XHTTP over HTTP/3, but this sing-box build lacks QUIC (built without with_quic)");
});

t.test("a link of a protocol the build was given no tag for is refused by name", () => {
    needs({ section: [ section() ], connection_link: fixture.links("proxy", [ "vmess://u@example.com:443?security=none#V" ]) },
        without(BASE, "with_vmess"), "Section 'Proxy' has a vmess:// link 'V', but this sing-box build lacks VMess (built without with_vmess)");
    needs({ section: [ section() ], connection_link: fixture.links("proxy", [ "anytls://p@example.com:443#A" ]) },
        without(BASE, "with_anytls"), "has a anytls:// link 'A'");
    needs({ section: [ section() ], connection_link: fixture.links("proxy", [ "mierus://u:p@example.com?profile=p&port=443&protocol=TCP#M" ]) },
        BASE, "has a mierus:// link 'M', but this sing-box build lacks mieru (built without with_mieru)");
});

t.test("a subscription is left to the core, which skips what it cannot build", () => {
    let result = v.run({
        section: [ section() ],
        subscription_url: [ { ".name": "sub", section: "proxy", url: "https://example.com/sub" } ]
    }, { core_tags: [ "with_clash_api" ] });
    t.ok(result.error == null || index(result.error, "this sing-box build lacks") < 0, "refused: " + result.error);
});

t.test("DNS over QUIC and HTTP/3 need QUIC", () => {
    needs({ settings: { dns_server: [ "quic://dns.adguard-dns.com" ] } }, without(BASE, "with_quic"),
        "DNS server 'quic://dns.adguard-dns.com' uses DNS over QUIC, but this sing-box build lacks QUIC");
    needs({ settings: { bootstrap_dns_server: [ "h3://1.1.1.1/dns-query" ] } }, without(BASE, "with_quic"),
        "DNS server 'h3://1.1.1.1/dns-query' uses DNS over HTTP/3");
});

t.test("a DNS section's servers need QUIC for DNS over QUIC too", () => {
    needs({ section: [ { ".name": "dns", enabled: "1", action: "dns", dns_server: [ "quic://dns.example.com" ], destinations: "example.org" } ] },
        without(BASE, "with_quic"), "DNS server 'quic://dns.example.com' uses DNS over QUIC");
});

t.test("requesting WARP profiles through a section needs WARP", () => {
    needs({
        settings: { warp_profiles_via_proxy: "1", warp_profiles_via_proxy_section: "proxy" },
        section: [ section() ],
        connection_link: fixture.links("proxy", [ "vless://u@a.example:443#A" ])
    }, without(BASE, "with_wireguard"),
        "Requesting WARP profiles through a section is on, but this sing-box build lacks WireGuard, AmneziaWG and WARP (built without with_wireguard)");
});

t.done();
