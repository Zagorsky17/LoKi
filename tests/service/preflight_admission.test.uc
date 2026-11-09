let t = require("t"), stub = require("stub"), preflight = require("service.preflight");
// These are the installer contract, not a list derived from the implementation.
const PROOFS = {
    platform: [ "openwrt-release", "requirements" ], environment: [ "namespace-layout", "system-origin" ],
    "candidate-manifest": [ "candidate-manifest", "package-format", "architecture", "component-set" ],
    ownership: [ "installed-metadata" ], files: [ "critical-file" ], dependencies: [ "ucode" ], configuration: [ "candidate-config" ],
    services: [ "procd-snapshot", "registration-origin" ], autostart: [ "directory" ], hooks: [ "hook-inventory" ],
    processes: [ "visibility", "origin" ], listeners: [ "socket-owners", "namespace-and-configuration" ],
    "dns-committed": [ "dnsmasq" ], "dns-pending": [ "uci-deltas" ], "dns-runtime": [ "dnsmasq", "dnsmasq-config" ],
    "nft-loaded": [ "table-list", "rules-and-namespace" ], "nft-persisted": [ "firewall-includes" ],
    "policy-rules": [ "ownership" ], "policy-routes": [ "ownership" ],
    "ipv4-routes-rules": [ "policy-rules", "policy-routes" ], "ipv6-routes-rules": [ "policy-rules", "policy-routes" ],
    resources: [ "candidate-capacity", "resource-budget" ], "core-check": [ "candidate-core" ]
};
function ready() {
    let rows = [];
    for (let kind in keys(PROOFS)) for (let object in PROOFS[kind])
        push(rows, { kind, object, state: "checked", reason: "proof-checked" });
    return rows;
}
function refused(result, conflict) {
    t.eq([ result.schema, result.result, result.complete, result.install_allowed ],
        [ 1, conflict ? "conflict" : "incomplete", false, false ]);
}

t.test("only the complete checked proof set grants admission without running commands", () => {
    let commands = stub.commands([]), first = preflight.admission(ready()), second = preflight.admission(ready());
    stub.restore(); t.eq(commands.calls, []);
    t.eq([ first.schema, first.result, first.complete, first.install_allowed ], [ 1, "checked", true, true ]);
    t.eq(first, second);
});

t.test("each missing mandatory kind or subproof refuses even when discovery itself passed", () => {
    let rows = ready();
    for (let missing in rows) {
        let incomplete = filter(ready(), (row) => row.kind != missing.kind || row.object != missing.object);
        let result = preflight.admission(incomplete); refused(result);
        t.ok(length(filter(result.observations, (row) => row.reason == "required-domain-proof-missing")) == 1,
            missing.kind + ":" + missing.object);
    }
    refused(preflight.admission([]));
});

t.test("any conflict, incomplete or unknown state refuses including optional observations", () => {
    for (let state in [ "conflict", "incomplete", "not-implemented", "success", null ]) {
        let rows = ready(); rows[0].state = state; refused(preflight.admission(rows), state == "conflict");
        rows = ready(); push(rows, { kind: "extra", object: "extra", state, reason: "fixed-reason" });
        refused(preflight.admission(rows), state == "conflict");
    }
    let rows = ready(); push(rows, null); refused(preflight.admission(rows));
});

t.test("diagnostic limits cannot hide any refusal in the complete proof set", () => {
    for (let state in [ "incomplete", "conflict", "success", null ]) {
        let rows = ready();
        for (let i = 0; i < 300; i++) push(rows, { kind: "extra", object: "fixed", state: "checked", reason: "fixed-reason" });
        rows[240].state = state;
        let result = preflight.admission(rows); refused(result, state == "conflict");
        t.eq(result.observations[0].state, state, "the failure is not hidden behind positive file evidence");
        t.eq(length(result.observations), 256);
        t.ok(length(filter(result.observations, (row) => row.reason == "observation-count-limit")) == 1);
    }
});

t.test("a checked installed component set is not refused merely for having many positive diagnostics", () => {
    let rows = ready();
    for (let i = 0; i < 128; i++) {
        push(rows, { kind: "ownership", object: "file-" + i, state: "checked", reason: "installed-component-content-checked" });
        push(rows, { kind: "files", object: "file-" + i, state: "checked", reason: "installed-component-content-checked" });
    }
    let result = preflight.admission(rows);
    t.eq([ result.result, result.complete, result.install_allowed ], [ "checked", true, true ]);
    t.eq(length(result.observations), 256);
    t.ok(length(filter(result.observations, (row) => row.reason == "checked-observations-omitted" && row.state == "checked")) == 1);
});

t.done();
