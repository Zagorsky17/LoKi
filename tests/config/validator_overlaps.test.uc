// Modified for LoKi on 2026-11-01: warnings must not change routing or validation policy.
let t = require("t");
let v = require("validation");
let fixture = require("fixture");
let generator = require("singbox.generator");
let lists = require("singbox.rulesets");

function section(name, extra) {
    return { ".name": name, enabled: "1", action: "bypass", ...(extra ?? {}) };
}

t.test("either external field warns without refusing the section or removing its provider", () => {
    for (let field in [ "rule_set", "rule_set_with_subnets" ]) {
        let data = { section: [ section("MAIN", { community_lists: [ "telegram" ], [field]: [ lists.community_url("telegram") ] }) ] };
        let result = v.accepts(data);
        t.eq(length(result.logs), 1);
        t.contains(result.logs[0], "[warn]");
        t.contains(result.logs[0], "same source");
        t.excludes(result.logs[0], "https://");
        fixture.seed({ ...data, settings: fixture.settings() });
        let config = generator.build({ service_address: "127.0.0.1" });
        t.eq(length(filter(config.route.rule_set, (item) => item.url == lists.community_url("telegram"))), 2);
    }
});

t.test("disabled and separate sections do not warn, while a DNS section can warn about domains", () => {
    t.eq(v.accepts({ section: [ section("OFF", { enabled: "0", community_lists: [ "telegram" ], rule_set: [ "telegram" ] }) ] }).logs, []);
    t.eq(v.accepts({ section: [ section("ONE", { community_lists: [ "telegram" ] }), section("TWO", { rule_set: [ "telegram" ] }) ] }).logs, []);
    let result = v.accepts({ section: [ section("DNS", { action: "dns", dns_server: [ "1.1.1.1" ], community_lists: [ "telegram" ], rule_set: [ "telegram" ] }) ] });
    t.eq(length(result.logs), 1);
});

t.test("warnings neither reveal URL credentials nor suppress an existing validation failure", () => {
    let data = { section: [ section("MAIN", { community_lists: [ "telegram" ], rule_set: [ "telegram", lists.community_url("telegram") + "?token=TEST_SECRET" ] }) ] };
    let result = v.accepts(data);
    t.eq(length(result.logs), 1);
    t.excludes(join("\n", result.logs), "TEST_SECRET");
    v.refuses({ section: [ section("MAIN", { community_lists: [ "telegram" ], rule_set: [ "telegram", "relative/file.srs" ] }) ] }, "is neither an http(s) URL nor an absolute path");
});
t.test("a display name cannot inject extra log records through an overlap warning", () => {
    let result = v.accepts({ section: [ section("MAIN", { label: "Name $(id)\n[error] forged", community_lists: [ "telegram" ], rule_set: [ "telegram" ] }) ] });
    t.eq(length(result.logs), 1);
    t.excludes(result.logs[0], "\n");
    t.contains(result.logs[0], "Name $(id) [error] forged");
});
t.done();
