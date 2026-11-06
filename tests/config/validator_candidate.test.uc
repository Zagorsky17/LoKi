let t = require("t");
let stub = require("stub");
let fixture = require("fixture");
let validator = require("config.validator");
let connections = require("config.connections");
let core_uci = require("core.uci");
let features = require("singbox.features");

function model(extra, sections) {
    return { sections: [ { ".name": "settings", ".type": "settings",
        config_format: "loki", config_version: "2.0.0",
        dns_server: [ "1.1.1.1" ], bootstrap_dns_server: [ "1.1.1.1" ],
        cache_path: stub.tmpdir() + "/private/cache.db", ...(extra ?? {}) }, ...(sections ?? []) ] };
}

function check(candidate) {
    let original = [ core_uci.get_all, core_uci.section_objects, features.tags ];
    let forbidden = () => die("host configuration or core was inspected");
    core_uci.get_all = forbidden;
    core_uci.section_objects = forbidden;
    features.tags = forbidden;
    stub.commands([]);
    let error = null;
    try { validator.validate_candidate(candidate); }
    catch (e) { error = e.message; }
    core_uci.get_all = original[0];
    core_uci.section_objects = original[1];
    features.tags = original[2];
    let calls = stub.calls();
    stub.restore();
    t.eq(calls, [], "prepared validation must not execute commands or write syslog");
    return error;
}

t.test("prepared values use only the current schema snapshot and preserve the runtime cache", () => {
    fixture.seed({ section: [ { ".name": "host", action: "bypass" } ] });
    connections.load();
    t.ok(connections.section_exists("host"));
    t.eq(check(model()), null);
    t.ok(connections.section_exists("host"));
    t.ok(!connections.section_exists("candidate"));
});

t.test("invalid prepared values fail without borrowing valid host values", () => {
    fixture.seed({ settings: { dns_timeout: "10s" }, section: [ { ".name": "host", action: "bypass" } ] });
    connections.load();
    let error = check(model({ dns_timeout: "synthetic-secret" }));
    t.contains(error, "DNS timeout");
    t.ok(connections.section_exists("host"), "a failed validation must restore the previous index");
});

t.test("prepared warnings do not write syslog and child links come from the snapshot", () => {
    let sections = [ { ".name": "candidate", ".type": "section", action: "connection",
        label: "synthetic-secret", community_lists: [ "telegram" ], rule_set: [ "telegram" ] } ];
    t.eq(check(model({}, sections)), null);
    push(sections, { ".name": "link", ".type": "connection_link", section: "candidate",
        uri: "hy2://synthetic-secret@node.example:443", name: "Example" });
    t.eq(check(model({}, sections)), null, "unknown core features remain an explicit separate check");
    sections[1].uri = "";
    t.ok(check(model({}, sections)) != null, "invalid candidate child data must not disappear");
});

t.test("foreign, future and malformed schemas cannot enter value validation", () => {
    for (let candidate in [ null, {}, model({ config_format: "forkop" }),
        model({ config_version: "999.0.0" }), model({}, [ { ".name": "bad", ".type": "unknown" } ]) ])
        t.ok(check(candidate) != null);
});

t.done();
