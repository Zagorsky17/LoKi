let t = require("t");
let stub = require("stub");
let exec = require("core.exec");
let fs = require("fs");

t.test("arguments reach the command exactly, whatever they contain", () => {
    stub.commands([ [ () => true, { status: 0 } ] ]);
    exec.run([ "logger", "it's", "a; rm -rf /", "$(id)" ]);
    t.eq(stub.calls()[0].argv, [ "logger", "it's", "a; rm -rf /", "$(id)" ]);
    stub.restore();
});

t.test("status discards output and reports the exit code", () => {
    stub.commands([ [ "false", { status: 1 } ] ]);
    t.eq(exec.status([ "false" ]), 1);
    t.ok(!exec.ok([ "false" ]));
    t.contains(stub.calls()[0].command, ">/dev/null 2>&1");
    stub.restore();
});

t.test("output is the stdout of a command that succeeded, null otherwise", () => {
    stub.commands([
        [ "ip -4 rule", { status: 0, stdout: "105:\tfrom all\n" } ],
        [ "nft list", { status: 1, stdout: "partial" } ]
    ]);
    t.eq(exec.output([ "ip", "-4", "rule" ]), "105:\tfrom all\n");
    t.eq(exec.output([ "nft", "list" ]), null);
    t.eq(exec.capture([ "nft", "list" ]), { status: 1, stdout: "partial" });
    stub.restore();
});

t.test("feed hands the text to the command's stdin", () => {
    stub.commands([ [ "nft -f -", { status: 0 } ] ]);
    t.eq(exec.feed([ "nft", "-f", "-" ], "add table inet t\n").status, 0);
    t.eq(stub.calls()[0].stdin, "add table inet t\n");
    stub.restore();
});

t.test("a background child is detached from the procd lock descriptor", () => {
    stub.commands([ [ () => true, { status: 0 } ] ]);
    exec.background([ "/etc/init.d/loki", "reload", "pending" ]);
    t.contains(stub.calls()[0].command, "1000>&- &");
    stub.restore();
});

t.test("log tags the message with its level and gives syslog the matching priority", () => {
    stub.commands([ [ () => true, { status: 0 } ] ]);
    exec.log("warn", "loki-core is slow");
    exec.log("error", "loki-core is gone");
    exec.log("info", "loki-core is back");
    t.eq(stub.command_lines(), [
        "logger -t loki -p user.warning [warn] loki-core is slow",
        "logger -t loki -p user.err [error] loki-core is gone",
        "logger -t loki -p user.info [info] loki-core is back"
    ]);
    stub.restore();
});

t.test("combined output can be bounded without changing the unbounded callers", () => {
    let original = fs.popen;
    let reads = [], closes = 0;
    try {
        fs.popen = () => ({ read: (size) => { push(reads, size); return "abc"; }, close: () => { closes++; return 7; } });
        t.eq(exec.combined([ "synthetic" ], 3), { status: 7, output: "abc" });
        t.eq(exec.combined([ "synthetic" ]), { status: 7, output: "abc" });
        t.eq(reads, [ 4, "all" ]);
        t.eq(closes, 2);
    }
    catch (e) { fs.popen = original; die(e); }
    fs.popen = original;
});

t.test("an output limit refuses even a successful command and does not return partial data", () => {
    let original = fs.popen;
    let closes = 0;
    try {
        fs.popen = () => ({ read: () => "synthetic-secret", close: () => { closes++; return 0; } });
        let result = exec.combined([ "synthetic" ], 3);
        t.eq(result, { status: 1, output: "", output_limit: true });
        t.eq(closes, 1);
    }
    catch (e) { fs.popen = original; die(e); }
    fs.popen = original;
});

t.test("invalid output bounds are refused before opening a child", () => {
    let original = fs.popen;
    let calls = 0;
    try {
        fs.popen = () => { calls++; return { read: () => "", close: () => 0 }; };
        for (let limit in [ 0, -1, "all", true, 1048577 ])
            t.eq(exec.combined([ "synthetic" ], limit), { status: 1, output: "", output_limit: true });
        t.eq(calls, 0);
    }
    catch (e) { fs.popen = original; die(e); }
    fs.popen = original;
});

t.test("a failed pipe read still closes the child pipe", () => {
    let original = fs.popen;
    let closes = 0, failed = false;
    try {
        fs.popen = () => ({ read: () => die("synthetic read failure"), close: () => { closes++; return 1; } });
        try { exec.combined([ "synthetic" ], 3); }
        catch (e) { failed = true; }
        t.ok(failed);
        t.eq(closes, 1);
    }
    catch (e) { fs.popen = original; die(e); }
    fs.popen = original;
});

t.done();
