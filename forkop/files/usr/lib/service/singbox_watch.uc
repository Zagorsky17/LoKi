// Follows sing-box through procd's respawns: the capture pauses meanwhile, and once procd gives
// up the runtime is taken down, so nothing steers traffic at a dead proxy.

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let constants = require("core.constants");
let library = require("core.library");
let worker = require("service.worker");
let health = require("service.health");

let paths = {
    pid: "/var/run/forkop/sing-box-watch.pid",
    // Kept until the cleanup has run, so a watcher that died halfway finishes it after a respawn.
    pending_cleanup: "/var/run/forkop/sing-box-watch.cleanup"
};

function spec() {
    return {
        name: "forkop-singbox-watch",
        instance: "watch",
        command: [ constants.FORKOP_BIN, "sing_box_watch" ],
        env: { FORKOP_LIB: library.dir() },
        pid_file: paths.pid
    };
}

// procd's stop notification carries no pid, so the watcher keeps the one it saw running.
function crash_step(event, core_pid) {
    if (event?.data?.service != "sing-box")
        return null;
    if (event.type == "instance.stop")
        return [ "sing_box_crash_pause", "" + core_pid ];
    if (event.type == "instance.start")
        return [ "sing_box_crash_resume" ];
    return null;
}

function should_cleanup(event) {
    return event?.type == "instance.fail" && event?.data?.service == "sing-box";
}

// Separate crash loops differ by pid; the same notification delivered twice does not.
function cleanup_event_key(event) {
    let data = event?.data ?? {};
    return join("|", map([ data.service, data.instance, data.pid, data.exit_code, data.respawn_count ], common.as_string));
}

// A sing-box that procd stopped respawning while no watcher was listening.
function failed_exit_code(services) {
    for (let name, instance in services?.["sing-box"]?.instances ?? {})
        if (instance?.running === false && instance.respawn == null && instance.exit_code != null)
            return common.as_string(instance.exit_code);
    return null;
}

function cleanup(exit_code) {
    return common.write_file(paths.pending_cleanup, exit_code + "\n") &&
        exec.ok([ constants.FORKOP_BIN, "sing_box_crash_cleanup", exit_code ]);
}

// Exits non-zero when a cleanup failed, so procd respawns it to try again.
function monitor() {
    let uloop = require("uloop");
    let me = spec();
    uloop.init();
    // libubox's own handler loses a SIGTERM that arrives before uloop.run().
    uloop.signal("SIGTERM", () => uloop.end());
    let connection = require("ubus").connect();
    if (connection == null)
        return 1;

    let services = () => connection.call("service", "list", { name: "sing-box" });
    let status = 0;
    let last_event = "";
    let core_pid = 0;
    let subscriber = connection.subscriber(function(notification) {
        let event = { type: notification.type, data: notification.data };
        if (event.type == "instance.start" && event.data?.service == "sing-box")
            core_pid = health.sing_box_service_pid_from_value(services());
        let step = crash_step(event, core_pid);
        if (step != null)
            exec.ok([ constants.FORKOP_BIN, ...step ]);
        if (!should_cleanup(event) || cleanup_event_key(event) == last_event)
            return;
        last_event = cleanup_event_key(event);
        if (!cleanup(common.as_string(event.data.exit_code))) {
            status = 1;
            uloop.end();
        }
    }, function(id) {});
    if (subscriber == null || !subscriber.subscribe("service") || !worker.announce(me))
        return 1;

    let state = services();
    core_pid = health.sing_box_service_pid_from_value(state);
    let pending = fs.readfile(paths.pending_cleanup);
    let exit_code = pending != null ? trim(pending) : failed_exit_code(state);
    if (exit_code != null && !cleanup(exit_code)) {
        worker.retire(me);
        return 1;
    }

    uloop.run();
    worker.retire(me);
    return status;
}

function start_worker() {
    return worker.start(spec());
}

function worker_current() {
    return worker.current(spec());
}

function stop_worker() {
    if (!worker.stop(spec()))
        return false;
    fs.unlink(paths.pending_cleanup);
    return true;
}

return { paths, spec, should_cleanup, cleanup_event_key, failed_exit_code, monitor, start_worker, worker_current, stop_worker };
