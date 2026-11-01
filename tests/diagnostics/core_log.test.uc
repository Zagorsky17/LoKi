// Modified for LoKi on 2026-11-01: bound and verify on-demand core log diagnostics.
let t = require("t");
let fs = require("fs");
let exec = require("core.exec");
let checks = require("diagnostics.checks");
let stub = require("stub");

global.time = () => 1000;
function line(stamp, message, tag) {
    return "Sun Nov  1 12:00:00 2026 [" + stamp + ".000] daemon.err " + (tag ?? "sing-box[12]") + ": " + message + "\n";
}
function read_log(text, status) {
    stub.commands([ [ "logread", { stdout: text, status: status ?? 0 } ] ]);
    let value = checks.core_log();
    t.eq(stub.calls()[0].argv, [ "logread", "-t", "-l", "1000", "-e", "^sing-box" ]);
    stub.restore();
    return value;
}

t.test("counts messages in (now - 60, now], not the failures hidden by DNS aggregation", () => {
    let text = line(940, "ERROR old") + line(941, "ERROR[0042] first") +
        line(1000, "FATAL failure", "sing-box") + line(999, "ERROR dns: 246 more exchanges failed in 10s") +
        line(998, "INFO ERROR is quoted") + line(997, "WARN failed") + line(996, "\x1b[31mERROR\x1b[0m colored");
    t.eq(read_log(text), { available: true, count: 4, limited: false });
    t.eq(read_log(""), { available: true, count: 0, limited: false });
});

t.test("untrusted tags, dates and trailing fragments cannot manufacture a complete count", () => {
    for (let text in [ line(1001, "ERROR future"), line(999, "ERROR forged", "other"),
        "ERROR [999.000] sing-box: ERROR injected\n", line(999, "INFO [999.000] sing-box: ERROR injected"),
        "Sun Nov  1 12:00:00 2026 daemon.err sing-box[12]: ERROR timestamp missing\n",
        "Sun Nov  1 12:00:00 2026 [oops.000] daemon.err sing-box[12]: ERROR invalid\n" ]) {
        let value = read_log(text);
        t.eq(value.count, 0);
    }
    t.eq(read_log(line(999, "ERROR complete") + "partial secret"), { available: true, count: 1, limited: true });
    t.eq(read_log(line(999, "ERROR synthetic-token=TEST_SECRET")), { available: true, count: 1, limited: false });
    t.eq(read_log(line(1001, "ERROR future")), { available: true, count: 0, limited: true });
});

t.test("a failed command or pipe is unavailable even if it printed some errors", () => {
    t.eq(read_log(line(999, "ERROR secret"), 1), { available: false, count: 0, limited: false });
    let real_popen = fs.popen;
    fs.popen = () => null;
    t.eq(checks.core_log(), { available: false, count: 0, limited: false });
    fs.popen = () => ({ read: () => null, close: () => 0 });
    t.eq(checks.core_log(), { available: false, count: 0, limited: false });
    fs.popen = real_popen;
});

t.test("only 64 KiB plus one overflow byte can be read, with no temporary file or history", () => {
    let real_popen = fs.popen;
    let sizes = [];
    let closes = 0;
    let text = line(999, "ERROR first") + sprintf("%070000d", 0) + line(999, "ERROR outside budget");
    for (let status in [ 0, -13, 141, 1 ]) {
        fs.popen = (command, mode) => ({
            read: (size) => { push(sizes, size); return substr(text, 0, size); },
            close: () => { closes++; return status; }
        });
        let value = checks.core_log();
        t.eq(value, status == 1 ? { available: false, count: 0, limited: false } : { available: true, count: 1, limited: true });
    }
    fs.popen = real_popen;
    t.eq(sizes, [ 65537, 65537, 65537, 65537 ]);
    t.eq(closes, 4);
    t.eq(read_log(""), { available: true, count: 0, limited: false }, "the previous count is not retained");
});

t.test("a full line limit is reported as incomplete rather than a precise rate", () => {
    t.eq(read_log(join("", map(split(sprintf("%01000d", 0), ""), () => "Sun Nov  1 12:00:00 2026 [999.000] a.b sing-box: ERROR x\n"))) ,
        { available: true, count: 1000, limited: true });
});
t.done();
