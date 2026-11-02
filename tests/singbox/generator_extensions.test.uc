let t = require("t");
let fixture = require("fixture");
let generator = require("singbox.generator");

function build(settings, sources) {
    fixture.seed({
        settings: { dns_server: [ "127.0.0.1" ], bootstrap_dns_server: [ "127.0.0.1" ], ...(settings ?? {}) },
        section: [ { ".name": "main", action: "connection", outbound_jsons: [ '{"type":"socks","tag":"Node","server":"127.0.0.1","server_port":1080}' ] } ],
        ...(sources ?? {})
    });
    return generator.build({ service_address: "127.0.0.1", local_prefixes: [] });
}

t.test("a configuration without providers has no provider extension or subscription cache flag", () => {
    let config = build();
    t.eq(config.providers, null);
    t.eq(config.experimental.cache_file.store_subscriptions, null);
    t.eq(config.experimental.cache_file.store_fakeip, true);
    t.eq(config.experimental.cache_file.enabled, true);
    t.eq(config.dns.timeout, null, "the shared 10s default needs no core extension");
    t.eq(config.experimental.unified_delay.enabled, true, "the default delay setting is unchanged");
});

t.test("only an explicitly disabled unified delay is omitted", () => {
    for (let value in [ "0", "false", "off" ]) {
        let config = build({ unified_delay: value });
        t.eq(config.experimental.unified_delay, null);
        t.eq(config.experimental.cache_file.store_fakeip, true);
        t.ok(config.experimental.clash_api != null, "Clash API is still required");
    }
    t.eq(build({ unified_delay: "1" }).experimental.unified_delay.enabled, true);
});

t.test("active local and remote providers retain their options and subscription cache", () => {
    for (let source in [ "http://127.0.0.1:18081/sub", "/etc/forkop/subscription.txt" ]) {
        let config = build({ unified_delay: "0" }, {
            subscription_url: [ { ".name": "sub", section: "main", tag: "Sub", url: source, subscription_update_enabled: "0" } ]
        });
        t.eq(length(config.providers), 1);
        t.eq(config.providers[0].tag, "main/Sub");
        t.eq(config.providers[0].type, substr(source, 0, 1) == "/" ? "local" : "remote");
        t.eq(config.providers[0].url ?? config.providers[0].path, source);
        t.eq(config.experimental.cache_file.store_subscriptions, true);
        t.eq(config.experimental.unified_delay, null);
    }
});

t.test("removed, orphaned and disabled provider sources do not leave stale extensions on repeated builds", () => {
    let active = build(null, { subscription_url: [ { ".name": "sub", section: "main", tag: "Sub", url: "http://127.0.0.1:18081/sub" } ] });
    let plain = build({ unified_delay: "0" });
    let ignored = build({ unified_delay: "0" }, {
        section: [
            { ".name": "off", action: "connection", enabled: "0" },
            { ".name": "main", action: "bypass", destinations: "example.test" }
        ],
        subscription_url: [
            { ".name": "disabled", section: "off", tag: "Off", url: "http://127.0.0.1:18081/sub" },
            { ".name": "orphan", section: "missing", tag: "Missing", url: "http://127.0.0.1:18081/sub" }
        ]
    });
    for (let config in [ plain, ignored, build({ unified_delay: "0" }) ]) {
        t.eq(config.providers, null);
        t.eq(config.experimental.cache_file.store_subscriptions, null);
        t.eq(config.experimental.unified_delay, null);
    }
    t.eq(length(active.providers), 1, "a later build must not mutate an earlier result");
    t.eq(active.experimental.cache_file.store_subscriptions, true);
});

t.done();
