let t = require("t");
let stub = require("stub");
let fs = require("fs");
let common = require("core.common");
let ubus = require("ubus");
let worker = require("service.worker");
let watch = require("service.singbox_watch");

let dir = stub.tmpdir();
watch.paths.pid = dir + "/sing-box-watch.pid";
watch.paths.pending_cleanup = dir + "/sing-box-watch.cleanup";

function fail(pid, exit_code, service) {
    return { type: "instance.fail", data: { service: service ?? "sing-box", instance: "instance1", pid, exit_code, respawn_count: 6 } };
}

t.test("only procd giving up on sing-box is a crash to clean up", () => {
    t.ok(watch.should_cleanup(fail(15047, 137)));
    t.ok(!watch.should_cleanup(fail(1, 1, "dnsmasq")), "another service failing");
    t.ok(!watch.should_cleanup({ type: "instance.respawn", data: { service: "sing-box", exit_code: 137 } }), "an ordinary respawn");
    t.ok(watch.cleanup_event_key(fail(15047, 137)) != watch.cleanup_event_key(fail(16048, 137)), "separate crash loops");
    t.eq(watch.cleanup_event_key(fail(15047, 137)), watch.cleanup_event_key(fail(15047, 137)));
});

t.test("a watcher that starts after procd gave up finds the crash in the service state", () => {
    let instance = (state) => ({ "sing-box": { instances: state == null ? {} : { instance1: state } } });
    t.eq(watch.failed_exit_code(instance({ running: false, exit_code: 137 })), "137");
    t.eq(watch.failed_exit_code(instance({ running: false, exit_code: 137, respawn: { retry: 5 } })), null, "still respawning");
    t.eq(watch.failed_exit_code(instance({ running: true, pid: 123 })), null);
    t.eq(watch.failed_exit_code(instance(null)), null);
});

let cleanups = [];

function monitored(services, cleanup_status) {
    cleanups = [];
    ubus.__reset();
    ubus.__on("service.list", () => services);
    stub.commands([ [ "/usr/bin/forkop sing_box_crash_cleanup", (argv) => {
        push(cleanups, argv[2]);
        return { status: cleanup_status ?? 0 };
    } ] ]);
    let status = watch.monitor();
    stub.restore();
    return status;
}

t.test("the watcher cleans up a crash once per crash loop and records it until the cleanup ran", () => {
    t.eq(monitored({}), 0);
    t.eq(cleanups, []);
    t.ok(fs.stat(watch.paths.pid) == null, "a watcher that ends removes its record");

    t.eq(monitored({ "sing-box": { instances: { instance1: { running: false, exit_code: 137 } } } }), 0);
    t.eq(cleanups, [ "137" ], "a crash whose notification was lost");

    fs.writefile(watch.paths.pending_cleanup, "139\n");
    t.eq(monitored({}), 0);
    t.eq(cleanups, [ "139" ], "a cleanup its previous process did not finish");

    fs.unlink(watch.paths.pending_cleanup);
    t.eq(monitored({ "sing-box": { instances: { instance1: { running: false, exit_code: 137 } } } }, 1), 1,
        "a failed cleanup ends the watcher, so procd respawns it");
    t.eq(trim(fs.readfile(watch.paths.pending_cleanup)), "137");
});

t.test("a notification from procd runs the cleanup, and a repeated one does not", () => {
    cleanups = [];
    ubus.__reset();
    ubus.__on("service.list", () => ({}));
    stub.commands([ [ "/usr/bin/forkop sing_box_crash_cleanup", (argv) => { push(cleanups, argv[2]); return {}; } ] ]);
    fs.unlink(watch.paths.pending_cleanup);
    let uloop = require("uloop");
    uloop.__on_run(() => {
        ubus.__notify("service", "instance.fail", fail(15047, 137).data);
        ubus.__notify("service", "instance.fail", fail(15047, 137).data);
        ubus.__notify("service", "instance.fail", fail(1, 1, "dnsmasq").data);
        ubus.__notify("service", "instance.fail", fail(16048, 137).data);
    });
    t.eq(watch.monitor(), 0);
    uloop.__on_run(null);
    stub.restore();
    t.eq(cleanups, [ "137", "137" ]);
});

t.test("a core procd respawns pauses the capture on its exit, naming the pid it ran as, and resumes it on its start", () => {
    let steps = [];
    let pid = 4242;
    ubus.__reset();
    ubus.__on("service.list", () => ({ "sing-box": { instances: { instance1: { running: true, pid } } } }));
    let step = (argv) => { push(steps, join(" ", slice(argv, 1))); return {}; };
    stub.commands([ [ "/usr/bin/forkop sing_box_crash_pause", step ], [ "/usr/bin/forkop sing_box_crash_resume", step ] ]);
    fs.unlink(watch.paths.pending_cleanup);
    let uloop = require("uloop");
    let service = (name) => ({ service: name, instance: "instance1" });
    uloop.__on_run(() => {
        ubus.__notify("service", "instance.stop", service("sing-box"));
        ubus.__notify("service", "instance.respawn", service("sing-box"));
        pid = 4343;
        ubus.__notify("service", "instance.start", service("sing-box"));
        ubus.__notify("service", "instance.stop", service("sing-box"));
        ubus.__notify("service", "instance.stop", service("dnsmasq"));
    });
    t.eq(watch.monitor(), 0);
    uloop.__on_run(null);
    stub.restore();
    t.eq(steps, [ "sing_box_crash_pause 4242", "sing_box_crash_resume", "sing_box_crash_pause 4343" ]);
});

t.test("a stop that arrives while the watcher starts up ends it as soon as its loop runs", () => {
    ubus.__reset();
    let uloop = require("uloop");
    uloop.__reset();
    ubus.__on("service.list", () => {
        uloop.__raise("SIGTERM");
        return {};
    });
    fs.unlink(watch.paths.pending_cleanup);
    let looped = false;
    uloop.__on_run(() => { looped = true; });
    t.eq(watch.monitor(), 0);
    uloop.__on_run(null);
    t.ok(!looped, "the loop ran on after the stop");
    t.ok(fs.stat(watch.paths.pid) == null, "a watcher that ends removes its record");
});

t.test("the watcher is a respawning procd service found again by its command line", () => {
    let spec = watch.spec();
    let payload = worker.payload(spec);
    t.eq(payload.name, "forkop-singbox-watch");
    t.eq(payload.instances.watch.command, [ "/usr/bin/forkop", "sing_box_watch" ]);
    t.eq(payload.instances.watch.respawn, [ "3600", "5", "0" ]);
    t.ok(!worker.is_worker(spec, common.own_pid()), "a process running something else");
});

t.test("stopping the watcher never signals a pid that is not the watcher", () => {
    fs.writefile(watch.paths.pid, common.own_pid() + "\n");
    stub.commands([ [ "ubus call service delete", { status: 4 } ], [ "ubus call service list", { stdout: "{\"forkop-singbox-watch\":{}}" } ] ]);
    t.ok(!watch.stop_worker(), "procd still holds the service");
    t.eq(trim(fs.readfile(watch.paths.pid)), common.own_pid(), "the record stays for the next attempt");

    stub.commands([ [ "ubus call service delete", { status: 4 } ], [ "ubus call service list", { stdout: "{}" } ] ]);
    t.ok(watch.stop_worker(), "a service already gone");
    t.eq(filter(stub.command_lines(), (line) => substr(line, 0, 4) == "kill"), []);
    t.ok(fs.stat(watch.paths.pid) == null, "a stale record is removed");
    stub.restore();
});

t.test("watcher readiness requires its recorded process and its own procd registration", () => {
    let me = common.own_pid();
    let readfile = fs.readfile;
    fs.writefile(watch.paths.pid, me + "\n");
    for (let candidate in [
        [ { "forkop-singbox-watch": { instances: { watch: {} } } }, true, true ],
        [ {}, true, false ],
        [ { "forkop-singbox-watch": { instances: { other: {} } } }, true, false ],
        [ { "forkop-singbox-watch": { instances: { watch: {} } } }, false, false ],
        [ null, true, false ]
    ]) {
        fs.readfile = (path) => path == "/proc/" + me + "/cmdline"
            ? (candidate[1] ? "ucode\0/usr/bin/forkop\0sing_box_watch\0" : "other\0") : readfile(path);
        stub.commands([ [ "ubus call service list", { stdout: sprintf("%J", candidate[0]) } ] ]);
        let current = watch.worker_current();
        fs.readfile = readfile;
        stub.restore();
        t.eq(current, candidate[2]);
    }
    fs.unlink(watch.paths.pid);
});

t.done();
