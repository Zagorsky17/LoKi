let t = require("t");
let migration = require("config.migration");

function model(settings, sections) {
    return { sections: [
        { ".name": "settings", ".type": "settings", config_format: "loki", config_version: "2.0.0", ...(settings ?? {}) },
        ...(sections ?? [])
    ] };
}

t.test("only the explicit LoKi format at a supported version is current", () => {
    t.eq(migration.decide(model()), { result: "current", from: "2.0.0" });
    for (let format in [ null, "", "forkop", "podkop", "LOKI", [ "loki" ], { loki: true } ])
        t.eq(migration.decide(model({ config_format: format })), { result: "reject", from: "unknown", reason: "foreign" });
    for (let version in [ "1.0.2", "1.0.5", "1.9.9" ])
        t.eq(migration.decide(model({ config_version: version })).reason, "below_min");
    t.eq(migration.decide(model({ config_version: "2.0.1" })).reason, "newer");
    for (let version in [ "", null ])
        t.eq(migration.decide(model({ config_version: version })).reason, "missing");
    for (let version in [ "NEXT-secret\ninjected", "2.0", [ "2.0.0" ], 200, "2.0.0 ", "22222222222222222222.0.0" ]) {
        let decision = migration.decide(model({ config_version: version }));
        t.eq(decision, { result: "reject", from: "unknown", reason: "invalid" });
        t.excludes(sprintf("%J", decision), "secret");
    }
});

t.test("ambiguous settings, removed sections and malformed models are refused", () => {
    for (let data in [ null, {}, { sections: null }, { sections: [] }, { sections: [ null ] }, { sections: [ "settings" ] } ])
        t.eq(migration.decide(data).result, "reject");
    let duplicate = model({}, [ { ".name": "other", ".type": "settings", config_format: "loki", config_version: "2.0.0" } ]);
    t.eq(migration.decide(duplicate).reason, "schema");
    for (let type_name in [ "server", "server_client", "tunnel", "tunnel_peer", "priority_group", "unknown" ])
        t.eq(migration.decide(model({}, [ { ".name": "secret\ninjected", ".type": type_name } ])).reason, "schema");
    t.eq(migration.decide(model({}, [ { ".name": "settings", ".type": "section" } ])).reason, "schema");
    let renamed = model();
    renamed.sections[0][".name"] = "other";
    t.eq(migration.decide(renamed).reason, "schema");
});

t.test("the supported client sections survive the shared model unchanged", () => {
    let types = [ "section", "subscription_url", "section_interface", "connection_link", "urltest", "fallback_group", "fallback_level" ];
    let original = model({}, map(types, (name) => ({ ".name": name, ".type": name, value: "synthetic-secret" })));
    let saved = sprintf("%J", original);
    let result = migration.migrate(original, "2.0.0");
    t.eq(result, { model: original, warnings: [] });
    result.model.sections[1].value = "changed";
    t.eq(sprintf("%J", original), saved, "the source is not mutated");
    t.eq(migration.migrate(original, "1.0.5").model, null);
    t.eq(migration.migrate(model({ config_format: null }), "2.0.0").model, null);
});

t.test("shared UCI operations preserve creation order, references, lists and deletions", () => {
    let before = model({}, [ { ".name": "old", ".type": "section", obsolete: "1" } ]);
    let after = model({}, [
        { ".name": ".new-1", ".type": "section", ".anonymous": true, links: [ ".new-2", "kept" ] },
        { ".name": ".new-2", ".type": "connection_link", ".anonymous": true, section: ".new-1", uri: "socks://127.0.0.1:1080" }
    ]);
    let ops = migration.changes(before, after);
    t.eq(map(ops, (op) => op.op), [ "add", "add", "set", "set", "set", "remove" ]);
    let calls = [];
    let counter = 0;
    let cursor = {
        add: (config, type_name) => "cfg" + ++counter,
        set: (...args) => { push(calls, args); return true; },
        delete: (...args) => { push(calls, args); return true; }
    };
    t.eq(migration.apply(cursor, ops), null);
    t.eq(calls[0], [ "forkop", "cfg1", "links", [ "cfg2", "kept" ] ]);
    t.eq(calls[1], [ "forkop", "cfg2", "section", "cfg1" ]);
    t.eq(calls[length(calls) - 1], [ "forkop", "old" ]);
    cursor.set = () => false;
    t.contains(migration.apply(cursor, [ { op: "set", section: "main", option: "enabled", value: "1" } ]), "could not set");
    t.eq(migration.changes(before, before), []);
});

t.test("named creation, retyping, option removal and write failures keep their UCI semantics", () => {
    let before = model({}, [ { ".name": "main", ".type": "section", obsolete: "1" } ]);
    let after = model({}, [ { ".name": "main", ".type": "urltest" }, { ".name": "added", ".type": "section", enabled: "1" } ]);
    let ops = migration.changes(before, after);
    t.eq(map(ops, (op) => op.op), [ "create", "retype", "unset", "set" ]);
    let calls = [];
    let cursor = {
        add: () => null,
        set: (...args) => { push(calls, args); return true; },
        delete: (...args) => { push(calls, args); return true; }
    };
    t.eq(migration.apply(cursor, ops), null);
    t.eq(calls[0], [ "forkop", "added", "section" ]);
    t.eq(calls[1], [ "forkop", "main", "urltest" ]);
    t.eq(calls[2], [ "forkop", "main", "obsolete" ]);
    t.contains(migration.apply(cursor, [ { op: "add", section: ".new-1", type: "section" } ]), "could not add");
    cursor.delete = () => false;
    t.contains(migration.apply(cursor, [ { op: "unset", section: "main", option: "enabled" } ]), "could not unset");
});

t.done();
