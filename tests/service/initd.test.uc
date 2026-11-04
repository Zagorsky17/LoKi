// Modified for LoKi on 2026-11-03: reject unsafe cache paths before stop/start.
let t = require("t");
let stub = require("stub");
let fs = require("fs");
let common = require("core.common");
let fixture = require("fixture");
let lock = require("service.lock");
let nft_state = require("nft.state");
let health = require("service.health");
let ui = require("service.ui");
let lifecycle = require("service.lifecycle");
let initd = require("service.initd");
let start_request = require("service.start_request");

let me = common.own_pid();
let calls = [];
let running = false;
let table = false;
let restored = false;
let lifecycle_status = 0;

function fresh(settings) {
    let dir = stub.tmpdir();
    ui.paths.service_actions = dir + "/service-actions";
    ui.paths.service_action_lock = dir + "/service-actions.lock";
    ui.paths.reload_lock = dir + "/forkop.reload.lock";
    ui.paths.pending_reload = dir + "/reload.pending";
    initd.paths.config = dir + "/forkop.config";
    start_request.paths.pending = dir + "/start.retry";
    start_request.paths.lock = dir + "/start-request.lock";
    initd.paths.internal_change = dir + "/internal-config-change";
    start_request.paths.autostart = dir + "/S99forkop";
    fs.writefile(initd.paths.config, "config forkop\n");
    fixture.seed({ settings: settings ?? {} });
    calls = [];
    running = false;
    table = false;
    restored = false;
    lifecycle_status = 0;
    health.forkop_stably_running = () => running;
    nft_state.table_present = () => table;
    lifecycle.restore_routing = () => {
        push(calls, "lifecycle restore routing");
        return restored;
    };
    lifecycle.start = (guard) => {
        if (guard != null && !guard())
            return 0;
        push(calls, "lifecycle start");
        return lifecycle_status;
    };
    lifecycle.stop = () => { push(calls, "lifecycle stop"); return lifecycle_status; };
    lifecycle.reload = (reason) => {
        push(calls, "lifecycle reload " + reason);
        push(calls, lock.held(ui.paths.reload_lock) ? "reload lock held" : "reload lock free");
        return lifecycle_status;
    };
    return dir;
}

function hooks(registered, extra) {
    stub.commands([
        [ "logger", {} ],
        [ "ubus call service list", registered == null ? { status: 4 } : { stdout: registered ? "{\"forkop\":{}}" : "{}" } ],
        ...(extra ?? [])
    ]);
}

function reloaded(reason, registered) {
    hooks(registered ?? true);
    let result = stub.capture(() => initd.reload(reason));
    stub.restore();
    return result.result;
}

function guard(age, config_hash) {
    fs.writefile(initd.paths.internal_change, sprintf("%d\n%s\n", common.now_seconds() - age, config_hash));
}

t.test("a reload the configuration change of a known writer triggered is skipped once", () => {
    fresh();
    running = true;
    stub.commands([ [ "md5sum", { stdout: "abc  " + initd.paths.config + "\n" } ], [ "ubus call service list", { stdout: "{\"forkop\":{}}" } ], [ "logger", {} ] ]);
    guard(0, "abc");
    t.eq(initd.reload("on_config_change"), { status: 0, sync: false });
    t.eq(calls, []);
    t.ok(fs.stat(initd.paths.internal_change) == null, "the guard is used up");

    guard(0, "abc");
    initd.reload("");
    t.eq(calls, [ "lifecycle reload ", "reload lock held" ], "a reload asked for by hand runs");
    t.ok(fs.stat(initd.paths.internal_change) != null, "and leaves the guard alone");

    for (let stale in [ [ 60, "abc" ], [ 0, "other" ] ]) {
        calls = [];
        guard(stale[0], stale[1]);
        initd.reload("on_config_change");
        t.eq(calls[0], "lifecycle reload on_config_change", "a guard that is " + (stale[0] ? "old" : "for another configuration"));
        t.ok(fs.stat(initd.paths.internal_change) == null);
    }
    stub.restore();
});

t.test("a reload runs the lifecycle under the reload lock and asks for the triggers after a config change", () => {
    fresh();
    running = true;
    hooks(true);
    t.eq(initd.reload("on_config_change"), { status: 0, sync: true });
    t.eq(calls, [ "lifecycle reload on_config_change", "reload lock held" ]);
    t.ok(!lock.held(ui.paths.reload_lock), "the lock is released");
    lifecycle_status = 5;
    t.eq(initd.reload("on_config_change"), { status: 5, sync: false });
    t.eq(initd.reload("")?.sync, false);
    stub.restore();
});

t.test("a reload of a service procd does not hold does nothing, and one procd gave no answer about runs", () => {
    fresh();
    running = true;
    for (let reason in [ "on_config_change", "" ]) {
        t.eq(reloaded(reason, false), { status: 0, sync: false });
        t.eq(calls, []);
    }
    t.ok(fs.stat(ui.paths.pending_reload) == null, "it does not queue itself either");
    reloaded("on_config_change", null);
    t.eq(calls[0], "lifecycle reload on_config_change");
});

t.test("a config change to a stopped runtime waits for the action bringing it up, or is dropped", () => {
    fresh();
    t.eq(reloaded("on_config_change"), { status: 0, sync: false });
    t.eq(calls, []);
    t.ok(fs.stat(ui.paths.pending_reload) == null, "nothing brings it up");

    let starting = ui.begin("start", "ui", me);
    reloaded("on_config_change");
    t.eq(calls, []);
    t.matches(fs.readfile(ui.paths.pending_reload), /^reason=on_config_change\n/, "queued behind the start");

    reloaded("pending");
    t.eq(calls, [], "a queued reload waits while another action runs");
    t.matches(fs.readfile(ui.paths.pending_reload), /^reason=pending\n/);
    ui.finish("start", starting.job_id, 1);
});

t.test("a reload that finds the reload lock taken queues itself", () => {
    fresh();
    running = true;
    lock.acquire(ui.paths.reload_lock, me);
    reloaded("on_config_change");
    t.eq(calls, []);
    t.matches(fs.readfile(ui.paths.pending_reload), /^reason=on_config_change\n/);
    lock.release(ui.paths.reload_lock, me);
});

t.test("a failed enabled start leaves its generation for retry and a good one clears it", () => {
    fresh();
    fs.symlink("../init.d/forkop", start_request.paths.autostart);
    hooks(true);
    lifecycle_status = 1;
    t.eq(stub.capture(() => initd.start("boot")).result, 1);
    let first = start_request.token();
    t.ok(first != "");
    t.eq(initd.retry_start(first), 1);
    t.eq(start_request.token(), first, "a retry does not create a new intent");
    lifecycle_status = 0;
    t.eq(stub.capture(() => initd.retry_start(first)).stdout, "");
    t.eq(start_request.token(), "");
    stub.restore();
});

t.test("failed manual starts describe only the retry that is actually armed", () => {
    fresh();
    let logs = [];
    stub.commands([ stub.logger(logs), [ "ubus call service list", { stdout: "{\"forkop\":{}}" } ] ]);
    lifecycle_status = 1;
    stub.capture(() => initd.start(""));
    t.eq(start_request.token(), "", "enabling later must not resurrect a failed disabled start");
    fs.symlink("../init.d/forkop", start_request.paths.autostart);
    stub.capture(() => initd.start(""));
    stub.restore();
    t.eq(logs, [ "[warn] LoKi did not start", "[warn] LoKi did not start; it retries while autostart remains enabled" ]);
});

t.test("a retry needs a pending generation and our exact autostart link", () => {
    fresh();
    hooks(true);
    start_request.begin();
    running = true;
    initd.retry_start();
    t.eq(start_request.token(), "");
    running = false;
    for (let kind in [ "absent", "file", "foreign" ]) {
        if (kind == "file")
            fs.writefile(start_request.paths.autostart, "foreign");
        if (kind == "foreign")
            fs.symlink("../init.d/other", start_request.paths.autostart);
        start_request.begin();
        initd.retry_start();
        t.eq(calls, [], kind);
        t.eq(start_request.token(), "");
        fs.unlink(start_request.paths.autostart);
    }
    fs.symlink("../init.d/forkop", start_request.paths.autostart);
    initd.retry_start();
    t.eq(calls, [], "an explicit stop stays stopped");
    start_request.begin();
    initd.retry_start();
    t.eq(calls, [ "lifecycle start" ]);
    stub.restore();
});

t.test("a monitored WAN coming back reapplies a running configuration", () => {
    fresh({ enable_badwan_interface_monitoring: "1", badwan_monitored_interfaces: "wan wwan" });
    let reloads = [];
    hooks(true, [ [ "/etc/init.d/forkop reload", (argv) => { push(reloads, argv[2]); return {}; } ] ]);
    running = true;
    initd.wan_up();
    t.eq(reloads, [ "interface_up:wan" ]);

    fresh({ badwan_monitored_interfaces: "wan" });
    running = true;
    initd.wan_up();
    t.eq(reloads, [ "interface_up:wan" ], "an unmonitored WAN");
    stub.restore();
});

t.test("a WAN coming up after a network restart puts back the routing under a table that is still there", () => {
    fresh({ enable_badwan_interface_monitoring: "1", badwan_monitored_interfaces: "wan" });
    let commands = [];
    hooks(true, [ [ "/etc/init.d/forkop", (argv) => { push(commands, argv[1] + " " + argv[2]); return {}; } ] ]);
    fs.symlink("../init.d/forkop", start_request.paths.autostart);
    start_request.begin();
    table = true;
    restored = true;
    initd.wan_up();
    t.eq(calls, [ "lifecycle restore routing" ]);
    t.eq(commands, [ "reload interface_up:wan" ], "a monitored WAN is reapplied as on any WAN-up");
    t.ok(fs.stat(start_request.paths.pending) == null, "no restart is left to try");

    calls = [];
    commands = [];
    restored = false;
    start_request.begin();
    initd.wan_up();
    t.eq([ calls, commands ], [ [ "lifecycle restore routing", "lifecycle start" ], [] ], "failed restoration retries without a stop/restart that could erase newer intent");

    calls = [];
    commands = [];
    table = false;
    initd.wan_up();
    t.eq(calls, [], "a stopped LoKi has no table and no routing to restore");
    stub.restore();
});

t.test("the triggers reload on a config change and on the monitored interfaces", () => {
    fresh({ enable_badwan_interface_monitoring: "1", badwan_monitored_interfaces: "wan wwan lte", badwan_reload_delay: "5000" });
    t.eq(split(initd.triggers(), "\n"), [
        "delay\t5000",
        "config\tconfig.change\tforkop\t/etc/init.d/forkop\treload\ton_config_change",
        "interface\tinterface.*.up\twan\t/etc/init.d/forkop\thandle_wan_up\t",
        "interface\tinterface.*.up\twwan\t/etc/init.d/forkop\treload\tinterface_up:wwan",
        "interface\tinterface.*.up\tlte\t/etc/init.d/forkop\treload\tinterface_up:lte",
        ""
    ]);
    fresh({});
    t.eq(split(initd.triggers(), "\n")[0], "delay\t2000");
    t.eq(length(split(initd.triggers(), "\n")), 4);
    // procd takes the delay as a number of milliseconds and nothing else.
    fresh({ badwan_reload_delay: "2s" });
    t.eq(split(initd.triggers(), "\n")[0], "delay\t2000");
});

t.test("a restart is one action for whoever asked, with the stop and start inside it", () => {
    fresh();
    let nested = [];
    hooks(true, [ [ "/etc/init.d/forkop", (argv) => {
        push(nested, argv[1] + (ui.active_action() == "restart" ? " inside restart" : ""));
        return { status: argv[1] == "start" ? 7 : 0 };
    } ] ]);
    t.eq(initd.restart(), 7, "the start decides");
    t.eq(nested, [ "stop inside restart", "start inside restart" ]);
    t.eq(ui.active_action(), "");
    stub.restore();
});

t.test("restart refuses an unsafe cache path before stopping the running service", () => {
    let dir = fresh();
    fs.mkdir(dir + "/public-cache", 0755);
    fixture.seed({ settings: { cache_path: dir + "/public-cache/cache.db" } });
    let nested = [];
    let logs = [];
    stub.commands([ stub.logger(logs), [ "/etc/init.d/forkop", (argv) => {
        push(nested, argv[1]);
        return { status: 0 };
    } ] ]);
    let status = initd.restart();
    stub.restore();
    t.eq(nested, [], "the unsafe path must be rejected before stop or start");
    t.eq(status, 1);
    t.eq(ui.active_action(), "");
    t.eq(fs.stat(dir + "/public-cache").mode & 0777, 0755);
    t.ok(index(sprintf("%J", logs), dir) < 0, "the restart error masks the selected path");
});

t.test("boot refuses a disabled service but an explicit manual Start remains allowed", () => {
    fresh();
    hooks(true);
    t.eq(initd.start("boot"), 0);
    t.eq(calls, []);
    t.eq(start_request.token(), "");
    t.eq(initd.start(""), 0);
    t.eq(calls, [ "lifecycle start" ]);
    stub.restore();
});

t.test("an initial failed start cannot recreate a request cancelled while it ran", () => {
    fresh();
    hooks(true);
    fs.symlink("../init.d/forkop", start_request.paths.autostart);
    lifecycle.start = (guard) => {
        t.ok(start_request.token() != "", "intent exists before lifecycle mutates anything");
        t.eq(lock.held(start_request.paths.lock), false);
        t.ok(guard());
        start_request.cancel();
        t.eq(guard(), false);
        return 1;
    };
    t.eq(initd.start("boot"), 1);
    t.eq(start_request.token(), "");
    stub.restore();
});

t.test("old successful completion and queued retry leave a new Start generation alone", () => {
    fresh();
    hooks(true);
    fs.symlink("../init.d/forkop", start_request.paths.autostart);
    let old;
    let next;
    lifecycle.start = () => {
        old = start_request.token();
        next = start_request.begin();
        return 0;
    };
    t.eq(initd.start("boot"), 0);
    t.eq(start_request.token(), next);
    t.eq(initd.retry_start(old), 0);
    t.eq(start_request.token(), next);
    stub.restore();
});

t.test("an intent write failure refuses before lifecycle and a clear failure remains an error", () => {
    let dir = fresh();
    hooks(true);
    fs.writefile(dir + "/not-a-dir", "foreign");
    start_request.paths.pending = dir + "/not-a-dir/request";
    t.eq(initd.start(""), 1);
    t.eq(calls, []);
    start_request.paths.pending = dir + "/start.retry";
    let unlink = fs.unlink;
    fs.unlink = (path) => path == start_request.paths.pending ? false : unlink(path);
    let status = initd.start("");
    fs.unlink = unlink;
    t.eq(status, 1);
    t.ok(start_request.token() != "");
    t.eq(ui.active_action(), "");
    stub.restore();
});

t.test("late readiness retries on the timer without any WAN event and retires its own instance", () => {
    fresh();
    hooks(true);
    fs.symlink("../init.d/forkop", start_request.paths.autostart);
    let token = start_request.begin();
    let uloop = require("uloop");
    let ubus = require("ubus");
    uloop.__reset();
    ubus.__reset();
    ubus.__on("service.delete", {});
    lifecycle_status = 1;
    uloop.__on_run(() => {
        t.eq(uloop.__timers()[0].ms, 30000);
        uloop.__fire("timer");
        t.eq(start_request.token(), token);
        t.eq(ubus.__calls(), []);
        lifecycle_status = 0;
        uloop.__fire("timer");
    });
    t.eq(initd.retry_monitor(token), 0);
    t.eq(calls, [ "lifecycle start", "lifecycle start" ]);
    t.eq(ubus.__calls(), [ { object: "service", method: "delete", args: {
        name: "forkop", instance: "start-retry-" + token
    } } ]);
    t.eq(start_request.token(), "");
    stub.restore();
});

t.test("timer cancellation and a newer generation cannot delete the newer instance", () => {
    fresh();
    hooks(true);
    fs.symlink("../init.d/forkop", start_request.paths.autostart);
    let old = start_request.begin();
    let next;
    let uloop = require("uloop");
    let ubus = require("ubus");
    uloop.__reset();
    ubus.__reset();
    ubus.__on("service.delete", {});
    uloop.__on_run(() => {
        start_request.cancel();
        next = start_request.begin();
        uloop.__fire("timer");
    });
    t.eq(initd.retry_monitor(old), 0);
    t.eq(calls, []);
    t.eq(start_request.token(), next);
    t.eq(ubus.__calls()[0].args, { name: "forkop", instance: "start-retry-" + old });
    stub.restore();
});

t.test("external rc.common Disable cancels a timer without invoking lifecycle", () => {
    fresh();
    hooks(true);
    fs.symlink("../init.d/forkop", start_request.paths.autostart);
    let token = start_request.begin();
    let uloop = require("uloop");
    let ubus = require("ubus");
    uloop.__reset();
    ubus.__reset();
    ubus.__on("service.delete", {});
    uloop.__on_run(() => {
        fs.unlink(start_request.paths.autostart);
        uloop.__fire("timer");
    });
    t.eq(initd.retry_monitor(token), 0);
    t.eq(calls, []);
    t.eq(start_request.token(), "");
    fs.symlink("../init.d/forkop", start_request.paths.autostart);
    initd.retry_start();
    t.eq(calls, [], "Enable alone must not revive the cancelled retry");
    stub.restore();
});

t.test("monitor errors and malformed generation never delete the whole service", () => {
    fresh();
    let uloop = require("uloop");
    let ubus = require("ubus");
    uloop.__reset();
    ubus.__reset();
    for (let token in [ "", "1-2-3;other", "1-2-3\n", null ])
        t.eq(initd.retry_monitor(token), 1);
    t.eq(ubus.__calls(), []);
    ubus.__on("service.delete", ubus.__failure("temporary failure"));
    t.eq(initd.retry_monitor("1-2-3"), 1);
    t.eq(ubus.__calls()[0].args, { name: "forkop", instance: "start-retry-1-2-3" });
});

t.test("a persistent retry sees committed UCI changes before lifecycle validation", () => {
    fresh({ cache_path: "first" });
    hooks(true);
    fs.symlink("../init.d/forkop", start_request.paths.autostart);
    let uci = require("core.uci");
    let seen = [];
    lifecycle.start = () => { push(seen, uci.get("forkop.settings.cache_path")); return 1; };
    initd.start("boot");
    let editor = require("uci").cursor();
    editor.set("forkop", "settings", "cache_path", "second");
    editor.commit("forkop");
    initd.retry_start();
    t.eq(seen, [ "first", "second" ]);
    stub.restore();
});

t.test("Stop cancellation during a timer callback retires without a retry child", () => {
    fresh();
    hooks(true);
    fs.symlink("../init.d/forkop", start_request.paths.autostart);
    let token = start_request.begin();
    let uloop = require("uloop");
    let ubus = require("ubus");
    uloop.__reset();
    ubus.__reset();
    ubus.__on("service.delete", {});
    lifecycle.start = (guard) => {
        t.ok(guard());
        start_request.cancel(token);
        uloop.__raise("SIGTERM");
        t.eq(guard(), false);
        return 1;
    };
    uloop.__on_run(() => uloop.__fire("timer"));
    t.eq(initd.retry_monitor(token), 0);
    t.eq(start_request.token(), "");
    t.eq(uloop.__processes(), []);
    t.eq(ubus.__calls()[0].args.instance, "start-retry-" + token);
    stub.restore();
});

t.done();
