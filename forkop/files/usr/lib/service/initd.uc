// Modified for LoKi on 2026-11-03: reject unsafe cache paths before restart stops the service.
// Modified for LoKi on 2026-11-03: product labels in user-facing messages.
// The init script's hooks; each is tracked as a UI action unless the page opened one for it.

let fs = require("fs");
let common = require("core.common");
let cache_path = require("core.cache_path");
let exec = require("core.exec");
let constants = require("core.constants");
let uci = require("core.uci");
let nft_state = require("nft.state");
let health = require("service.health");
let lock = require("service.lock");
let ui = require("service.ui");
let start_request = require("service.start_request");

const CONFIG_NAME = "forkop";
const CONFIG_CHANGE = "on_config_change";
// The reason of a reload a monitored interface set off, followed by its name.
const INTERFACE_UP = "interface_up:";
const SERVICE_INIT = constants.FORKOP_SERVICE_INIT;

let paths = {
    config: "/etc/config/forkop",
    // Written by the migration after it commits, so the reload its own commit
    // triggers is skipped.
    internal_change: "/var/run/forkop.internal-config-change"
};

// Loaded only by the hooks that run it: the status and trigger hooks do not, the WAN hook only
// to put back the routing of a table that is still there.
function lifecycle() {
    return require("service.lifecycle");
}

function settings() {
    return uci.get_all(CONFIG_NAME, "settings") ?? {};
}

function tracked() {
    return getenv("FORKOP_UI_ACTION_TRACKED") == "1";
}

function begin(action) {
    return tracked() ? "" : ui.begin(action, "initd", common.own_pid()).job_id;
}

function finish(action, job_id, status) {
    if (job_id != "")
        ui.finish(action, job_id, status);
}

function runtime_running() {
    return health.forkop_stably_running(constants.RT_TABLE_NAME, constants.NFT_TABLE_NAME, constants.NFT_FAKEIP_MARK, 2);
}

// The guard names the configuration its writer committed; a reload of that
// exact configuration within half a minute is the one its commit triggered.
function internal_change(reason) {
    if (reason != CONFIG_CHANGE || fs.stat(paths.internal_change) == null)
        return false;
    let guard = split(fs.readfile(paths.internal_change) ?? "", "\n");
    fs.unlink(paths.internal_change);
    if (!match(guard[0], /^[0-9]+$/) || common.now_seconds() - int(guard[0]) > 30 || (guard[1] ?? "") == "")
        return false;
    let hash = split(trim(exec.output([ "md5sum", paths.config ]) ?? ""), " ")[0];
    return guard[1] == hash;
}

// A reload applies only while procd holds the service; without procd's answer it runs.
function registered() {
    let services = common.parse_json(exec.output([ "ubus", "call", "service", "list", sprintf("%J", { name: "forkop" }) ]));
    return type(services) != "object" || services.forkop != null;
}

function attempt(token, automatic) {
    let job = begin("start");
    let guard = () => start_request.current(token) && (!automatic || start_request.enabled());
    uci.reset();
    let status = lifecycle().start(guard);
    if (status == 0 || !start_request.enabled()) {
        if (!start_request.cancel(token)) {
            exec.log("error", "Failed to clear the pending LoKi start");
            status = 1;
        }
    }
    if (status != 0)
        exec.log("warn", "LoKi did not start" + (start_request.current(token) && start_request.enabled()
            ? "; it retries while autostart remains enabled" : ""));
    finish("start", job, status);
    return status;
}

function start(reason) {
    if (reason == "boot" && !start_request.enabled())
        return 0;
    let token = start_request.begin();
    if (token == "") {
        exec.log("error", "Failed to record the LoKi start request");
        return 1;
    }
    return attempt(token, reason == "boot");
}

function stop() {
    let job = begin("stop");
    let status = lifecycle().stop();
    finish("stop", job, status);
    return status;
}

// One action, though rc.common runs a stop and a start: the nested two open none of their own.
function restart() {
    let job = begin("restart");
    try {
        cache_path.validate(settings());
    }
    catch (e) {
        exec.log("error", e.message);
        finish("restart", job, 1);
        return 1;
    }
    let status = exec.run([ SERVICE_INIT, "stop" ]);
    let start_status = exec.run([ SERVICE_INIT, "start" ]);
    if (start_status != 0)
        status = start_status;
    finish("restart", job, status);
    return status;
}

// { status, sync }: sync asks the init script to register its triggers again,
// which a configuration change may have moved.
function reload(reason) {
    let skipped = { status: 0, sync: false };
    if (internal_change(reason))
        return skipped;
    if (!registered()) {
        exec.log("info", "LoKi is not running; reload skipped");
        warn("LoKi is not running; reload skipped\n");
        return skipped;
    }

    ui.refresh();
    let active = ui.active_action();
    if (reason == "pending" && active != "" && !tracked()) {
        lock.mark_request(ui.paths.pending_reload, reason);
        return skipped;
    }
    // A change to a runtime that is not running waits for the next start, or for
    // the action that is bringing it up.
    if (reason == CONFIG_CHANGE && !runtime_running()) {
        if (active != "")
            lock.mark_request(ui.paths.pending_reload, reason);
        return skipped;
    }

    let owner = common.own_pid();
    if (!lock.acquire(ui.paths.reload_lock, owner)) {
        lock.mark_request(ui.paths.pending_reload, reason || "reload_busy");
        return skipped;
    }

    let job = begin("reload");
    let status = lifecycle().reload(reason);
    finish("reload", job, status);
    lock.release(ui.paths.reload_lock, owner);
    if (ui.active_action() == "")
        lock.run_pending_reload_if_requested(ui.paths.pending_reload, SERVICE_INIT);
    return { status, sync: status == 0 && reason == CONFIG_CHANGE };
}

function status() {
    let running = runtime_running();
    print(running ? "running\n" : "not running\n");
    return running ? 0 : 1;
}

function retry_start(token) {
    token = token ?? start_request.token();
    if (!start_request.current(token))
        return 0;
    if (!start_request.enabled() || runtime_running())
        return start_request.cancel(token) ? 0 : 1;
    exec.log("info", "Retrying the failed LoKi start");
    return attempt(token, true);
}

function retry_token() {
    return start_request.enabled() ? start_request.token() : "";
}

function retry_monitor(token) {
    if (type(token) != "string" || match(token, /^[1-9][0-9]*-[0-9]+-[1-9][0-9]*$/) == null)
        return 1;
    let uloop = require("uloop");
    uloop.init();
    uloop.signal("SIGTERM", () => uloop.end());
    let connection = require("ubus").connect();
    if (connection == null)
        return 1;
    let status = 0;
    let timer;
    let retire = function() {
        if (!start_request.cancel(token))
            status = 1;
        // Each generation removes only its own instance, even after a new Start.
        connection.call("service", "delete", { name: "forkop", instance: "start-retry-" + token });
        if (connection.error() != null)
            status = 1;
        uloop.end();
    };
    let pending = () => start_request.current(token) && start_request.enabled();
    let step = function() {
        if (pending())
            retry_start(token);
        if (pending())
            timer.set(30000);
        else
            retire();
    };
    if (pending()) {
        timer = uloop.timer(30000, step);
        uloop.run();
    }
    else
        retire();
    connection.disconnect();
    return status;
}

function monitored(interface_name) {
    let values = settings();
    return common.option(values, "enable_badwan_interface_monitoring", "") == "1" &&
        index(common.words(common.option(values, "badwan_monitored_interfaces", "")), interface_name) >= 0;
}

function routing_restored() {
    return nft_state.table_present(constants.NFT_TABLE_NAME) && lifecycle().restore_routing();
}

function wan_up() {
    let token = start_request.token();
    if (!runtime_running() && !routing_restored())
        return retry_start(token);
    if (!start_request.cancel(token))
        return 1;
    if (!monitored("wan"))
        return 0;
    return exec.run([ SERVICE_INIT, "reload", INTERFACE_UP + "wan" ]);
}

// The procd triggers as the tab separated lines the init script turns into
// procd_add_*_trigger calls.
function triggers() {
    let values = settings();
    let lines = [
        "delay\t" + common.int_option(values, "badwan_reload_delay", "2000"),
        "config\tconfig.change\t" + CONFIG_NAME + "\t" + SERVICE_INIT + "\treload\t" + CONFIG_CHANGE,
        "interface\tinterface.*.up\twan\t" + SERVICE_INIT + "\thandle_wan_up\t"
    ];
    if (common.option(values, "enable_badwan_interface_monitoring", "") == "1")
        for (let name in common.words(common.option(values, "badwan_monitored_interfaces", "")))
            if (name != "wan")
                push(lines, "interface\tinterface.*.up\t" + name + "\t" + SERVICE_INIT + "\treload\t" + INTERFACE_UP + name);
    return join("\n", lines) + "\n";
}

return { paths, start, stop, restart, reload, status, retry_start, retry_token, retry_monitor, wan_up, triggers };
