let t = require("t");
let stub = require("stub");
let fs = require("fs");
let rules = require("service.preflight_rules");

const QUERY4 = "exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -s KILL 2 /sbin/ip -Numeric -j -4 route show table all";
const QUERY6 = replace(QUERY4, "-j -4", "-j -6");

function has(result, reason, object) {
    return length(filter(result, (item) => item.reason == reason && (object == null || item.object == object))) > 0;
}

function collect(data4, data6) {
    stub.commands([[ QUERY4, { stdout: data4 } ], [ QUERY6, { stdout: data6 ?? "[]" } ]]);
    let result = rules.collect_routes();
    stub.restore();
    return result;
}

t.test("numeric route types and implicit main/unicast match the native ip output", () => {
    let data = '[{"dst":"192.0.2.0/24","dev":"br-lan","protocol":"2","scope":"253","prefsrc":"192.0.2.1","flags":[]},' +
        '{"type":"2","dst":"default","dev":"lo","table":"105","scope":"254","flags":[]}]';
    let parsed = rules.parse_routes(data, 4);
    t.eq(parsed.error, null);
    t.eq(parsed.routes[0].table, 254);
    t.eq(parsed.routes[0].type, 1);
    t.eq(parsed.routes[1].table, 105);
    t.eq(parsed.routes[1].type, 2);
    t.eq(rules.parse_routes('[{"dst":"2001:db8::/64","dev":"br-lan","protocol":"2","metric":256,"flags":[],"pref":"medium"}]', 6).error, null);
    t.eq(rules.parse_routes('[{"type":"6","dst":"default","table":"200","flags":[]}]', 4).error, null);
    t.eq(rules.parse_routes('[{"type":"9","dst":"default","table":"4294967295","protocol":"255","scope":"255","metric":4294967295,"flags":["onlink"]}]', 4).error, null);
});

t.test("malformed, duplicate and noncanonical JSON never becomes an empty routing table", () => {
    for (let data in [ null, 42, {}, [], "", "[", "[] []", "[]/*private*/", "[]\u0000",
        '[{"dst":"default","dst":"192.0.2.1"}]', '[{"dst":"default","d\\u0073t":"192.0.2.1"}]',
        '[{"dst":"default","metric":-0}]', '[{"dst":"default","metric":1e2}]' ])
        t.eq(rules.parse_routes(data, 4).error, "policy-route-json-invalid");
    for (let data in [ "{}", "null", "[null]", "[1]", "[{}]" ])
        t.eq(rules.parse_routes(data, 4).error, "policy-route-shape-invalid");
    for (let family in [ null, "4", true, 5 ])
        t.eq(rules.parse_routes("[]", family).error, "policy-route-family-invalid");
});

t.test("address family, numeric bounds and flags are validated before reporting a snapshot", () => {
    for (let row in [ { dst: "2001:db8::/64" }, { dst: "192.0.2.1/33" }, { dst: "private.invalid" },
        { dst: "default", gateway: "::1" }, { dst: "default", prefsrc: "192.0.2.999" },
        { dst: "default", table: 105 }, { dst: "default", table: "0" }, { dst: "default", table: "0105" },
        { dst: "default", table: "4294967296" }, { dst: "default", type: 2 }, { dst: "default", type: "0" },
        { dst: "default", protocol: "256" }, { dst: "default", scope: 254 }, { dst: "default", metric: -1 },
        { dst: "default", metric: 4294967296 }, { dst: "default", metric: true }, { dst: "default", dev: "../private" },
        { dst: "default", dev: "a:b" }, { dst: "default", flags: "onlink" }, { dst: "default", flags: [ null ] },
        { dst: "default", flags: [ "onlink", "onlink" ] }, { dst: "default", pref: 0 },
        { dst: "192.0.2.1\u0000private" }, { dst: "default", gateway: "192.0.2.1\u0000x" },
        { dst: "default", dev: "lo\u0000x" }, { dst: "default", table: "105\u0000x" },
        { dst: "default", protocol: "2\u0000x" } ])
        t.eq(rules.parse_routes(sprintf("%J", [ row ]), 4).error, "policy-route-shape-invalid");
});

t.test("unreviewed selectors and actions remain explicitly incomplete", () => {
    for (let key in [ "nhid", "nexthops", "encap", "from", "tos", "expires", "metrics", "future-private-key" ]) {
        let row = { dst: "default" };
        row[key] = null;
        t.eq(rules.parse_routes(sprintf("%J", [ row ]), 4).error, "policy-route-selector-or-action-unverified");
    }
    t.eq(rules.parse_routes('[{"dst":"default","flags":["future-private-flag"]}]', 4).error,
        "policy-route-selector-or-action-unverified");
});

t.test("route and byte bounds accept their edge without silently dropping an extra route", () => {
    let rows = [];
    for (let i = 0; i < 2048; i++) push(rows, { dst: "192.0.2.1" });
    t.eq(length(rules.parse_routes(sprintf("%J", rows), 4).routes), 2048);
    push(rows, { dst: "192.0.2.2" });
    t.eq(rules.parse_routes(sprintf("%J", rows), 4).error, "policy-route-count-limit");
    t.ok(has(collect("[]" + sprintf("%262142s", "")), "policy-route-snapshot-read-complete", "ipv4"));
    t.ok(has(collect("[]" + sprintf("%262143s", "")), "policy-route-response-size-limit", "ipv4"));
});

t.test("all reads are fixed and candidate table hints reveal no addresses or interface values", () => {
    let data = sprintf("%J", [ { dst: "default", dev: "evil;'\"", table: "105", type: "2", flags: [] } ]);
    stub.commands([[ QUERY4, { stdout: data } ], [ QUERY6, { stdout: "[]" } ]]);
    let captured = stub.capture(() => rules.collect_routes());
    let commands = stub.command_lines();
    stub.restore();
    t.eq(commands, [ QUERY4, QUERY4, QUERY6, QUERY6 ]);
    t.eq(captured.stdout, "");
    t.eq(captured.stderr, "");
    let result = collect(data);
    t.ok(has(result, "policy-route-candidate-table-unverified", "ipv4-candidate-table"));
    t.eq(length(filter(result, (item) => item.state == "conflict")), 0);
    t.excludes(sprintf("%J", result), "evil");
    t.ok(has(result, "policy-routes-ownership-configuration-unverified"));
});

t.test("changed route order or contents refuses just the affected snapshot", () => {
    let first = '[{"dst":"192.0.2.0/24"},{"dst":"198.51.100.0/24"}]';
    let second = '[{"dst":"198.51.100.0/24"},{"dst":"192.0.2.0/24"}]';
    let seen = 0;
    stub.commands([[ QUERY4, () => ({ stdout: ++seen == 1 ? first : second }) ], [ QUERY6, { stdout: "[]" } ]]);
    let result = rules.collect_routes();
    stub.restore();
    t.ok(has(result, "policy-routes-changed-during-read", "ipv4"));
    t.eq(has(result, "policy-route-snapshot-read-complete", "ipv4"), false);
    t.ok(has(result, "policy-route-snapshot-read-complete", "ipv6"));
    t.excludes(sprintf("%J", result), "192.0.2");
});

t.test("query and close failures are incomplete without exposing exception text", () => {
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
        let result = rules.collect_routes();
        fs.popen = popen;
        t.ok(has(result, "policy-route-query-failed", "ipv4"));
        t.ok(has(result, "policy-route-query-failed", "ipv6"));
        t.eq(closed, failure == "open" || failure == "missing" ? 0 : 2);
        t.excludes(sprintf("%J", result), "private");
    }
});

t.test("namespace identity is checked before and after reads without revealing ids", () => {
    for (let mode in [ "same", "other", "changed", "missing", "invalid", "nul", "error" ]) {
        let readlink = fs.readlink;
        let calls = 0;
        fs.readlink = (path) => {
            calls++;
            t.ok(path == "/proc/self/ns/net" || path == "/proc/1/ns/net");
            if (mode == "error") die("private-namespace-error");
            if (mode == "missing") return null;
            if (mode == "invalid") return "net:[0]";
            if (mode == "nul") return "net:[123]\u0000private";
            if (mode == "changed" && calls > 2) return "net:[124]";
            return mode == "other" && path == "/proc/1/ns/net" ? "net:[124]" : "net:[123]";
        };
        let result = collect("[]");
        fs.readlink = readlink;
        t.eq(calls, mode == "error" ? 2 : 4);
        let reason = mode == "same" ? "policy-route-network-namespace-checked" :
            mode == "other" ? "policy-route-noninitial-network-namespace" :
            mode == "changed" ? "policy-route-namespace-changed-during-read" : "policy-route-namespace-unavailable";
        t.ok(has(result, reason, "network-namespace"));
        t.eq(has(result, "policy-route-network-namespace-checked"), mode == "same");
        t.ok(has(result, "policy-route-snapshot-read-complete", "ipv4"));
        t.excludes(sprintf("%J", result), "net:[");
        t.excludes(sprintf("%J", result), "private");
    }
});

t.done();
