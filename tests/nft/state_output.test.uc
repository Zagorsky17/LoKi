let t = require("t"), fs = require("fs"), fixture = require("fixture");
let state = require("nft.state"), exec = require("core.exec");
const LIMIT = 1048576;
const RULE = "106: from all fwmark 0x8000000/0x8000000 oif eth1 lookup main\n";
const SNAPSHOT = "table inet loki {\n chain capture_pause {\n }\n}\n@@loki-runtime-snapshot@@\n" +
    "local default dev lo scope host\n105: from all fwmark 0x4000000/0x4000000 lookup loki\n@@loki-runtime-snapshot@@\n";

function pipe(fn, output, status, broken) {
    let popen = fs.popen, amount = null, closed = 0, result, error;
    fs.popen = () => ({ read: (count) => { amount = count; if (broken) die("synthetic-read-failure"); return output; }, close: () => { closed++; return status ?? 0; } });
    try { result = fn(); } catch (e) { error = e; }
    fs.popen = popen;
    return { result, amount, closed, error };
}

t.test("oversized ip output cannot supply a partially trusted routing device", () => {
    let result = pipe(() => state.bound_rule_devices("-4", "106", "0x8000000"), RULE + sprintf("%1048577s", "x"));
    if (result.error != null) die(result.error);
    t.eq(result.result, []); t.eq(result.amount, LIMIT + 1); t.eq(result.closed, 1);
});

t.test("oversized runtime snapshots are unhealthy and reads remain bounded", () => {
    fixture.kernel_ipv6(null);
    let result = pipe(() => state.runtime_network_configured("loki", "loki", "0x4000000"), SNAPSHOT + sprintf("%1048577s", "x"));
    if (result.error != null) die(result.error);
    t.eq(result.result, false); t.eq(result.amount, LIMIT + 1); t.eq(result.closed, 1);
});

t.test("normal route status and partial IPv6-disabled snapshot semantics are preserved", () => {
    for (let status in [ 0, 1 ]) {
        let result = pipe(() => state.bound_rule_devices("-4", "106", "0x8000000"), RULE, status);
        if (result.error != null) die(result.error);
        t.eq(result.result, status == 0 ? [ "eth1" ] : []); t.eq(result.closed, 1);
        fixture.kernel_ipv6(null);
        result = pipe(() => state.runtime_network_configured("loki", "loki", "0x4000000"), SNAPSHOT, status);
        if (result.error != null) die(result.error);
        t.eq(result.result, true); t.eq(result.closed, 1);
    }
});

t.test("a failed bounded read closes its pipe before reporting failure", () => {
    let result = pipe(() => state.bound_rule_devices("-4", "106", "0x8000000"), "", 0, true);
    t.ok(result.error != null); t.eq(result.closed, 1);
});

t.test("invalid stdout budgets cannot launch an external command", () => {
    for (let limit in [ 0, -1, 1048577, "1024" ]) {
        let result = pipe(() => exec.capture([ "synthetic-never-run" ], limit), "data");
        if (result.error != null) die(result.error);
        t.eq(result.result, { status: 1, stdout: "", output_limit: true }); t.eq(result.amount, null); t.eq(result.closed, 0);
    }
});

t.test("native stdout pipes accept the exact bound, reject overflow and discard stderr", () => {
    for (let size in [ LIMIT, LIMIT + 1 ]) {
        let result = exec.capture([ "/usr/bin/python3", "-c", "import sys;sys.stdout.buffer.write(b'x'*" + size + ");sys.stderr.write('synthetic-private-stderr')" ], LIMIT);
        t.eq(result.output_limit === true, size > LIMIT);
        t.eq(length(result.stdout), size > LIMIT ? 0 : LIMIT);
        t.excludes(result.stdout, "synthetic-private-stderr");
        if (size == LIMIT) t.eq(result.status, 0);
    }
});

t.done();
