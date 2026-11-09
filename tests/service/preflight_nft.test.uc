let t = require("t");
let stub = require("stub");
let fs = require("fs");
let nft = require("service.preflight_nft");

// Real watchdog timing is covered by test_preflight_deadline.py; keep parser fixtures deterministic.
let query_exec = require("core.exec");
query_exec.deadline = (argv, seconds, limit) => {
    try { return query_exec.combined(argv, limit); }
    catch (e) { return { status: 1, output: "" }; }
};

const QUERY = "/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /usr/sbin/nft -j list tables";
const HEADER = { metainfo: { version: "1.0.9", release_name: "synthetic", json_schema_version: 1 } };

function snapshot(tables) {
    return sprintf("%J", { nftables: [ HEADER, ...tables ] });
}

function row(family, name) {
    return { table: { family, name, handle: 1 } };
}

function has(result, reason) {
    return length(filter(result, (item) => item.reason == reason)) > 0;
}

t.test("empty and known table inventories are bounded hints, never permission", () => {
    for (let tables in [ [], [ row("inet", "loki") ], [ row("ip", "podkop"), row("inet", "forkop") ] ]) {
        let data = snapshot(tables);
        let state = stub.commands([[ QUERY, { stdout: data } ]]);
        let output = nft.collect();
        t.eq(stub.command_lines(), [ QUERY, QUERY ]);
        t.eq(length(state.calls), 2);
        t.ok(has(output, "nft-table-list-read-complete"));
        t.ok(has(output, "nft-rules-and-namespace-unverified"));
        t.eq(has(output, "candidate-nft-table-origin-unverified"), length(tables) == 1 && tables[0].table.name == "loki");
        t.eq(has(output, "legacy-nft-table-content-unverified"), length(tables) == 2);
        t.eq(length(filter(output, (item) => item.state == "conflict")), 0);
        t.excludes(sprintf("%J", output), "podkop");
        t.excludes(sprintf("%J", output), "forkop");
        stub.restore();
    }
});

t.test("unknown names are never disclosed or mistaken for a proven conflict", () => {
    let data = snapshot([ row("inet", "synthetic-secret-table") ]);
    stub.commands([[ QUERY, { stdout: data } ]]);
    let output = nft.collect();
    stub.restore();
    t.ok(has(output, "nft-table-list-read-complete"));
    t.excludes(sprintf("%J", output), "synthetic-secret");
    t.eq(length(filter(output, (item) => item.state == "conflict")), 0);
});

t.test("malformed, duplicated and future JSON cannot become an empty table list", () => {
    for (let data in [ null, 42, "", "[]", "{}", "{", "{}{}", snapshot([]) + "\u0000",
        '{"nftables":[{"metainfo":{"json_schema_version":1}},{"table":{"family":"inet","name":"loki","name":"fw4"}}]}',
        '{"nftables":[{"metainfo":{"json_schema_version":1}},{"table":{"family":"inet","name":"loki","n\\u0061me":"fw4"}}]}',
        snapshot([ row("inet", "x"), row("inet", "x") ]) ])
        t.ok(nft.parse(data).error != null);
    t.eq(nft.parse('{"nftables":[{"metainfo":{"json_schema_version":2}}]}').error,
        "nft-table-schema-unverified");
    for (let schema in [ "true", "null", "1.0" ])
        t.ok(nft.parse('{"nftables":[{"metainfo":{"json_schema_version":' + schema + '}}]}').error != null);
    t.eq(nft.parse('{"nftables":[]}').error, "nft-table-shape-invalid");
});

t.test("byte and table limits reject the next item without retaining input", () => {
    let tables = [];
    for (let i = 0; i < 512; i++) push(tables, row("inet", "t" + i));
    t.eq(nft.parse(snapshot(tables)).error, null);
    push(tables, row("inet", "t512"));
    t.eq(nft.parse(snapshot(tables)).error, "nft-table-shape-invalid");
    let large = snapshot([]) + sprintf("%65536s", "x");
    stub.commands([[ QUERY, { stdout: large } ]]);
    let output = nft.collect();
    stub.restore();
    t.ok(has(output, "nft-table-response-size-limit"));
    t.excludes(sprintf("%J", output), "xxxxx");
});

t.test("changed inventory and query failures stay incomplete with fixed reasons", () => {
    let first = snapshot([]);
    let second = snapshot([ row("inet", "loki") ]);
    let calls = 0;
    stub.commands([[ QUERY, () => ({ stdout: ++calls == 1 ? first : second }) ]]);
    t.ok(has(nft.collect(), "nft-table-list-changed-during-read"));
    stub.restore();
    for (let failure in [ "open", "missing", "read", "data", "close", "status" ]) {
        let original = fs.popen;
        let closed = 0;
        fs.popen = () => {
            if (failure == "open") die("synthetic-secret");
            if (failure == "missing") return null;
            return { read: () => { if (failure == "read") die("synthetic-secret"); return failure == "data" ? null : first; },
                close: () => { closed++; if (failure == "close") die("synthetic-secret"); return failure == "status" ? 1 : 0; } };
        };
        let output = nft.collect();
        fs.popen = original;
        t.ok(has(output, "nft-table-query-failed"));
        t.eq(closed, failure == "open" || failure == "missing" ? 0 : 1);
        t.excludes(sprintf("%J", output), "synthetic-secret");
    }
});

t.done();
