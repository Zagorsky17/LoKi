let t = require("t");
let fs = require("fs");
let stub = require("stub");
let repo = require("repo");
let exec = require("core.exec");
let uloop = require("uloop");
let common = require("core.common");
let quote = (value) => exec.command_line([ value ]);

t.test("the native RPC controls have their required BusyBox ash and file sync tools", () => {
    t.eq(exec.status([ "/bin/busybox", "ash", "-c", "exit 0" ]), 0,
        "BusyBox ash is required; install the declared backend CI prerequisite");
    t.ok(fs.stat("/usr/bin/sync")?.type == "file", "GNU sync is the Linux file-sync substitute for target BusyBox fsync");
});

function setup(argv, permission) {
    uloop.__reset();
    let rpc = stub.fresh("service.rpc");
    let directory = stub.tmpdir();
    fs.chmod(directory, 0700);
    rpc.paths.temporary = directory + "/journal";
    rpc.paths.fsync = [ "/usr/bin/sync" ];
    let fixtures = directory + "/fixtures";
    fs.mkdir(fixtures, 0700);
    let request = { args: { argv, ubus_rpc_session: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }, replied: null };
    request.defer = () => {};
    request.reply = (reply) => { request.replied = reply; };
    let prepared = rpc.prepare(request, permission);
    t.eq(prepared.success, true);
    request.args.request_id = prepared.id;
    rpc.invoke(request, permission);
    let child = uloop.__processes()[0];
    return { rpc, fixtures, request, child, permission, script: child.args[3], output: child.args[4] };
}

function response(run) {
    return run.rpc.result({ args: { id: run.request.replied.result_id, part: "status", offset: 0,
        ubus_rpc_session: run.request.args.ubus_rpc_session } }, run.permission).response;
}

function wait_file(path) {
    for (let i = 0; i < 60; i++) {
        if (fs.stat(path) != null)
            return true;
        sleep(50);
    }
    return false;
}

function wait_completion(run) {
    for (let i = 0; i < 60; i++) {
        if (index(fs.readfile(run.output + "/status") ?? "", run.request.replied.result_id + ":") == 0)
            return true;
        sleep(50);
    }
    return false;
}

t.test("an accepted lifecycle worker keeps writing own state after the RPC response and group cleanup", () => {
    let run = setup([ "service_action_async", "start" ], "rpc_write");
    let base = run.fixtures;
    let helper = base + "/owner-worker";
    fs.writefile(helper, '#!/bin/sh\ni=0; while [ ! -f ' + quote(base + "/continue") + ' ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done\n' +
        '[ -f ' + quote(base + "/continue") + ' ] || exit 1\n' +
        'for fd in /proc/$$/fd/*; do /bin/busybox readlink "$fd"; done > ' + quote(base + "/owner-fds") + '\n' +
        '/bin/busybox head -c 524288 /dev/zero > ' + quote(base + "/own-state") + '\n');
    fs.chmod(helper, 0755);
    let runner = base + "/accept.uc";
    fs.writefile(runner, 'let ui = require("service.ui"); let installer = require("service.installer");\n' +
        'require("core.constants").LOKI_BIN = ' + sprintf("%J", helper) + ';\n' +
        'ui.paths.service_actions = ' + sprintf("%J", base + "/actions") + ';\n' +
        'ui.paths.service_action_lock = ' + sprintf("%J", base + "/actions.lock") + ';\n' +
        'ui.paths.reload_lock = ' + sprintf("%J", base + "/reload.lock") + ';\n' +
        'installer.paths.state = ' + sprintf("%J", base + "/installer.json") + ';\n' +
        'print(sprintf("%J", ui.start_action("start")));\n');
    let pgid_file = base + "/rpc-pgid";
    let result = exec.combined([ "/usr/bin/setsid", "/bin/busybox", "ash", "-c",
        'echo "$$" > ' + quote(pgid_file) + '; ' + run.script, run.output,
        "ucode", "-L", repo.path("tests/fakes"), "-L", repo.path("tests/lib"), "-L", repo.path("loki/files/usr/lib"), runner ]);
    t.eq(result.status, 0, result.output);
    uloop.__exit(0, 0);
    t.eq(response(run).code, 0);
    t.eq(json(response(run).stdout).success, true);
    t.eq(fs.stat(base + "/own-state"), null, "the owner has not written before its caller received the response");
    let pgid = trim(fs.readfile(pgid_file));
    exec.status([ "/bin/kill", "-KILL", "--", "-" + pgid ]);
    fs.writefile(base + "/continue", "accepted");
    t.eq(wait_file(base + "/own-state"), true, "the accepted owner survives cleanup of its former caller");
    for (let i = 0; i < 60 && fs.stat(base + "/own-state").size < 524288; i++)
        sleep(50);
    t.eq(fs.stat(base + "/own-state").size, 524288);
    t.excludes(fs.readfile(base + "/owner-fds"), run.output, "a detached owner must not retain RPC spool or completion descriptors");
});

t.test("an RPC deadline removes unaccepted descendant producers in its owned process group", () => {
    let run = setup([ "check_dns" ], "rpc_read");
    let base = run.fixtures;
    let producer = base + "/producer.sh";
    fs.writefile(producer, '#!/bin/sh\n/bin/sh -c ' + quote('echo "$$" > ' + quote(base + "/producer.pid") +
        '; while :; do printf x >> ' + quote(base + "/ticks") + '; sleep 0.05; done') + ' &\nwait\n');
    let command = exec.command_line([ "/usr/bin/setsid", "/bin/busybox", "ash", "-c", run.script, run.output, "/bin/sh", producer ]);
    let pipe = fs.popen(command + " </dev/null >/dev/null 2>&1 & echo $!", "r");
    let pid = trim(pipe.read("all"));
    pipe.close();
    t.matches(pid, /^[0-9]+$/);
    run.child.pid = int(pid);
    let failure = null;
    try {
        t.eq(wait_file(base + "/ticks"), true);
        filter(uloop.__timers(), (timer) => !timer.cancelled && timer.ms == run.rpc.DIAGNOSTIC_MS)[0].callback();
        t.eq(response(run).code, 124);
        let size = fs.stat(base + "/ticks").size;
        sleep(200);
        t.eq(fs.stat(base + "/ticks").size, size, "the orphan producer cannot keep writing");
        let producer_pid = trim(fs.readfile(base + "/producer.pid"));
        let stat = fs.readfile("/proc/" + producer_pid + "/stat");
        t.ok(stat == null || match(stat, /\) [ZX] /) != null, "the producer is gone or awaiting reaping");
        t.eq(fs.stat(run.output + "/stdout"), null);
    }
    catch (e) { failure = e; }
    exec.status([ "/bin/kill", "-KILL", "--", "-" + pid ]);
    if (failure != null)
        die(failure.message);
});

t.test("a recovered starting job keeps its resource reservation while its real producer is still alive", () => {
    let clock = common.monotonic_ms;
    let now = clock();
    common.monotonic_ms = () => now;
    let run = setup([ "report", "masked", "{}" ], "rpc_read");
    let producer = run.fixtures + "/producer.sh";
    fs.writefile(producer, '#!/bin/sh\ni=0; while [ ! -f ' + quote(run.fixtures + "/finish") + ' ] && [ "$i" -lt 200 ]; do ' +
        'printf x >> ' + quote(run.fixtures + "/ticks") + '; printf x; sleep 0.05; i=$((i+1)); done\n');
    let command = exec.command_line([ "/usr/bin/setsid", "/bin/busybox", "ash", "-c", run.script, run.output, "/bin/sh", producer ]);
    let pipe = fs.popen(command + " </dev/null >/dev/null 2>&1 & echo $!", "r");
    let pid = trim(pipe.read("all"));
    pipe.close();
    let error = null;
    try {
        t.eq(wait_file(run.fixtures + "/ticks"), true);
        let record_path = run.output + "/record.json";
        let record = json(fs.readfile(record_path));
        fs.writefile(record_path, sprintf("%J", { ...record, phase: "starting" }));
        uloop.__reset();
        let replacement = stub.fresh("service.rpc");
        replacement.paths.temporary = run.rpc.paths.temporary;
        replacement.paths.fsync = run.rpc.paths.fsync;
        let args = { id: record.id, part: "status", offset: 0, ubus_rpc_session: record.session };
        t.eq(replacement.result({ args }, "rpc_read").response.code, 125);
        now += run.rpc.RESULT_TTL_MS + 1;
        for (let timer in filter(uloop.__timers(), (timer) => !timer.cancelled && timer.ms == run.rpc.RESULT_TTL_MS))
            timer.callback();
        let ticks = fs.stat(run.fixtures + "/ticks").size;
        sleep(150);
        t.ok(fs.stat(run.fixtures + "/ticks").size > ticks, "the old producer is still alive beyond result TTL");
        t.ok(now < record.deadline, "the original command budget has not elapsed");
        let next = replacement.prepare({ args: { argv: [ "report", "masked", "{}" ], ubus_rpc_session: record.session } }, "rpc_read");
        t.eq(next.success, false, "an unknown outcome must not release the live large-job reservation");
        t.eq(fs.stat(record_path)?.type, "file", "the active journal cannot be pruned by result TTL");
        t.eq(replacement.result({ args: { ...args, part: "release" } }, "rpc_read").success, false);
        fs.writefile(run.fixtures + "/finish", "finish");
        t.eq(wait_completion(run), true);
        t.eq(replacement.result({ args }, "rpc_read").response.code, 125);
        t.eq(replacement.result({ args: { ...args, part: "release" } }, "rpc_read").success, true);
        t.eq(replacement.prepare({ args: { argv: [ "report", "masked", "{}" ], ubus_rpc_session: record.session } }, "rpc_read").success, true);
    }
    catch (e) { error = e; }
    common.monotonic_ms = clock;
    if (index(fs.readfile("/proc/" + pid + "/cmdline") ?? "", run.output) >= 0)
        exec.status([ "/bin/kill", "-KILL", "--", "-" + pid ]);
    if (error != null)
        die(error.message);
});

t.test("exclusive native spool creation preserves raced victims and cannot trust stale numeric success", () => {
    for (let name in [ "stdout", "stderr", "status" ]) {
        let run = setup([ "show_version" ], "rpc_read");
        let victim = run.fixtures + "/victim";
        fs.writefile(victim, "synthetic foreign state");
        fs.symlink(victim, run.output + "/" + name);
        if (name != "status")
            fs.writefile(run.output + "/status", "0\n");
        let invoked = run.fixtures + "/payload-ran";
        let result = exec.combined([ "/usr/bin/setsid", "/bin/busybox", "ash", "-c", run.script, run.output,
            "/bin/sh", "-c", 'printf ran > "$1"; printf payload', "payload", invoked ]);
        t.ok(fs.readfile(victim) == "synthetic foreign state", "exclusive redirections must not clobber a raced victim");
        t.eq(fs.stat(invoked), null, "all exclusive opens precede payload execution");
        t.ok(result.status != 0);
        let pending = run.rpc.result({ args: { id: run.request.replied.result_id, part: "status", offset: 0,
            ubus_rpc_session: run.request.args.ubus_rpc_session } }, "rpc_read");
        t.eq(pending.pending, true, "a stale numeric status cannot finish the new live request");
        uloop.__exit(0, result.status);
        t.ok(response(run).code != 0, "failure to create a new completion marker is never success");
    }
});

t.test("an empty pre-open marker keeps live polls pending and private output descriptors stay out of helpers", () => {
    let run = setup([ "show_version" ], "rpc_read");
    let script = replace(run.script, ") & guard=$!; ", ") & guard=$!; printf '%s\\n' \"$guard\" > " + quote(run.fixtures + "/guard.pid") + "; ");
    script = replace(script, "& out=$!; ", "& out=$!; printf '%s\\n' \"$out\" > " + quote(run.fixtures + "/out.pid") + "; ");
    script = replace(script, "& err=$!; ", "& err=$!; printf '%s\\n' \"$err\" > " + quote(run.fixtures + "/err.pid") + "; ");
    let payload = 'for fd in 4 5 6; do [ ! -e "/proc/$$/fd/$fd" ] || exit 91; done; printf ready > "$1"; ' +
        'i=0; while [ ! -f "$2" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done; printf done';
    let command = exec.command_line([ "/usr/bin/setsid", "/bin/busybox", "ash", "-c", script, run.output,
        "/bin/sh", "-c", payload, "payload", run.fixtures + "/ready", run.fixtures + "/finish" ]);
    let pipe = fs.popen(command + " </dev/null >/dev/null 2>&1 & echo $!", "r");
    let pid = trim(pipe.read("all"));
    pipe.close();
    let error = null;
    try {
        t.eq(wait_file(run.fixtures + "/ready"), true, "payload received no private output/completion descriptors");
        t.eq(fs.stat(run.output + "/status").size, 0);
        let args = { id: run.request.replied.result_id, part: "status", offset: 0, ubus_rpc_session: run.request.args.ubus_rpc_session };
        t.eq(run.rpc.result({ args }, "rpc_read").pending, true);
        t.eq(run.rpc.result({ args: { ...args, part: "release" } }, "rpc_read").success, false);
        sleep(100);
        for (let helper in [ "guard", "out", "err" ]) {
            let child = trim(fs.readfile(run.fixtures + "/" + helper + ".pid"));
            t.ok(fs.stat("/proc/" + child) != null, "helper is alive while the payload is held");
            for (let fd in [ 4, 5, 6 ])
                t.eq(fs.lstat("/proc/" + child + "/fd/" + fd), null, "helper cannot retain unrelated private output descriptors");
        }
        fs.writefile(run.fixtures + "/finish", "finish");
        t.eq(wait_completion(run), true);
        uloop.__exit(0, 0);
        t.eq(response(run), { code: 0, stdout: "done", stderr: "" });
    }
    catch (e) { error = e; }
    if (index(fs.readfile("/proc/" + pid + "/cmdline") ?? "", run.output) >= 0)
        exec.status([ "/bin/kill", "-KILL", "--", "-" + pid ]);
    if (error != null)
        die(error.message);
});

t.test("fixed Monitoring and dashboard snapshots above128KiB cross real HTTP and collector boundaries intact", () => {
    let controller = require("controller").start();
    let connections = [];
    let proxies = {};
    for (let i = 0; i < 1000; i++) {
        let entry = { id: "connection-" + i, metadata: { host: sprintf("%200s", "example.invalid") }, download: i };
        push(connections, entry);
        proxies["node-" + i] = entry;
    }
    for (let endpoint in [ "/connections", "/proxies", "/providers/proxies" ]) {
        let body = sprintf("%J", endpoint == "/connections" ? { connections } :
            endpoint == "/proxies" ? { proxies } : { providers: { fixture: { proxies: connections } } });
        controller.reply({ status: 200, body });
        let run = setup([ "clash_api", "GET", endpoint, "" ], "rpc_read");
        let config = run.fixtures + "/runtime.json";
        fs.writefile(config, sprintf("%J", { experimental: { clash_api: {
            external_controller: controller.endpoint, secret: "synthetic-controller-key" } } }));
        let driver = run.fixtures + "/snapshot.uc";
        fs.writefile(driver, 'require("fixture").seed({ settings: { config_path: ' + sprintf("%J", config) + ' } });\n' +
            'require("ubus").__on("session.access", { access: true });\n' +
            'exit(require("service.rpc").run(' + sprintf("%J", run.request.args.argv) + ', ' +
            sprintf("%J", repo.path("loki/files/usr/lib")) + ', "rpc_read"));\n');
        let captured = exec.combined([ "/usr/bin/setsid", "/bin/busybox", "ash", "-c", run.script, run.output,
            "/usr/bin/env", "LOKI_RPC_SESSION=" + run.request.args.ubus_rpc_session, "ucode", "-L", repo.path("tests/fakes"),
            "-L", repo.path("tests/lib"), "-L", repo.path("loki/files/usr/lib"), driver ]);
        uloop.__exit(0, captured.status);
        let terminal = response(run);
        t.eq(terminal.code, 0, "a valid full snapshot must not be reduced to an inline-size failure");
        t.eq(terminal.result_id, run.request.replied.result_id);
        let args = { id: terminal.result_id, part: "stdout", offset: 0, ubus_rpc_session: run.request.args.ubus_rpc_session };
        let restored = "";
        while (true) {
            let chunk = run.rpc.result({ args }, "rpc_read");
            t.eq(chunk.success, true);
            restored += b64dec(chunk.data);
            args.offset = chunk.next;
            if (chunk.eof)
                break;
        }
        t.ok(length(restored) > run.rpc.MAX_OUTPUT_BYTES);
        t.eq(json(restored), { status: 200, body });
        t.excludes(restored, "synthetic-controller-key");
        let busy = run.rpc.prepare({ args: { argv: run.request.args.argv,
            ubus_rpc_session: run.request.args.ubus_rpc_session } }, "rpc_read");
        t.eq(busy.success, false, "a held large snapshot returns explicit busy rather than an empty success");
        t.ok(length(busy.message) > 0);
        t.eq(run.rpc.result({ args: { ...args, part: "release", offset: 0 } }, "rpc_read").success, true);
    }
});

t.done();
