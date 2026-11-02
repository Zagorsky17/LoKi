let t = require("t");
let v = require("validation");

t.test("a missing QUIC feature never exposes a private DNS path or query token", () => {
    for (let server in [ "h3://dns.example/dns-query/synthetic-account", "quic://synthetic-account.dns.nextdns.io" ]) {
        let result = v.run({ section: [ { ".name": "dns", enabled: "1", action: "dns", dns_server: [ server ], destinations: "example.org" } ] },
            { core_tags: [ "with_clash_api", "with_utls" ] });
        t.contains(result.error, "this sing-box build lacks QUIC");
        t.excludes(result.error, "synthetic-account");
        t.excludes(result.error, "synthetic-secret");
        t.excludes(result.error, server);
    }
});

t.test("invalid DNS input does not expose credentials, tokens, hostnames or parser fragments", () => {
    for (let server in [ "h3://dns.example/dns-query?token=synthetic-secret", "https://user:synthetic-secret@dns.example/dns-query",
        "https://dns.example/dns-query#synthetic-secret", "synthetic-secret://dns.example", "https://synthetic-secret!invalid/", "tls://dns.example:synthetic-secret" ]) {
        let cases = [
            { settings: { dns_server: [ server ] } },
            { settings: { bootstrap_dns_server: [ server ] } },
            { section: [ { ".name": "dns", action: "dns", dns_server: [ server ], destinations: "example.org" } ] },
            { section: [ { ".name": "proxy", enabled: "1", action: "connection" } ], section_interface: [ { ".name": "lan", section: "proxy", name: "lan1", domain_resolver_enabled: "1", domain_resolver_dns_server: [ server ] } ] }
        ];
        for (let input in cases) {
            let result = v.run(input, { core_tags: [ "with_clash_api", "with_utls", "with_quic" ] });
            t.ok(result.error != null, "invalid DNS input was accepted");
            t.contains(lc(result.error), "dns server", "the refusal came from the DNS input guard");
            t.excludes(result.error, "synthetic-secret");
            t.excludes(result.error, server);
        }
    }
});


t.done();
