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
    initd.paths.start_retry = dir + "/start.retry";
    initd.paths.internal_change = dir + "/internal-config-change";
    initd.paths.autostart = dir + "/S99forkop";
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
    lifecycle.start = () => { push(calls, "lifecycle start"); return lifecycle_status; };
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

t.test("a failed start leaves a retry for the next WAN-up, and a good one clears it", () => {
    fresh();
    hooks(true);
    lifecycle_status = 1;
    t.eq(stub.capture(() => initd.start("")).result, 1);
    t.matches(fs.readfile(initd.paths.start_retry), /^reason=start_failed\n/);
    stub.capture(() => initd.start("triggered"));
    t.matches(fs.readfile(initd.paths.start_retry), /^reason=wan_retry_failed\n/);
    lifecycle_status = 0;
    t.eq(stub.capture(() => initd.start("")).stdout, "", "at boot procd would write it into the syslog beside the log's own line");
    t.ok(fs.stat(initd.paths.start_retry) == null);
    stub.restore();
});

t.test("a failed start says whether the WAN coming up tries it again", () => {
    fresh();
    let logs = [];
    stub.commands([ stub.logger(logs), [ "ubus call service list", { stdout: "{\"forkop\":{}}" } ] ]);
    lifecycle_status = 1;
    stub.capture(() => initd.start(""));
    fs.writefile(initd.paths.autostart, "");
    stub.capture(() => initd.start(""));
    stub.restore();
    t.eq(logs, [ "[warn] LoKi did not start", "[warn] LoKi did not start; it tries again when the WAN comes up" ]);
});

t.test("a WAN coming up restarts only a failed start of an enabled service", () => {
    fresh();
    let restarts = 0;
    hooks(true, [ [ "/etc/init.d/forkop restart triggered", () => { restarts++; return {}; } ] ]);
    lock.mark_request(initd.paths.start_retry, "start_failed");
    running = true;
    initd.retry_start();
    t.ok(fs.stat(initd.paths.start_retry) == null, "a running service needs no retry");

    running = false;
    lock.mark_request(initd.paths.start_retry, "start_failed");
    initd.retry_start();
    t.eq(restarts, 0, "a disabled service stays down");
    t.ok(fs.stat(initd.paths.start_retry) == null);

    fs.writefile(initd.paths.autostart, "");
    initd.retry_start();
    t.eq(restarts, 0, "a service stopped on purpose stays down");
    lock.mark_request(initd.paths.start_retry, "start_failed");
    initd.retry_start();
    t.eq(restarts, 1);
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
    fs.writefile(initd.paths.autostart, "");
    lock.mark_request(initd.paths.start_retry, "start_failed");
    table = true;
    restored = true;
    initd.wan_up();
    t.eq(calls, [ "lifecycle restore routing" ]);
    t.eq(commands, [ "reload interface_up:wan" ], "a monitored WAN is reapplied as on any WAN-up");
    t.ok(fs.stat(initd.paths.start_retry) == null, "no restart is left to try");

    calls = [];
    commands = [];
    restored = false;
    lock.mark_request(initd.paths.start_retry, "start_failed");
    initd.wan_up();
    t.eq([ calls, commands ], [ [ "lifecycle restore routing" ], [ "restart triggered" ] ], "a routing it could not restore leaves the failed start to retry");

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

t.done();
