let t = require("t");
let stub = require("stub");
let fs = require("fs");
let rules = require("service.preflight_rules");

const QUERY4 = "exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -s KILL 2 /sbin/ip -Numeric -j -4 rule list";
const QUERY6 = replace(QUERY4, "-j -4", "-j -6");

function row(mark, mask, priority, table) {
    let value = { priority: priority ?? 105, src: "all", table: table ?? "105" };
    if (mark != null) value.fwmark = mark;
    if (mask != null) value.fwmask = mask;
    return value;
}

function has(result, reason, object) {
    return length(filter(result, (item) => item.reason == reason && (object == null || item.object == object))) > 0;
}

function collect(data4, data6) {
    stub.commands([[ QUERY4, { stdout: data4 } ], [ QUERY6, { stdout: data6 ?? data4 } ]]);
    let value = rules.collect();
    stub.restore();
    return value;
}

t.test("numeric tables, full unsigned marks, omitted masks and explicit zero masks are distinct", () => {
    let parsed = rules.parse(sprintf("%J", [ row("0x80000000"), row("4294967295", "0"), row("0", "0xffffffff") ]));
    t.eq(parsed.error, null);
    t.eq(parsed.rules[0].mark, 2147483648);
    t.eq(parsed.rules[0].mask, 4294967295);
    t.eq(parsed.rules[1].mask, 0);
    t.eq(parsed.rules[2].mark, 0);
});

t.test("mark predicate overlap matches the complete four-bit truth table", () => {
    for (let a = 0; a < 16; a++) for (let ma = 0; ma < 16; ma++)
        for (let b = 0; b < 16; b++) for (let mb = 0; mb < 16; mb++) {
            let any = false;
            for (let packet = 0; packet < 16; packet++)
                if ((packet & ma) == (a & ma) && (packet & mb) == (b & mb)) any = true;
            if (rules.overlaps(a, ma, b, mb) != any) die("four-bit predicate mismatch");
        }
    t.eq(rules.overlaps(0x04000000, 0x04000000, 0x00100000, 0x00100000), true);
    t.eq(rules.overlaps(0x80000000, 0x80000000, 0, 0x80000000), false);
});

t.test("outer whitespace is accepted and quoted whitespace is never silently removed", () => {
    t.eq(rules.parse(' [ { "priority" : 0, "src" : "all", "table" : "255" } ]\n').error, null);
    t.eq(rules.parse('[{"priority":0,"src":"a ll","table":"255"}]').error,
        "policy-rule-selector-or-action-unverified");
});

t.test("duplicate and escaped duplicate keys, trailing data, comments and alternative number encodings refuse", () => {
    for (let data in [ null, 42, {}, [], '[{"priority":1,"priority":2,"src":"all","table":"105"}]',
        '[{"priority":1,"pr\\u0069ority":2,"src":"all","table":"105"}]',
        '[] []', '[]/*private*/', '[{"priority":-0,"src":"all","table":"105"}]',
        '[{"priority":1e2,"src":"all","table":"105"}]', "[]\u0000", "[", "" ])
        t.eq(rules.parse(data).error, "policy-rule-json-invalid");
});

t.test("invalid numeric ranges and types never become empty or unmarked rules", () => {
    for (let data in [ row(1), row("1", true), row("0x100000000"), row("-1"), row("01"), row("0x"),
        row("1", "4294967296"), row("1", "0x100000000"), row(null, "0"),
        row("1", null, -1), row("1", null, 4294967296), row("1", null, true),
        row("1", null, 1, "loki"), row("1", null, 1, "0"), row("1", null, 1, "0105"),
        row("1", null, 1, 105), { priority: 1, src: null, table: "105" },
        { ...row("1"), protocol: "256" }, { ...row("1"), protocol: 4 },
        { ...row("1"), protocol: "private" } ])
        t.eq(rules.parse(sprintf("%J", [ data ])).error, "policy-rule-shape-invalid");
    for (let data in [ "{}", "null", "[null]", "[1]" ])
        t.eq(rules.parse(data).error, "policy-rule-shape-invalid");
});

t.test("significant unsupported selectors and actions remain incomplete", () => {
    for (let key in [ "not", "goto", "suppress_prefixlen", "l3mdev", "uid_start", "ipproto", "dport", "future-private-key" ]) {
        let value = row("0x4000000");
        value[key] = null;
        t.eq(rules.parse(sprintf("%J", [ value ])).error, "policy-rule-selector-or-action-unverified");
    }
});

t.test("interfaces remain data, with fixed limits and no values copied into commands or reports", () => {
    let value = row("0x4000000");
    value.iif = "lo";
    value.oif = "evil;'\"";
    value.protocol = "4";
    let data = sprintf("%J", [ value ]);
    let output = collect(data);
    t.ok(has(output, "policy-rule-snapshot-read-complete"));
    t.excludes(sprintf("%J", output), "evil");
    for (let bad in [ null, 42, [ "lo" ], "", "a b", "../private", "a:b", sprintf("%16s", "x") ]) {
        value.iif = bad;
        t.eq(rules.parse(sprintf("%J", [ value ])).error, "policy-rule-shape-invalid");
    }
});

t.test("rule and response bounds accept the edge and reject an extra input", () => {
    let values = [];
    for (let i = 0; i < 2048; i++) push(values, row(null, null, i, "254"));
    t.eq(length(rules.parse(sprintf("%J", values)).rules), 2048);
    push(values, row(null, null, 2048, "254"));
    t.eq(rules.parse(sprintf("%J", values)).error, "policy-rule-count-limit");
    t.eq(rules.parse("[]" + sprintf("%262143s", "")).error, "policy-rule-json-invalid");
    t.ok(has(collect("[]" + sprintf("%262143s", "")), "policy-rule-response-size-limit"));
});

t.test("default rules and legitimate duplicate priorities are preserved without a conflict claim", () => {
    let data = sprintf("%J", [ row(null, null, 0, "255"), row(null, null, 32766, "254"),
        row(null, null, 32767, "253"), row("0x4000000"), row("0x100000", "0x100000") ]);
    let output = collect(data);
    t.ok(has(output, "policy-rule-candidate-overlap-unverified", "ipv4-candidate-table"));
    t.ok(has(output, "policy-rule-candidate-overlap-unverified", "ipv6-fakeip-match-space"));
    t.eq(length(filter(output, (item) => item.state == "conflict")), 0);
    t.ok(has(output, "policy-rules-ownership-configuration-unverified"));
    t.ok(has(output, "policy-routes-and-namespace-unverified"));
});

t.test("changing order within one priority refuses the snapshot instead of sorting it away", () => {
    let first = sprintf("%J", [ row("0x4000000"), row("0x100000", "0x100000") ]);
    let second = sprintf("%J", [ row("0x100000", "0x100000"), row("0x4000000") ]);
    let seen = 0;
    stub.commands([[ QUERY4, () => ({ stdout: ++seen == 1 ? first : second }) ], [ QUERY6, { stdout: "[]" } ]]);
    let output = rules.collect();
    stub.restore();
    t.ok(has(output, "policy-rules-changed-during-read", "ipv4"));
    t.eq(has(output, "policy-rule-snapshot-read-complete", "ipv4"), false);
});

t.test("only the four fixed read queries run and raw data is never emitted", () => {
    let state = stub.commands([[ QUERY4, { stdout: "[]" } ], [ QUERY6, { stdout: "[]" } ]]);
    let captured = stub.capture(() => rules.collect());
    let commands = stub.command_lines();
    stub.restore();
    t.eq(commands, [ QUERY4, QUERY4, QUERY6, QUERY6 ]);
    t.eq(captured.stdout, "");
    t.eq(captured.stderr, "");
    t.eq(length(state.calls), 4);
});

t.test("status errors, noninteger close and pipe failures are incomplete without private details", () => {
    for (let failure in [ "open", "missing", "read", "data", "close", "status", "noninteger" ]) {
        let popen = fs.popen;
        let closed = 0;
        fs.popen = () => {
            if (failure == "open") die("private-open-error");
            if (failure == "missing") return null;
            return { read: () => { if (failure == "read") die("private-read-error"); return failure == "data" ? null : "[]"; },
                close: () => { closed++; if (failure == "close") die("private-close-error");
                    return failure == "status" ? 9 : failure == "noninteger" ? false : 0; } };
        };
        let output = rules.collect();
        fs.popen = popen;
        t.ok(has(output, "policy-rule-query-failed", "ipv4"));
        t.ok(has(output, "policy-rule-query-failed", "ipv6"));
        t.eq(closed, failure == "open" || failure == "missing" ? 0 : 2);
        t.excludes(sprintf("%J", output), "private");
    }
});

t.done();
