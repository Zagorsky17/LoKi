let t = require("t");
let fixture = require("fixture");
let generator = require("singbox.generator");
let q = require("sbconfig");
let validation = require("validation");
let uci = require("uci");

function build(settings) {
    fixture.seed({
        settings: { dns_server: [ "127.0.0.1" ], bootstrap_dns_server: [ "127.0.0.1" ], ...(settings ?? {}) },
        section: [ { ".name": "main", action: "bypass", destinations: "example.test" } ]
    });
    return generator.build({ controller_secret: fixture.CONTROLLER_SECRET, service_address: "127.0.0.1", local_prefixes: [] });
}

t.test("the verified 10s DNS default is omitted without changing resolvers or the stored setting", () => {
    for (let settings in [ {}, { dns_timeout: "10s" } ]) {
        let config = build(settings);
        t.eq(config.dns.timeout, null);
        t.eq(q.dns_server_tag(config, "dns-server").server, "127.0.0.1");
        t.eq(q.dns_server_tag(config, "bootstrap-dns-server").server, "127.0.0.1");
        t.eq(config.dns.final, "dns-server");
        t.eq(config.experimental.cache_file.store_fakeip, true);
        t.eq(uci.cursor().get("loki", "settings", "dns_timeout"), settings.dns_timeout);
    }
});

t.test("every nondefault spelling is preserved and a later build cannot lose its timeout", () => {
    for (let duration in [ "1ms", "400ms", "4s", "12s", "1m", "10000ms" ]) {
        let first = build({ dns_timeout: duration });
        let defaults = build({ dns_timeout: "10s" });
        let again = build({ dns_timeout: duration });
        t.eq(first.dns.timeout, duration);
        t.eq(defaults.dns.timeout, null);
        t.eq(again.dns.timeout, duration);
        t.eq(uci.cursor().get("loki", "settings", "dns_timeout"), duration);
    }
});

t.test("malformed or NUL-suffixed durations are not silently treated as the default", () => {
    for (let duration in [ "bad", "10s-secret", "10s" + chr(0) + "suffix" ]) {
        t.eq(build({ dns_timeout: duration }).dns.timeout, duration);
        validation.refuses({ settings: { dns_timeout: duration } }, "DNS timeout");
    }
});

t.done();
