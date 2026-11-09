let t = require("t"), fs = require("fs"), stub = require("stub"), nft = require("service.preflight_nft"), exec = require("core.exec");
exec.deadline = (argv, seconds, limit) => {
    try { return exec.combined(argv, limit); } catch (e) { return { status: 1, output: "" }; }
};
const TABLES = "/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /usr/sbin/nft -j list tables";
const RULES = "/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /usr/sbin/nft -s -j list ruleset";
const HEADER = { metainfo: { json_schema_version: 1 } };
function model(expr) {
    return { nftables: [ HEADER, { table: { family: "inet", name: "fw4" } },
        { chain: { family: "inet", table: "fw4", name: "input", type: "filter", hook: "input", prio: 0, policy: "drop" } },
        { chain: { family: "inet", table: "fw4", name: "target" } },
        { rule: { family: "inet", table: "fw4", chain: "input", expr, comment: "synthetic-private tproxy mark" } } ] };
}
function parse(expr) { return nft.parse_rules(sprintf("%J", model(expr))); }
function has(rows, reason) { return length(filter(rows, (row) => row.reason == reason)) > 0; }
function collect(response, scope) {
    stub.commands([[ TABLES, { stdout: sprintf("%J", { nftables: [ HEADER, { table: { family: "inet", name: "fw4" } } ] }) } ], [ RULES, response ]]);
    let result, error;
    try { result = nft.collect(scope ?? { identities: {} }); } catch (e) { error = e; }
    stub.restore(); if (error != null) die(error);
    t.excludes(sprintf("%J", result), "synthetic-private");
    return result;
}

t.test("ordinary filtering, literal verdict maps, counters and supported header adjustments are compatible", () => {
    let expr = [ { match: { op: "==", left: { meta: { key: "iifname" } }, right: "lo" } }, { counter: null },
        { vmap: { key: { ct: { key: "state" } }, data: { set: [ [ "invalid", { drop: null } ], [ "established", { accept: null } ] ] } } },
        { mangle: { key: { payload: { protocol: "ip", field: "dscp" } }, value: 0 } },
        { mangle: { key: { "tcp option": { name: "maxseg", field: "size" } }, value: { rt: { key: "mtu" } } } },
        { jump: { target: "target" } }, { masquerade: null }, { reject: { type: "icmpx", expr: "port-unreachable" } } ];
    t.eq(parse(expr).error, null);
    let result = collect({ stdout: sprintf("%J", model(expr)) });
    t.ok(has(result, "nft-compatible-rules-checked"));
});

t.test("packet interception, mark usage, unknown statements and unverified verdict maps refuse", () => {
    for (let op in [ "tproxy", "redirect", "dnat", "snat", "queue", "dup", "fwd", "notrack", "flow", "xt", "meter", "future", "limit", "ct helper" ])
        t.ok(parse([ { [op]: null } ]).error != null, op);
    for (let statement in [ { mangle: { key: { meta: { key: "mark" } }, value: 1 } },
        { match: { op: "==", left: { ct: { key: "mark" } }, right: 0 } },
        { mangle: { key: { payload: { protocol: "ip", field: "daddr" } }, value: "127.0.0.42" } },
        { vmap: { key: 1, data: "@unverified-map" } },
        { vmap: { key: 1, data: { set: [ [ 1, { queue: null } ] ] } } }, { jump: { target: "missing" } } ])
        t.ok(parse([ statement ]).error != null);
});

t.test("truncation, duplicate fields, unknown objects and finite byte/node bounds refuse", () => {
    for (let data in [ "", "{}", "[]", "{", '{"nftables":[{"metainfo":{"json_schema_version":1,"json_schema_version":1}}]}',
        sprintf("%1048577s", "x"), sprintf("%J", { nftables: [ HEADER, { future: {} } ] }) ])
        t.ok(nft.parse_rules(data).error != null);
    let value = model([]); value.nftables[4].rule.chain = "missing";
    t.ok(nft.parse_rules(sprintf("%J", value)).error != null);
    let nested = 0; for (let i = 0; i < 40; i++) nested = [ nested ];
    t.ok(parse([ { match: { op: "==", left: nested, right: 0 } } ]).error != null);
    let wide = []; for (let i = 0; i < 32768; i++) push(wide, 0);
    t.eq(parse([ { match: { op: "==", left: wide, right: 0 } } ]).error, "nft-rules-node-limit");
    let data = sprintf("%J", { nftables: [ HEADER ] });
    t.eq(nft.parse_rules(data + sprintf("%" + (1048576 - length(data)) + "s", "")).error, null);
});

t.test("traffic counters do not change the semantic snapshot while changed rules and failed queries remain incomplete", () => {
    let first = model([ { counter: { packets: 1, bytes: 10 } }, { accept: null } ]);
    let second = model([ { counter: { packets: 2, bytes: 20 } }, { accept: null } ]);
    t.eq(nft.parse_rules(sprintf("%J", first)).snapshot, nft.parse_rules(sprintf("%J", second)).snapshot);
    let calls = 0;
    t.ok(has(collect(() => ({ stdout: sprintf("%J", ++calls == 1 ? first : second) })), "nft-compatible-rules-checked"));
    second.nftables[4].rule.expr = [ { drop: null } ]; calls = 0;
    t.ok(has(collect(() => ({ stdout: sprintf("%J", ++calls == 1 ? first : second) })), "nft-rules-changed-during-read"));
    t.ok(has(collect({ status: 1, stdout: "" }), "nft-rules-query-failed"));
    t.ok(has(collect({ stdout: sprintf("%1048577s", "x") }), "nft-rules-response-size-limit"));
    t.ok(has(collect({ stdout: sprintf("%J", first) }, { identities: {}, error: "scope" }), "nft-rules-and-namespace-unverified"));
});

function own_rule() {
    let value = model([ { match: { op: "==", left: { "&": [ { meta: { key: "mark" } }, 67108864 ] }, right: 67108864 } },
        { counter: null }, { accept: null } ]);
    value.nftables[4].rule.comment = "loki: TPROXY traffic";
    return value;
}

t.test("only the checksum-bound own fw4 input rule can use the reserved packet mark", () => {
    t.eq(nft.parse_rules(sprintf("%J", own_rule()), true).error, null);
    t.eq(nft.parse_rules(sprintf("%J", own_rule())).error, "nft-mark-usage-unverified");
    for (let fault in [ "family", "table", "chain", "comment", "mask", "value", "operator", "action", "extra", "counter", "handle", "extra-field" ]) {
        let value = own_rule(), rule = value.nftables[4].rule;
        if (fault == "counter") rule.expr[1] = { counter: { packets: { meta: { key: "mark" } }, bytes: 0 } };
        if (fault == "handle") rule.handle = { meta: { key: "mark" } };
        if (fault == "extra-field") rule.unverified = { meta: { key: "mark" } };
        if (fault == "family") rule.family = "ip";
        if (fault == "table") rule.table = "other";
        if (fault == "chain") rule.chain = "target";
        if (fault == "comment") rule.comment = "copied label";
        if (fault == "mask") rule.expr[0].match.left["&"][1] = 1;
        if (fault == "value") rule.expr[0].match.right = 1;
        if (fault == "operator") rule.expr[0].match.op = "!=";
        if (fault == "action") rule.expr[2] = { drop: null };
        if (fault == "extra") push(rule.expr, { match: { op: "==", left: { ct: { key: "mark" } }, right: 0 } });
        t.ok(nft.parse_rules(sprintf("%J", value), true).error != null, fault);
    }
    let value = own_rule(); push(value.nftables, { rule: { family: "inet", table: "fw4", chain: "input",
        expr: [ { match: { op: "==", left: { meta: { key: "mark" } }, right: 67108864 } }, { accept: null } ] } });
    t.eq(nft.parse_rules(sprintf("%J", value), true).error, "nft-mark-usage-unverified", "another rule cannot borrow the own fragment proof");
});

t.test("loaded own mark admission requires the protected exact file checksum and exclusive own proof", () => {
    let root = stub.tmpdir(), target = "/usr/share/nftables.d/chain-pre/input/loki.nft";
    fs.chmod(root, 0755);
    stub.real.system("umask 022; mkdir -p '" + root + "/usr/share/nftables.d/chain-pre/input'");
    let body = fs.readfile("../loki/files" + target); fs.writefile(root + target, body); fs.chmod(root + target, 0644);
    let file = { path: target, type: "file", mode: 0644, size: length(body), package: "loki", version: "2" };
    file.sha256 = require("singbox.runtime").file_digest(root + target, file); t.ok(file.sha256 != null);
    let deadline = exec.deadline, failure;
    exec.deadline = (argv) => {
        let query = join(" ", argv);
        if (query == TABLES) return { status: 0, output: sprintf("%J", { nftables: [ HEADER, { table: { family: "inet", name: "fw4" } } ] }) };
        if (query == RULES) return { status: 0, output: sprintf("%J", own_rule()) };
        die("unexpected command");
    };
    try {
        for (let fault in [ "valid", "missing", "foreign", "changed" ]) {
            if (fault == "changed") fs.writefile(root + target, replace(body, "counter accept", "counter drop  "));
            let proof = fault == "missing" ? {} : { [target]: { ...file, package: fault == "foreign" ? "other" : "loki" } };
            let rows = nft.collect({ identities: {} }, root, proof);
            t.eq(has(rows, "nft-compatible-rules-checked"), fault == "valid", fault);
            t.excludes(sprintf("%J", rows), root);
        }
    }
    catch (e) { failure = e; }
    exec.deadline = deadline; if (failure != null) die(failure);
});

t.done();
