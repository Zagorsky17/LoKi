let t = require("t");
let stub = require("stub");
let fs = require("fs");
let common = require("core.common");
let worker = require("service.worker");
let sync = require("nft.ruleset_sync");

function replacing(options, fn) {
    let directory = stub.tmpdir();
    let pid_file = directory + "/worker.pid";
    let old = sync.worker_spec(sprintf("%064x", 1));
    let next = sync.worker_spec(sprintf("%064x", 2));
    let service_pid_file = old.pid_file;
    old.pid_file = next.pid_file = pid_file;
    let original = { readfile: fs.readfile, unlink: fs.unlink, ensure: common.ensure_dir,
        alive: common.pid_alive, sleep: global.sleep };
    let elapsed = 0;
    let gone_at = null;
    let alive = true;
    let added = false;
    let logs = [];
    let signals = [];
    fs.writefile(pid_file, "1234\n");
    fs.readfile = (path) => path == "/proc/1234/cmdline" ? "ucode\0" + join("\0", options.unrelated ? [ "other-worker" ] : old.command) + "\0" :
        path == "/proc/5678/cmdline" ? "ucode\0" + join("\0", next.command) + "\0" :
        original.readfile(path == service_pid_file ? pid_file : path);
    fs.unlink = (path) => original.unlink(path == service_pid_file ? pid_file : path);
    common.ensure_dir = (path) => path == common.parent_dir(service_pid_file) || original.ensure(path);
    common.pid_alive = (pid) => pid == "1234" ? alive : pid == "5678" && added;
    global.sleep = (milliseconds) => {
        elapsed += milliseconds;
        if (gone_at != null && elapsed >= gone_at) alive = false;
    };
    stub.commands([
        [ "ubus call service delete", {} ],
        [ "ubus call service add", () => {
            if (alive && !options.unrelated) return { status: 1 };
            added = true;
            fs.writefile(pid_file, "5678\n");
            return {};
        } ],
        [ "kill", (argv) => {
            push(signals, argv);
            if (argv[1] == "-KILL" && !options.unkillable) gone_at = elapsed + 10;
            return { status: options.unkillable ? 1 : 0 };
        } ],
        stub.logger(logs)
    ]);
    let error;
    try { fn({ old, next, signals, logs, alive: () => alive, elapsed: () => elapsed }); }
    catch (e) { error = e; }
    fs.readfile = original.readfile;
    fs.unlink = original.unlink;
    common.ensure_dir = original.ensure;
    common.pid_alive = original.alive;
    global.sleep = original.sleep;
    stub.restore();
    if (error != null) die(error.message);
}

t.test("Apply waits for the previous generation to exit before starting its replacement", () => {
    replacing({}, (state) => {
        t.ok(sync.start_worker({ generation: state.next.data.generation, sections: [ {} ] }));
        t.ok(!state.alive());
        t.eq(fs.readfile(state.next.pid_file), "5678\n");
        t.contains(state.signals, [ "kill", "-KILL", "1234" ]);
        t.ok(state.elapsed() <= 6000, "termination remains bounded");
    });
});

t.test("a process that survives KILL prevents replacement, retains its pid and logs the refusal", () => {
    replacing({ unkillable: true }, (state) => {
        t.ok(!worker.stop({ ...state.old, command: slice(state.old.command, 0, 2) }));
        t.eq(fs.readfile(state.old.pid_file), "1234\n");
        t.contains(join("\n", state.logs), "did not stop");
        t.ok(state.elapsed() <= 6000);
    });
});

t.test("a reused pid belonging to another command is never signalled", () => {
    replacing({ unrelated: true }, (state) => {
        t.ok(sync.start_worker({ generation: state.next.data.generation, sections: [ {} ] }));
        t.eq(state.signals, []);
        t.eq(fs.readfile(state.next.pid_file), "5678\n");
    });
});

t.done();
