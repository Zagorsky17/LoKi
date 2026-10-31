// Modified for LoKi on 2026-10-31: explicit DNS encryption must never downgrade silently.
let t = require("t");
let v = require("validation");
let fixture = require("fixture");
let generator = require("singbox.generator");
let q = require("sbconfig");

function data(settings) {
    return {
        settings: { bootstrap_dns_server: [ "192.0.2.53" ], ...settings },
        section: [ { ".name": "direct", enabled: "1", action: "bypass", destinations: "target.example" } ]
    };
}

t.test("the explicit DNS mode accepts UDP, DoH and DoT without changing the chosen protocol", () => {
    for (let entry in [
        [ "0", "", "192.0.2.54", "udp" ],
        [ "1", "https", "https://dns.example/custom-query", "https" ],
        [ "1", "tls", "tls://dns.example", "tls" ]
    ]) {
        let input = data({ dns_encryption: entry[0], dns_encrypted_protocol: entry[1], dns_server: [ entry[2] ] });
        v.accepts(input);
        fixture.seed(input);
        let config = generator.build({ service_address: "192.168.1.1" });
        t.eq(q.dns_server_tag(config, "dns-server").type, entry[3]);
        t.eq(q.dns_server_tag(config, "bootstrap-dns-server").type, "udp");
    }
});

t.test("invalid and mismatching encryption settings are refused by both validation and generation", () => {
    for (let entry in [
        [ "auto", "", "192.0.2.54", "DNS encryption must be explicitly enabled or disabled" ],
        [ "", "", "192.0.2.54", "DNS encryption must be explicitly enabled or disabled" ],
        [ "1", "", "https://dns.example/dns-query", "Choose DoH (https) or DoT (tls)" ],
        [ "1", "quic", "quic://dns.example", "Choose DoH (https) or DoT (tls)" ],
        [ "1", "udp", "192.0.2.54", "Choose DoH (https) or DoT (tls)" ],
        [ "1", "https", "http://dns.example/dns-query", "unsupported DNS server URI scheme 'http'" ],
        [ "1", "https", "192.0.2.54", "Main DNS protocol must match the explicit encryption setting (https)" ],
        [ "1", "tls", "https://dns.example/dns-query", "Main DNS protocol must match the explicit encryption setting (tls)" ],
        [ "0", "https", "https://dns.example/dns-query", "Main DNS protocol must match the explicit encryption setting (udp)" ],
        [ "0", "", "tcp://192.0.2.54", "Main DNS protocol must match the explicit encryption setting (udp)" ]
    ]) {
        let input = data({ dns_encryption: entry[0], dns_encrypted_protocol: entry[1], dns_server: [ entry[2] ] });
        v.refuses(input, entry[3]);
        fixture.seed(input);
        t.contains(t.throws(() => generator.build({ service_address: "192.168.1.1" })).message, entry[3]);
    }
});

t.test("every main server must match the global encryption mode", () => {
    v.refuses(data({
        dns_encryption: "1", dns_encrypted_protocol: "https",
        dns_server: [ "https://dns.example/dns-query", "192.0.2.54" ]
    }), "Main DNS protocol must match the explicit encryption setting (https)");
});

t.test("an explicit encryption mode keeps bootstrap on UDP by IP", () => {
    let input = data({ dns_encryption: "0", dns_server: [ "192.0.2.54" ], bootstrap_dns_server: [ "tls://192.0.2.53" ] });
    v.refuses(input, "Bootstrap DNS must use UDP");
    fixture.seed(input);
    t.contains(t.throws(() => generator.build({ service_address: "192.168.1.1" })).message, "Bootstrap DNS must use UDP");
});

t.test("legacy DNS URIs stay unchanged until an explicit encryption mode is saved", () => {
    let input = data({ dns_server: [ "https://dns.example/dns-query", "tls://other.example" ] });
    v.accepts(input);
    fixture.seed(input);
    let config = generator.build({ service_address: "192.168.1.1" });
    t.eq(map(q.dns_server_tag(config, "dns-server").servers, (tag) => q.dns_server_tag(config, tag).type), [ "https", "tls" ]);
});

t.done();
