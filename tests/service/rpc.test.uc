let t = require("t");
let fs = require("fs");
let stub = require("stub");
let uloop = require("uloop");
let ubus = require("ubus");
let cli = require("service.cli");
let exec = require("core.exec");
let common = require("core.common");
const SID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const OTHER = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
let clients = [];

function fresh() {
    uloop.__reset();
    ubus.__reset();
    clients = [];
    let rpc = stub.fresh("service.rpc");
    let parent = stub.tmpdir();
    fs.chmod(parent, 0700);
    rpc.paths.temporary = parent + "/journal";
    fs.mkdir(rpc.paths.temporary, 0700);
    rpc.paths.fsync = [ "/usr/bin/sync" ];
    return rpc;
}

function request(argv, extra) {
    let value = { args: { argv, ubus_rpc_session: SID, ...(extra ?? {}) }, deferred: false, replied: null, replies: 0 };
    value.defer = () => { value.deferred = true; };
    value.reply = (reply) => { value.initial = reply; value.replied = reply; value.replies++; };
    return value;
}

function job_path(index) {
    return uloop.__processes()[index ?? 0].args[4];
}

function settled(index) {
    let client = clients[index];
    if (client == null || client.request.initial?.result_id == null)
        return;
    let args = { id: client.request.initial.result_id, part: "status", offset: 0, ubus_rpc_session: client.request.args.ubus_rpc_session };
    let status = client.rpc.result({ args }, client.permission);
    if (status.success && !status.pending) {
        client.request.replied = status.response;
        if (status.response.result_id == null)
            client.rpc.result({ args: { ...args, part: "release" } }, client.permission);
    }
}

function start(rpc, value, permission) {
    if (value.args.request_id == null) {
        let prepared = rpc.prepare({ args: value.args }, permission);
        if (!prepared.success)
            return { code: prepared.code ?? 1, stdout: "", stderr: prepared.message };
        value.args.request_id = prepared.id;
    }
    let index = length(uloop.__processes());
    let result = rpc.invoke(value, permission);
    if (value.initial?.result_id != null) {
        clients[index] = { rpc, request: value, permission };
        settled(index);
    }
    return result;
}

function exit_child(index, code) {
    uloop.__exit(index, code);
    settled(index);
}

function completion(path, status) {
    let id = substr(path, rindex(path, "/") + 1);
    fs.writefile(path + "/status", id + ":" + (status ?? "0") + "\n");
    fs.chmod(path + "/status", 0600);
}

function complete(index, stdout, stderr, status) {
    let path = job_path(index);
    fs.writefile(path + "/stdout", stdout ?? "{}");
    fs.writefile(path + "/stderr", stderr ?? "");
    completion(path, status);
    exit_child(index, 0);
}

function body_bytes(size) {
    let value = "x";
    while (length(value) < size)
        value += value;
    return substr(value, 0, size);
}

t.test("unknown fields, executable/env injection, malformed SID and input limits fail before a child starts", () => {
    let rpc = fresh();
    for (let extra in [ { env: { LD_PRELOAD: "/tmp/payload" } }, { executable: "/bin/sh" }, { cwd: "/tmp" },
        { timeout: 0 }, { ubus_rpc_session: "00000000000000000000000000000000" }, { ubus_rpc_session: OTHER + "x" },
        { ubus_rpc_session: "root" }, { ubus_rpc_session: null }, { permission: "rpc_write" } ])
        t.ok(start(rpc, request([ "show_version" ], extra), "rpc_read").code != 0, sprintf("%J", extra));
    for (let args in [ [], null, {}, [ 1 ], [ "show_version", "extra" ], [ "show_version" + chr(0) ],
        [ "report", "masked", "\n" ], [ "rpc_dispatch", "rpc_write", "enable" ], [ "installer_run", "id" ],
        [ "report", "masked", body_bytes(rpc.MAX_ARGUMENT_BYTES) ] ])
        t.ok(start(rpc, request(args), "rpc_read").code != 0, "malformed args");
    t.eq(uloop.__processes(), []);
});

t.test("a trusted worker gets fixed argv and a clean environment, with private output even under umask zero", () => {
    let rpc = fresh();
    stub.env({ LD_PRELOAD: "/tmp/untrusted", PATH: "/tmp/attacker", LOKI_LIB: "/tmp/attacker" });
    let value = request([ "report", "masked", '{"message":"$(touch should-not-run); quoted"}' ]);
    t.eq(start(rpc, value, "rpc_read"), null);
    stub.restore();
    let child = uloop.__processes()[0];
    t.eq(value.deferred, true);
    t.eq(child.executable, "/usr/bin/setsid");
    t.eq(child.env.LD_PRELOAD, null);
    t.eq(child.env.PATH, "/usr/sbin:/usr/bin:/sbin:/bin");
    t.eq(child.env.LOKI_RPC_SESSION, SID);
    t.eq(child.env.LOKI_RPC_ACCESS, null);
    t.eq(child.env.LOKI_LIB, require("core.library").dir());
    t.eq(slice(child.args, 5), [ "/usr/bin/loki", "rpc_dispatch", "rpc_read", ...value.args.argv ]);
    t.eq(fs.stat(job_path()).mode & 0777, 0700);
    complete(0, "masked output", "", "0");
    t.eq(value.replied, { code: 0, stdout: "masked output", stderr: "" });
    t.eq(fs.stat(job_path()), null);
});

t.test("signal-style exit zero without a completion marker is a failure and cannot replay a response", () => {
    let rpc = fresh();
    let value = request([ "show_version" ]);
    start(rpc, value, "rpc_read");
    fs.writefile(job_path() + "/stdout", "partial");
    exit_child(0, 0);
    t.eq(value.replied.code, 1);
    t.eq(value.replied.stdout, "");
    t.eq(fs.stat(job_path()), null);
    exit_child(0, 0);
    t.eq(value.replies, 1);
});

t.test("output over the byte cap and invalid completion data fail without a partial response", () => {
    for (let kind in [ "large", "combined", "invalid", "signal" ]) {
        let rpc = fresh();
        let value = request([ "show_version" ]);
        start(rpc, value, "rpc_read");
        if (kind == "large")
            complete(0, body_bytes(rpc.MAX_OUTPUT_BYTES + 1));
        else if (kind == "combined")
            complete(0, body_bytes(rpc.MAX_OUTPUT_BYTES), "y");
        else
            complete(0, "partial", "", kind == "invalid" ? "0\n1" : "137");
        t.ok(value.replied.code != 0, kind);
        if (kind != "signal")
            t.eq(value.replied.stdout, "", kind);
        t.eq(fs.stat(job_path()), null);
    }
});

t.test("deadlines kill only the owned process group, release its slot and ignore a later completion", () => {
    let rpc = fresh();
    let value = request([ "check_dns" ]);
    start(rpc, value, "rpc_read");
    let child = uloop.__processes()[0];
    let timer = filter(uloop.__timers(), (entry) => !entry.cancelled && entry.ms == rpc.DIAGNOSTIC_MS)[0];
    t.eq(timer.ms, rpc.DIAGNOSTIC_MS);
    stub.commands([ [ "/bin/kill -KILL -- -" + child.pid, { status: 0 } ], [ "/usr/bin/sync", { status: 0 } ] ]);
    timer.callback();
    settled(0);
    stub.restore();
    t.eq(value.replied.code, 124);
    t.eq(fs.stat(job_path()), null);
    exit_child(0, 0);
    t.eq(value.replies, 1);
    t.eq(start(rpc, request([ "show_version" ]), "rpc_read"), null);
    complete(1);
});

t.test("bounded concurrent reads leave a writer slot and cleanup admits a later request", () => {
    let rpc = fresh();
    for (let i = 0; i < rpc.MAX_READ_JOBS; i++)
        t.eq(start(rpc, request([ "show_version" ]), "rpc_read"), null);
    t.eq(start(rpc, request([ "show_version" ], { ubus_rpc_session: OTHER }), "rpc_read").code, 16);
    t.eq(start(rpc, request([ "enable" ], { ubus_rpc_session: OTHER }), "rpc_write"), null);
    t.eq(start(rpc, request([ "disable" ], { ubus_rpc_session: OTHER }), "rpc_write").code, 16);
    complete(0);
    t.eq(start(rpc, request([ "show_version" ]), "rpc_read"), null);
    for (let i = 1; i < rpc.MAX_JOBS + 1; i++)
        complete(i);
});

t.test("a failed spawn releases private state, and shutdown stops owned children once", () => {
    let rpc = fresh();
    let real = uloop.process;
    uloop.process = () => null;
    let failed = request([ "show_version" ]);
    start(rpc, failed, "rpc_read");
    uloop.process = real;
    t.eq(failed.replied.code, 1);
    t.eq(fs.lsdir(rpc.paths.temporary), [ "format" ]);
    let active = request([ "show_version" ]);
    start(rpc, active, "rpc_read");
    stub.commands([ [ "/bin/kill", { status: 0 } ], [ "/usr/bin/sync", { status: 0 } ] ]);
    rpc.shutdown();
    settled(0);
    t.eq(length(filter(stub.calls(), (call) => call.argv[0] == "/bin/kill")), 1);
    rpc.shutdown();
    t.eq(length(filter(stub.calls(), (call) => call.argv[0] == "/bin/kill")), 1);
    stub.restore();
    t.eq(active.replied.code, 124);
});

t.test("the child validates the current session and exact ACL method before dispatch", () => {
    let rpc = fresh();
    let real = cli.dispatch;
    let dispatched = [];
    cli.dispatch = (argv, lib) => { push(dispatched, { argv, lib }); return 0; };
    stub.env({ LOKI_RPC_SESSION: SID });
    let granted = true;
    ubus.__on("session.access", (args) => ({ access: granted && args.function == "rpc_read" }));
    t.eq(rpc.run([ "show_version" ], "/trusted", "rpc_read"), 0);
    t.eq(ubus.__calls()[0], { object: "session", method: "access", args: {
        ubus_rpc_session: SID, scope: "ubus", object: "loki", function: "rpc_read"
    } });
    granted = false;
    t.eq(stub.capture(() => rpc.run([ "show_version" ], "/trusted", "rpc_read")).result, 1);
    t.eq(stub.capture(() => rpc.run([ "enable" ], "/trusted", "rpc_write")).result, 1);
    t.eq(stub.capture(() => rpc.run([ "enable" ], "/trusted", "rpc_read")).result, 1);
    ubus.__refuse_connections();
    t.eq(stub.capture(() => rpc.run([ "show_version" ], "/trusted", "rpc_read")).result, 1);
    stub.restore();
    cli.dispatch = real;
    t.eq(dispatched, [ { argv: [ "show_version" ], lib: "/trusted" } ]);
});

t.test("the viewer snapshot preserves topology without unknown fields, URI credentials or JSON payloads", () => {
    let rpc = fresh();
    let source = [
        { ".type": "settings", ".name": "settings", yacd_secret_key: "synthetic-key", custom_unknown: "synthetic-token" },
        { ".type": "section", ".name": "main", label: "Main", action: "connection", enabled: "1",
            outbound_jsons: [ '{"password":"synthetic-password"}' ] },
        { ".type": "subscription_url", ".name": "sub", section: "main", tag: "Provider", url: "https://secret.invalid/token", headers: [ "Authorization: synthetic" ] },
        { ".type": "connection_link", ".name": "link", section: "main", name: "Node", uri: "socks://user:secret@proxy.invalid:1080" }
    ];
    let copy = sprintf("%J", source);
    let snapshot = rpc.public_sections(source);
    t.eq(snapshot[1], { ".type": "section", ".name": "main", label: "Main", action: "connection", enabled: "1", outbound_jsons: [ "{}" ] });
    t.eq(snapshot[2].url, "configured");
    t.eq(snapshot[3].name, "Node");
    for (let secret in [ "synthetic", "secret.invalid", "proxy.invalid", "socks://", "custom_unknown" ])
        t.excludes(sprintf("%J", snapshot), secret);
    t.eq(sprintf("%J", source), copy);
});

t.test("the real output collector bounds bytes without imposing a file-size limit on own state", () => {
    let rpc = fresh();
    let value = request([ "show_version" ]);
    start(rpc, value, "rpc_read");
    let path = job_path();
    let script = uloop.__processes()[0].args[3];
    let state = path + "/own-state";
    let run = exec.combined([ "/bin/busybox", "ash", "-c", script, path, "/bin/sh", "-c",
        '/bin/busybox head -c 524288 /dev/zero > "$1"; printf done', "worker", state ]);
    t.eq(run.status, 0, run.output);
    t.eq(fs.stat(state).size, 524288);
    t.eq(fs.readfile(path + "/stdout"), "done");
    for (let name in [ "stdout", "stderr", "stdout.pipe", "stderr.pipe" ])
        t.eq(fs.lstat(path + "/" + name).mode & 0777, 0600);
    fs.unlink(state);
    exit_child(0, 0);
    t.eq(value.replied, { code: 0, stdout: "done", stderr: "" });

    let flooded = request([ "show_version" ]);
    start(rpc, flooded, "rpc_read");
    path = job_path(1);
    run = exec.combined([ "/bin/busybox", "ash", "-c", script, path, "/bin/busybox", "head", "-c", "1048576", "/dev/zero" ]);
    t.ok(fs.stat(path + "/stdout").size <= rpc.MAX_OUTPUT_BYTES + 1);
    exit_child(1, 0);
    t.eq(flooded.replied.code, 1);
    t.eq(flooded.replied.stdout, "");
    t.eq(fs.stat(path), null);
});

t.test("collector-only write failure cannot return a successful partial report from a successful payload", () => {
    for (let part in [ "stdout", "stderr" ]) {
        let rpc = fresh();
        let value = request([ "show_version" ]);
        start(rpc, value, "rpc_read");
        let path = job_path();
        let script = uloop.__processes()[0].args[3];
        let collector = '/bin/busybox head -c ' + (rpc.MAX_OUTPUT_BYTES + 1) + ' < "$0/' + part + '.pipe" >&' + (part == "stdout" ? "4" : "5") + ' 4>&- 5>&- 6>&-';
        t.contains(script, collector);
        script = replace(script, collector, '( ulimit -f 1; exec ' + collector + ' )');
        let state = common.parent_dir(rpc.paths.temporary) + "/own-state";
        let payload_exit = state + ".exit";
        let run = exec.combined([ "/bin/busybox", "ash", "-c", script, path, "/bin/sh", "-c",
            '/bin/busybox head -c 4096 /dev/zero' + (part == "stderr" ? " >&2" : "") +
            '; /bin/busybox head -c 524288 /dev/zero > "$1"; printf 0 > "$2"; exit 0', "payload", state, payload_exit ]);
        t.eq(fs.readfile(payload_exit), "0", "the payload itself exited successfully");
        t.eq(fs.stat(state).size, 524288, "the collector limit must never be inherited by payload/owner state writes");
        let captured = fs.lstat(path + "/" + part);
        t.eq(captured.type, "file");
        t.ok(captured.size > 0 && captured.size < 4096, "a regular partial output file is not complete output");
        t.eq(split(trim(fs.readfile(path + "/status")), ":")[1], "125", "collector failure must override payload success");
        t.ok(run.status != 0);
        exit_child(0, 0);
        t.ok(value.replied.code != 0);
    }
});

t.test("healthy collectors preserve a nonzero payload exit and its partial diagnostic output", () => {
    let rpc = fresh();
    let value = request([ "show_version" ]);
    start(rpc, value, "rpc_read");
    let path = job_path();
    let script = uloop.__processes()[0].args[3];
    let run = exec.combined([ "/bin/busybox", "ash", "-c", script, path, "/bin/sh", "-c",
        "printf partial; printf detail >&2; exit 17" ]);
    t.eq(run.status, 17);
    exit_child(0, 0);
    t.eq(value.replied, { code: 17, stdout: "partial", stderr: "detail" });
});

t.test("large masked reports are read in bounded repeatable chunks owned by one session and permission", () => {
    let rpc = fresh();
    let value = request([ "report", "masked", "{}" ]);
    start(rpc, value, "rpc_read");
    let content = body_bytes(rpc.CHUNK_BYTES - 1) + "Привет 🦊" + body_bytes(262144);
    complete(0, content, "detail", "0");
    t.eq(value.replied.code, 0);
    t.eq(value.replied.stdout, "");
    let id = value.replied.result_id;
    t.eq(type(id), "string");
    let part = (offset, extra, permission) => rpc.result({ args: {
        id, part: "stdout", offset, ubus_rpc_session: SID, ...(extra ?? {})
    } }, permission ?? "rpc_read");
    let first = part(0);
    t.eq(part(0), first, "reading the same offset is idempotent");
    t.eq(part(0, { ubus_rpc_session: OTHER }).success, false);
    t.eq(part(0, null, "rpc_write").success, false);
    for (let invalid in [ { env: {} }, { part: "../status" }, { offset: -1 }, { offset: "0" }, { offset: length(content) + 1 } ])
        t.eq(part(0, invalid).success, false);
    let restored = "";
    for (let offset = 0; ; ) {
        let chunk = part(offset);
        t.eq(chunk.success, true);
        let bytes = b64dec(chunk.data);
        t.ok(length(bytes) <= rpc.CHUNK_BYTES);
        restored += bytes;
        offset = chunk.next;
        if (chunk.eof)
            break;
    }
    t.eq(restored, content);
    t.eq(start(rpc, request([ "report", "masked", "{}" ]), "rpc_read").code, 16);
    t.eq(start(rpc, request([ "show_version" ]), "rpc_read"), null);
    complete(1);
    t.eq(part(0, { part: "release" }).success, true);
    t.eq(part(0).success, false);
    t.eq(fs.stat(job_path()), null);
});

t.test("escaped inline output switches to chunks before its actual JSON response exceeds the RPC budget", () => {
    let content = chr(0) + '"' + "\\";
    while (length(content) < 98304)
        content += content;
    for (let stream in [ "stdout", "stderr" ]) {
        let rpc = fresh();
        let value = request([ "show_version" ]);
        start(rpc, value, "rpc_read");
        complete(0, stream == "stdout" ? content : "", stream == "stderr" ? content : "", "17");
        t.ok(length(content) <= rpc.MAX_OUTPUT_BYTES);
        t.ok(length(sprintf("%J", value.replied)) <= rpc.MAX_OUTPUT_BYTES,
            "the actual terminal response must fit the inline transport budget after JSON escaping");
        t.eq(value.replied.code, 17);
        t.eq(type(value.replied.result_id), "string", "escaped output must retain all bytes through existing chunks");
        let restored = "";
        for (let offset = 0; ; ) {
            let part = rpc.result({ args: { id: value.replied.result_id, part: stream, offset, ubus_rpc_session: SID } }, "rpc_read");
            t.eq(part.success, true);
            restored += b64dec(part.data);
            offset = part.next;
            if (part.eof)
                break;
        }
        t.ok(restored == content, "chunk decoding must preserve NUL, quotes and backslashes without truncation");
        t.eq(rpc.result({ args: { id: value.replied.result_id, part: "release", offset: 0, ubus_rpc_session: SID } }, "rpc_read").success, true);
    }
});

t.test("abandoned large results expire, release their quota and never return partial oversized reports", () => {
    let rpc = fresh();
    let value = request([ "report", "masked", "{}" ]);
    start(rpc, value, "rpc_read");
    complete(0, body_bytes(rpc.MAX_OUTPUT_BYTES + 1));
    let expiry = filter(uloop.__timers(), (timer) => timer.ms == rpc.RESULT_TTL_MS && !timer.cancelled)[0];
    expiry.callback();
    t.eq(fs.stat(job_path()), null);
    let next = request([ "report", "masked", "{}" ]);
    t.eq(start(rpc, next, "rpc_read"), null);
    complete(1, body_bytes(rpc.MAX_LARGE_OUTPUT_BYTES + 1));
    t.eq(next.replied.code, 1);
    t.eq(next.replied.stdout, "");
    t.eq(next.replied.result_id, null);
    t.eq(fs.stat(job_path(1)), null);
});

t.test("oversized fixed Monitoring snapshots fail explicitly instead of returning a partial connection list", () => {
    let rpc = fresh();
    let value = request([ "clash_api", "GET", "/connections", "" ]);
    start(rpc, value, "rpc_read");
    complete(0, body_bytes(rpc.MAX_LARGE_OUTPUT_BYTES + 1));
    t.ok(value.replied.code != 0);
    t.eq(value.replied.stdout, "");
    t.eq(value.replied.result_id, null);
});

t.test("prepare is inert and a lost first reply or duplicate start cannot submit a write twice", () => {
    let rpc = fresh();
    let args = { argv: [ "enable" ], ubus_rpc_session: SID };
    let prepared = rpc.prepare({ args }, "rpc_write");
    t.eq(prepared.success, true);
    t.eq(length(prepared.id), 64);
    t.eq(uloop.__processes(), []);
    let value = request(args.argv, { request_id: prepared.id });
    value.reply = () => die("the browser connection is gone");
    t.eq(rpc.invoke(value, "rpc_write"), null);
    t.eq(length(uloop.__processes()), 1);
    let replay = request(args.argv, { request_id: prepared.id });
    t.eq(rpc.invoke(replay, "rpc_write"), null);
    t.eq(replay.initial, { pending: true, result_id: prepared.id });
    t.eq(length(uloop.__processes()), 1);
    t.eq(rpc.invoke(request([ "disable" ], { request_id: prepared.id }), "rpc_write").code, 125);
    t.eq(rpc.invoke(request(args.argv, { request_id: prepared.id, ubus_rpc_session: OTHER }), "rpc_write").code, 125);
    let path = job_path();
    let metadata = json(fs.readfile(path + "/record.json"));
    t.eq(metadata.phase, "running");
    t.eq(metadata.argv, null);
    t.eq(fs.stat(path + "/record.json").mode & 0777, 0600);
    fs.writefile(path + "/stdout", "done");
    fs.writefile(path + "/stderr", "");
    completion(path, "0");
    uloop.__exit(0, 0);
    let read = { id: prepared.id, part: "status", offset: 0, ubus_rpc_session: SID };
    t.eq(rpc.result({ args: read }, "rpc_write").response, { code: 0, stdout: "done", stderr: "" });
    rpc.result({ args: { ...read, part: "release" } }, "rpc_write");
    t.eq(rpc.invoke(request(args.argv, { request_id: prepared.id }), "rpc_write").code, 125);
    t.eq(length(uloop.__processes()), 1);
});

t.test("a restarted broker recovers the private journal without spawning an accepted request again", () => {
    let rpc = fresh();
    let value = request([ "enable" ]);
    start(rpc, value, "rpc_write");
    let path = job_path();
    let replacement = stub.fresh("service.rpc");
    replacement.paths.temporary = rpc.paths.temporary;
    replacement.paths.fsync = rpc.paths.fsync;
    let replay = request(value.args.argv, { request_id: value.args.request_id });
    t.eq(replacement.invoke(replay, "rpc_write"), null);
    t.eq(length(uloop.__processes()), 1);
    let args = { id: value.args.request_id, part: "status", offset: 0, ubus_rpc_session: SID };
    t.eq(replacement.result({ args }, "rpc_write").pending, true);
    fs.writefile(path + "/stdout", "recovered");
    fs.writefile(path + "/stderr", "");
    completion(path, "0");
    t.eq(replacement.result({ args }, "rpc_write").response.stdout, "recovered");
    t.eq(length(uloop.__processes()), 1);
    replacement.result({ args: { ...args, part: "release" } }, "rpc_write");
});

function recovered_resource_case(phase) {
    let rpc = fresh();
    let clock = common.monotonic_ms;
    let now = clock();
    common.monotonic_ms = () => now;
    let error = null;
    try {
        let value = request([ "report", "masked", "{}" ]);
        start(rpc, value, "rpc_read");
        let path = job_path();
        let record = json(fs.readfile(path + "/record.json"));
        fs.writefile(path + "/record.json", sprintf("%J", { ...record, phase }));
        uloop.__reset();
        let replacement = stub.fresh("service.rpc");
        replacement.paths.temporary = rpc.paths.temporary;
        replacement.paths.fsync = rpc.paths.fsync;
        let args = { id: record.id, part: "status", offset: 0, ubus_rpc_session: SID };
        replacement.result({ args }, "rpc_read");
        now = record.deadline + 1;
        for (let timer in filter(uloop.__timers(), (timer) => !timer.cancelled))
            timer.callback();
        t.eq(replacement.result({ args }, "rpc_read").response.code, 125, phase);
        t.eq(replacement.result({ args: { ...args, part: "release" } }, "rpc_read").success, false, phase);
        stub.commands([]);
        replacement.shutdown();
        let calls = stub.calls();
        stub.restore();
        t.eq(calls, [], "shutdown must not signal an unverified recovered PID");
        t.eq(fs.stat(path + "/record.json")?.type, "file");
        let second = stub.fresh("service.rpc");
        second.paths.temporary = rpc.paths.temporary;
        second.paths.fsync = rpc.paths.fsync;
        let next = () => second.prepare({ args: { argv: value.args.argv, ubus_rpc_session: OTHER } }, "rpc_read");
        t.eq(next().success, false, "a new session cannot reuse a quarantined large slot");
        for (let marker in [ "invalid", "00000", "256", "", "0" + chr(0), "0" + chr(0) + "x" ]) {
            fs.writefile(path + "/status", record.id + ":" + marker);
            t.eq(next().success, false, "invalid marker shape, size or code is not completion proof");
            t.eq(second.result({ args: { ...args, part: "release" } }, "rpc_read").success, false,
                "invalid markers must retain the live lease rather than create an expiring result");
        }
        fs.unlink(path + "/status");
        fs.mkdir(path + "/status", 0700);
        t.eq(next().success, false, "a non-file marker cannot release the producer reservation");
        t.eq(second.result({ args: { ...args, part: "release" } }, "rpc_read").success, false);
        fs.rmdir(path + "/status");
        for (let stale in [ "0\n", OTHER + OTHER + ":0\n" ]) {
            fs.writefile(path + "/status", stale);
            t.eq(next().success, false);
            t.eq(second.result({ args: { ...args, part: "release" } }, "rpc_read").success, false,
                "a numeric or differently bound marker cannot prove completion of this job");
        }
        fs.writefile(path + "/stdout", "recovered");
        fs.writefile(path + "/stderr", "");
        completion(path, "0");
        t.eq(next().success, false, "lazy reap retains the completed result until release or TTL");
        let terminal = second.result({ args }, "rpc_read");
        t.eq(terminal.pending, false);
        t.ok(terminal.response.code != 0, "completion proof does not turn an unknown or overdue outcome into success");
        t.eq(second.result({ args: { ...args, part: "release" } }, "rpc_read").success, true);
        t.eq(next().success, true, "valid completion proof finally permits quota reuse");
    }
    catch (e) { error = e; }
    stub.restore();
    common.monotonic_ms = clock;
    if (error != null)
        die(error.message);
}

t.test("recovered starting keeps quota through deadline, shutdown and restart until valid completion proof", () => {
    recovered_resource_case("starting");
});

t.test("recovered running keeps quota through deadline, shutdown and restart until valid completion proof", () => {
    recovered_resource_case("running");
});

t.test("expired, pruned and old-boot tokens are rejected rather than treated as fresh writes", () => {
    let rpc = fresh();
    let prepared = rpc.prepare({ args: { argv: [ "enable" ], ubus_rpc_session: SID } }, "rpc_write");
    let expired = request([ "enable" ], { request_id: prepared.id });
    filter(uloop.__timers(), (timer) => !timer.cancelled && timer.ms == rpc.PREPARE_TTL_MS)[0].callback();
    t.eq(rpc.invoke(expired, "rpc_write").code, 125);
    t.eq(uloop.__processes(), []);
    let replacement = stub.fresh("service.rpc");
    replacement.paths.temporary = rpc.paths.temporary;
    replacement.paths.fsync = rpc.paths.fsync;
    t.eq(replacement.invoke(expired, "rpc_write").code, 125);
    let next = replacement.prepare({ args: { argv: [ "enable" ], ubus_rpc_session: SID } }, "rpc_write");
    let epoch_file = stub.tmpdir() + "/boot-id";
    fs.writefile(epoch_file, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\n");
    let rebooted = stub.fresh("service.rpc");
    rebooted.paths.temporary = rpc.paths.temporary;
    rebooted.paths.fsync = rpc.paths.fsync;
    rebooted.paths.epoch = epoch_file;
    t.eq(rebooted.invoke(request([ "enable" ], { request_id: next.id }), "rpc_write").code, 125);
    t.eq(uloop.__processes(), []);
    t.eq(rebooted.prepare({ args: { argv: [ "enable" ], request_id: next.id, ubus_rpc_session: SID } }, "rpc_write").success, false);
});

t.test("journal write, rename and synchronization failures prevent payload spawn", () => {
    for (let mode in [ "sync", "rename", "write" ]) {
        let rpc = fresh();
        let prepared = rpc.prepare({ args: { argv: [ "enable" ], ubus_rpc_session: SID } }, "rpc_write");
        let real = fs.rename;
        let open = fs.open;
        if (mode == "sync")
            rpc.paths.fsync = [ "/bin/false" ];
        else if (mode == "rename")
            fs.rename = () => false;
        else
            fs.open = (path, mode, permissions) => match(path, /\/record\.new$/) ? null : open(path, mode, permissions);
        let result = rpc.invoke(request([ "enable" ], { request_id: prepared.id }), "rpc_write");
        fs.rename = real;
        fs.open = open;
        t.ok(result.code != 0, mode);
        t.eq(uloop.__processes(), [], mode);
        let meta = json(fs.readfile(rpc.paths.temporary + "/" + prepared.id + "/record.json"));
        t.eq(meta.phase, "prepared", mode);
    }
    let unsafe = fresh();
    fs.chmod(unsafe.paths.temporary, 0777);
    t.eq(unsafe.prepare({ args: { argv: [ "enable" ], ubus_rpc_session: SID } }, "rpc_write").success, false);
    t.eq(fs.stat(unsafe.paths.temporary).mode & 0777, 0777);
    t.eq(uloop.__processes(), []);
});

t.test("an existing journal under an unsafe parent is refused without repairing or spawning", () => {
    let rpc = fresh();
    let parent = common.parent_dir(rpc.paths.temporary);
    fs.chmod(parent, 0777);
    let prepared = rpc.prepare({ args: { argv: [ "enable" ], ubus_rpc_session: SID } }, "rpc_write");
    t.eq(prepared.success, false);
    t.eq(fs.stat(parent).mode & 0777, 0777);
    t.eq(fs.lsdir(rpc.paths.temporary), []);
    t.eq(uloop.__processes(), []);
});

function directory_read_failure_case(link) {
    let rpc = fresh();
    let marker = rpc.paths.temporary + "/format";
    let victim = common.parent_dir(rpc.paths.temporary) + "/victim";
    fs.writefile(victim, "synthetic foreign state");
    if (link)
        fs.symlink(victim, marker);
    else
        fs.writefile(marker, "unrecognized marker");
    let other = rpc.paths.temporary + "/.input.123.456";
    fs.writefile(other, "must remain");
    let original = fs.lsdir;
    fs.lsdir = (path) => path == rpc.paths.temporary ? null : original(path);
    let result = null;
    let error = null;
    try { result = rpc.prepare({ args: { argv: [ "enable" ], ubus_rpc_session: SID } }, "rpc_write"); }
    catch (e) { error = e; }
    fs.lsdir = original;
    if (error != null)
        die(error.message);
    t.eq(result.success, false);
    t.ok(fs.readfile(victim) == "synthetic foreign state", "the synthetic victim must not be modified");
    t.eq(fs.readfile(marker), link ? "synthetic foreign state" : "unrecognized marker");
    t.eq(fs.lstat(marker).type, link ? "link" : "file");
    t.eq(fs.readfile(other), "must remain");
    t.eq(uloop.__processes(), []);
}

t.test("journal directory read failure leaves an existing marker and other entries unchanged", () => {
    directory_read_failure_case(false);
});

t.test("journal directory read failure cannot overwrite a marker symlink target", () => {
    directory_read_failure_case(true);
});

function journal_temporary_case(kind) {
    let rpc = fresh();
    let prepared = rpc.prepare({ args: { argv: [ "enable" ], ubus_rpc_session: SID } }, "rpc_write");
    let temporary = rpc.paths.temporary + "/" + prepared.id + "/record.new";
    let victim = common.parent_dir(rpc.paths.temporary) + "/victim";
    fs.writefile(victim, "synthetic foreign state");
    fs.chmod(victim, 0600);
    if (kind == "symlink")
        fs.symlink(victim, temporary);
    else if (kind == "hardlink")
        t.eq(exec.status([ "/bin/ln", victim, temporary ]), 0);
    else if (kind != "race") {
        fs.writefile(temporary, "preexisting regular entry");
        fs.chmod(temporary, kind == "foreign" ? 0666 : 0600);
    }
    let before = fs.lstat(temporary);
    let original = fs.open;
    if (kind == "race")
        fs.open = (path, flags, permissions) => {
            if (path == temporary)
                fs.symlink(victim, temporary);
            return original(path, flags, permissions);
        };
    let result = null;
    let error = null;
    try { result = rpc.invoke(request([ "enable" ], { request_id: prepared.id }), "rpc_write"); }
    catch (e) { error = e; }
    fs.open = original;
    if (error != null)
        die(error.message);
    t.ok(fs.readfile(victim) == "synthetic foreign state", "the synthetic victim must not be modified");
    t.eq(fs.lstat(temporary)?.type, kind == "symlink" || kind == "race" ? "link" : "file");
    if (before != null) {
        t.eq(fs.lstat(temporary).inode, before.inode);
        t.eq(fs.lstat(temporary).mode, before.mode);
    }
    t.eq(fs.readfile(temporary), kind == "foreign" || kind == "safe" ? "preexisting regular entry" : "synthetic foreign state");
    t.ok(result?.code != null && result.code != 0);
    t.eq(uloop.__processes(), []);
}

t.test("a journal temporary symlink cannot overwrite its victim", () => journal_temporary_case("symlink"));
t.test("a journal temporary hardlink cannot overwrite its victim", () => journal_temporary_case("hardlink"));
t.test("a foreign journal temporary remains unchanged before spawn refusal", () => journal_temporary_case("foreign"));
t.test("an existing safe regular temporary is refused without overwrite", () => journal_temporary_case("safe"));
t.test("a symlink inserted immediately before native journal open cannot be followed", () => journal_temporary_case("race"));

function prepared_spool_case(name) {
    let rpc = fresh();
    let prepared = rpc.prepare({ args: { argv: [ "show_version" ], ubus_rpc_session: SID } }, "rpc_read");
    let directory = rpc.paths.temporary + "/" + prepared.id;
    let victim = common.parent_dir(rpc.paths.temporary) + "/victim";
    fs.writefile(victim, "synthetic foreign state");
    fs.symlink(victim, directory + "/" + name);
    let result = rpc.invoke(request([ "show_version" ], { request_id: prepared.id }), "rpc_read");
    t.ok(result?.code != null && result.code != 0, "an existing prepared spool entry must refuse before spawn");
    t.eq(length(uloop.__processes()), 0);
    t.ok(fs.readfile(victim) == "synthetic foreign state");
    t.eq(fs.lstat(directory + "/" + name).type, "link");
    t.eq(json(fs.readfile(directory + "/record.json")).phase, "prepared");
}

t.test("prepared stdout symlinks refuse before a payload can start", () => prepared_spool_case("stdout"));
t.test("prepared stderr symlinks refuse before a payload can start", () => prepared_spool_case("stderr"));
t.test("prepared status symlinks refuse before a payload can start", () => prepared_spool_case("status"));
t.test("prepared pipe entries refuse before a payload can start", () => {
    for (let name in [ "stdout.pipe", "stderr.pipe", "guard.pipe" ])
        prepared_spool_case(name);
});

t.test("record synchronization or partial writes fail before spawn even after a valid request digest", () => {
    for (let mode in [ "record-sync", "directory-sync", "partial-write" ]) {
        let rpc = fresh();
        let prepared = rpc.prepare({ args: { argv: [ "enable" ], ubus_rpc_session: SID } }, "rpc_write");
        let original_open = fs.open;
        if (mode == "partial-write")
            fs.open = (path, flags, permissions) => match(path, /\/record\.new$/)
                ? { write: () => 0, close: () => true } : original_open(path, flags, permissions);
        else {
            let sync = common.parent_dir(rpc.paths.temporary) + "/sync.sh";
            fs.writefile(sync, "case \"$1\" in " + (mode == "record-sync" ? "*/record.new" : "*/" + prepared.id) +
                ") exit 1;; esac\nexec /usr/bin/sync \"$1\"\n");
            rpc.paths.fsync = [ "/bin/sh", sync ];
        }
        let result = rpc.invoke(request([ "enable" ], { request_id: prepared.id }), "rpc_write");
        fs.open = original_open;
        t.contains(result.stderr, "recorded before execution", mode);
        t.eq(uloop.__processes(), [], mode);
    }
});

t.test("a corrupt or foreign journal fails closed without executing or deleting unrecognized data", () => {
    for (let content in [ "{truncated", "{}", '{"format":"other"}' ]) {
        let rpc = fresh();
        let prepared = rpc.prepare({ args: { argv: [ "enable" ], ubus_rpc_session: SID } }, "rpc_write");
        let path = rpc.paths.temporary + "/" + prepared.id + "/record.json";
        fs.writefile(path, content);
        let replacement = stub.fresh("service.rpc");
        replacement.paths.temporary = rpc.paths.temporary;
        replacement.paths.fsync = rpc.paths.fsync;
        t.eq(replacement.prepare({ args: { argv: [ "enable" ], ubus_rpc_session: SID } }, "rpc_write").success, false);
        t.ok(replacement.invoke(request([ "enable" ], { request_id: prepared.id }), "rpc_write").code != 0);
        t.eq(fs.readfile(path), content);
        t.eq(uloop.__processes(), []);
    }
});

t.test("recovery rejects injected runtime fields and impossible phases in an otherwise valid record", () => {
    for (let change in [ { child: { pid: 1 } }, { operation: [] },
        { phase: "running", response: { code: 0, stdout: "", stderr: "" } },
        { phase: "done", response: { code: 0, stdout: "", stderr: "" }, expires: common.monotonic_ms() + 3600000 } ]) {
        let rpc = fresh();
        let prepared = rpc.prepare({ args: { argv: [ "enable" ], ubus_rpc_session: SID } }, "rpc_write");
        let path = rpc.paths.temporary + "/" + prepared.id + "/record.json";
        let content = sprintf("%J", { ...json(fs.readfile(path)), ...change });
        fs.writefile(path, content);
        let replacement = stub.fresh("service.rpc");
        replacement.paths.temporary = rpc.paths.temporary;
        replacement.paths.fsync = rpc.paths.fsync;
        t.eq(replacement.prepare({ args: { argv: [ "enable" ], ubus_rpc_session: SID } }, "rpc_write").success, false);
        t.eq(fs.readfile(path), content);
        t.eq(uloop.__processes(), []);
    }
});

t.test("diagnostics acknowledge immediately and remain pollable beyond an HTTP server's sixty-second request limit", () => {
    let rpc = fresh();
    let real_time = common.monotonic_ms;
    let now = real_time();
    common.monotonic_ms = () => now;
    let value = request([ "check_dns" ]);
    start(rpc, value, "rpc_read");
    t.eq(value.initial.pending, true);
    t.eq(value.replies, 1);
    t.eq(rpc.DIAGNOSTIC_MS > 60000, true);
    now += 61000;
    let args = { id: value.args.request_id, part: "status", offset: 0, ubus_rpc_session: SID };
    t.eq(rpc.result({ args }, "rpc_read").pending, true);
    complete(0);
    common.monotonic_ms = real_time;
    t.eq(value.replied.code, 0);
});

t.test("a request refused before execution logs its reason without its arguments or session", () => {
    let rpc = fresh();
    stub.commands([ [ "logger", {} ] ]);
    let result = rpc.prepare(request([ "start", "synthetic-private-argument" ]), "rpc_write");
    let lines = join("\n", stub.command_lines());
    stub.restore();
    t.eq(result.success, false);
    t.contains(lines, "RPC refused: The RPC operation is not allowed");
    t.excludes(lines, "synthetic-private-argument");
    t.excludes(lines, SID);
});

t.done();
