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
    t.ok(result.error == null || index(result.error, "this loki-core build lacks") < 0,
        "a core with every tag refused it: " + result.error);
}

t.test("a link the build cannot dial is refused, without printing its secrets", () => {
    let hy2 = "hy2://secret-password@example.com:443?sni=example.com#Fast";
    needs({ section: [ section() ], connection_link: fixture.links("proxy", [ hy2 ]) }, without(BASE, "with_quic"),
        "Section 'Proxy' has a hy2:// link 'Fast', but this loki-core build lacks QUIC (built without with_quic)");
    let result = v.run({ section: [ section() ], connection_link: fixture.links("proxy", [ hy2 ]) }, { core_tags: without(BASE, "with_quic") });
    t.ok(index(result.error, "secret-password") < 0, "the refusal carries the password");

    needs({ section: [ section() ], connection_link: fixture.links("proxy", [ "naive+https://u:p@example.com:443#N" ]) }, BASE,
        "has a naive+https:// link 'N', but this loki-core build lacks NaiveProxy (built without with_naive)");
    needs({ section: [ section() ], connection_link: fixture.links("proxy", [ "vless://u@example.com:443?security=reality&pbk=key&sni=a.com#R" ]) },
        without(BASE, "with_utls"), "has a vless:// link 'R' that uses Reality or a TLS fingerprint");
    needs({ section: [ section() ], connection_link: fixture.links("proxy", [ "vless://u@example.com:443?security=tls&type=xhttp&alpn=h3#X" ]) },
        without(BASE, "with_quic"),
        "Section 'Proxy' has a vless:// link 'X' that uses XHTTP over HTTP/3, but this loki-core build lacks QUIC (built without with_quic)");
});

t.test("a link of a protocol the build was given no tag for is refused by name", () => {
    needs({ section: [ section() ], connection_link: fixture.links("proxy", [ "vmess://u@example.com:443?security=none#V" ]) },
        without(BASE, "with_vmess"), "Section 'Proxy' has a vmess:// link 'V', but this loki-core build lacks VMess (built without with_vmess)");
    needs({ section: [ section() ], connection_link: fixture.links("proxy", [ "anytls://p@example.com:443#A" ]) },
        without(BASE, "with_anytls"), "has a anytls:// link 'A'");
    needs({ section: [ section() ], connection_link: fixture.links("proxy", [ "mierus://u:p@example.com?profile=p&port=443&protocol=TCP#M" ]) },
        BASE, "has a mierus:// link 'M', but this loki-core build lacks mieru (built without with_mieru)");
});

t.test("a subscription is left to the core, which skips what it cannot build", () => {
    let result = v.run({
        section: [ section() ],
        subscription_url: [ { ".name": "sub", section: "proxy", url: "https://example.com/sub" } ]
    }, { core_tags: [ "with_clash_api" ] });
    t.ok(result.error == null || index(result.error, "this loki-core build lacks") < 0, "refused: " + result.error);
});

t.test("DNS over QUIC and HTTP/3 need QUIC", () => {
    needs({ settings: { dns_server: [ "quic://dns.adguard-dns.com" ] } }, without(BASE, "with_quic"),
        "A configured DNS server uses DNS over QUIC, but this loki-core build lacks QUIC");
    needs({ settings: { bootstrap_dns_server: [ "h3://1.1.1.1/dns-query" ] } }, without(BASE, "with_quic"),
        "A configured DNS server uses DNS over HTTP/3");
});

t.test("a DNS section's servers need QUIC for DNS over QUIC too", () => {
    needs({ section: [ { ".name": "dns", enabled: "1", action: "dns", dns_server: [ "quic://dns.example.com" ], destinations: "example.org" } ] },
        without(BASE, "with_quic"), "A configured DNS server uses DNS over QUIC");
});


t.done();
