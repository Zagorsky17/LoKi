let t = require("t");
let fs = require("fs");
let stub = require("stub");
let runtime = require("singbox.runtime");
let health = require("service.health");

function identify(failure) {
    let path = "/etc/loki-core/config.json";
    let command = [ "/usr/bin/loki-core", "run", "-c", path, "-D", "/usr/share/loki-core" ];
    let dir = stub.tmpdir();
    let source = dir + "/cmdline";
    let body = join("\u0000", command) + "\u0000";
    fs.writefile(source, failure == "oversized" ? sprintf("%65537s", "") : failure == "argv" ? body + "extra\u0000" : body);
    let original = { open: fs.open, readlink: fs.readlink, service: health.sing_box_service_list, ticks: health.start_ticks };
    let reads = 0, closes = 0;
    health.start_ticks = () => failure == "pid-reuse" && ++reads > 1 ? 999 : 456;
    health.sing_box_service_list = (verbose) => {
        t.eq(verbose, true);
        if (failure == "procd") return null;
        let instance = { running: true, pid: 1234, command: failure == "command" ? [ ...command, "wrong" ] : command };
        return { "loki-core": { instances: failure == "duplicate" ? { a: instance, b: instance } : { main: instance } } };
    };
    fs.readlink = (name) => {
        t.eq(name, "/proc/1234/exe");
        if (failure == "exe-throw") die("SYNTHETIC_PRIVATE_EXE");
        return failure == "exe" ? "/usr/bin/loki-core (deleted)" : "/usr/bin/loki-core";
    };
    fs.open = (name, mode) => {
        t.eq(name, "/proc/1234/cmdline");
        if (failure == "open") return null;
        let file = original.open(source, mode);
        return { read: (n) => { if (failure == "read") die("SYNTHETIC_PRIVATE_ARGV"); return file.read(n); },
            error: () => failure == "io" ? "synthetic I/O" : file.error(),
            close: () => { closes++; file.close();
                if (failure == "close-throw") die("SYNTHETIC_PRIVATE_CLOSE"); return failure != "close"; } };
    };
    let result;
    let error = null;
    try { result = runtime.identity(path); }
    catch (e) { error = e.message; }
    fs.open = original.open; fs.readlink = original.readlink;
    health.sing_box_service_list = original.service; health.start_ticks = original.ticks;
    return { result, error, closes, command };
}

t.test("core identity binds procd command, executable, complete argv and start ticks", () => {
    let value = identify("");
    t.eq(value.error, null);
    t.eq(value.result, { pid: "1234", start_ticks: "456", command: value.command });
    t.eq(value.closes, 1);
});

t.test("missing, replaced, malformed or unverifiable core identity is refused without exposing argv", () => {
    for (let failure in [ "procd", "command", "duplicate", "exe", "exe-throw", "open", "read", "io",
        "argv", "oversized", "pid-reuse", "close", "close-throw" ]) {
        let value = identify(failure);
        t.eq(value.error, null, failure);
        t.eq(value.result, null, failure);
        if (index([ "read", "io", "argv", "oversized", "pid-reuse", "close", "close-throw" ], failure) >= 0)
            t.eq(value.closes, 1, failure);
    }
});

t.done();
