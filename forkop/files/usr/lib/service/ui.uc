// An action is a job file under /var/run that its worker finishes; a job whose worker died is
// marked stale instead of running forever.

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let constants = require("core.constants");
let uci = require("core.uci");
let subscription_headers = require("singbox.subscription_headers");
let health = require("service.health");
let lock = require("service.lock");
let installer = require("service.installer");

const CONFIG_NAME = "forkop";
const FINISHED_TTL_SECONDS = 3600;
const ACKED_TTL_SECONDS = 15;
const STALE_GRACE_SECONDS = 15;
const STABLE_MIN_AGE = 2;
const ACTION_LOCK_OWNER_GRACE = 5;
const SERVICE_ACTIONS = { start: true, stop: true, restart: true, reload: true };

let paths = {
    service_actions: "/var/run/forkop/ui-state/service-actions",
    service_action_lock: "/var/run/forkop/ui-state/service-actions.lock",
    reload_lock: "/var/run/forkop.reload.lock",
    pending_reload: "/var/run/forkop/reload.pending",
    rc_dir: "/etc/rc.d"
};

function valid_job_id(id) {
    return type(id) == "string" && id != "." && id != ".." && match(id, /^[A-Za-z0-9._-]+$/) != null;
}

function job_path(dir, id) {
    return valid_job_id(id) ? dir + "/" + id + ".json" : null;
}

function read_job(path) {
    return common.read_json_file(path);
}

function write_job(path, value) {
    return common.write_file_atomic(path, sprintf("%J\n", value));
}

function valid_job(value) {
    return type(value) == "object" && (value.running === true || value.running === false);
}

function number(value) {
    return match(common.as_string(value), /^[0-9]+$/) ? int(value) : 0;
}

function remove_job(path) {
    let base = replace(path, /\.json$/, "");
    for (let file in [ path, base + ".out", base + ".out.json" ])
        fs.unlink(file);
}

// A job whose worker is gone is stale, unless it is young enough that its
// worker may not have recorded itself yet.
function refresh_job(path, stale_message) {
    let value = read_job(path);
    if (value?.running !== true || common.pid_alive(common.as_string(value.pid ?? "")))
        return;
    if (common.now_seconds() - number(value.started_at) < STALE_GRACE_SECONDS && number(value.started_at) > 0)
        return;
    write_job(path, { ...value, success: false, running: false, message: stale_message, exit_code: null, updated_at: common.now_seconds() });
}

// Finished jobs go once the page has acknowledged them or once they are old.
function clean_dir(dir) {
    let now = common.now_seconds();
    for (let path in fs.glob(dir + "/*.json")) {
        let value = read_job(path);
        if (!valid_job(value)) {
            remove_job(path);
            continue;
        }
        if (value.running)
            continue;
        let acked = value.acked_at != null && now - number(value.acked_at) >= ACKED_TTL_SECONDS;
        if (acked || now - (fs.stat(path)?.mtime ?? now) > FINISHED_TTL_SECONDS)
            remove_job(path);
    }
}

function refresh() {
    common.ensure_dir(paths.service_actions);
    clean_dir(paths.service_actions);
    for (let path in fs.glob(paths.service_actions + "/*.json"))
        refresh_job(path, "Service action worker exited unexpectedly");
}

function running_service_job() {
    for (let path in fs.glob(paths.service_actions + "/*.json")) {
        let value = read_job(path);
        if (value?.running === true && common.as_string(value.action) != "")
            return value;
    }
    return null;
}

function active_action() {
    return running_service_job()?.action ?? "";
}

function jobs(dir) {
    let result = [];
    for (let path in fs.glob(dir + "/*.json")) {
        let value = read_job(path);
        if (valid_job(value))
            push(result, { ...value, job_id: replace(fs.basename(path), /\.json$/, "") });
    }
    return result;
}

// A section is enabled unless explicitly switched off.
function capabilities() {
    let enabled = (type_name, fallback) =>
        length(filter(uci.section_objects(CONFIG_NAME, type_name), (s) => common.bool_option(s, "enabled", fallback)));
    return {
        sections_enabled_count: enabled("section", true)
    };
}

function default_headers() {
    return subscription_headers.default_header_lines();
}

// status is what the service is and busy what is being done to it. Elapsed seconds, not a start
// time: a router without an RTC disagrees with the browser about the time.
function current_state() {
    refresh();
    let executable = (path) => ((fs.stat(path)?.mode ?? 0) & 0111) != 0;
    let forkop_running = health.forkop_stably_running(constants.RT_TABLE_NAME, constants.NFT_TABLE_NAME, constants.NFT_FAKEIP_MARK, STABLE_MIN_AGE) ? 1 : 0;
    let forkop_enabled = executable(paths.rc_dir + "/S" + constants.FORKOP_START_PRIORITY + "forkop") ? 1 : 0;
    let sing_box_running = forkop_running || health.sing_box_service_stable(STABLE_MIN_AGE) ? 1 : 0;
    let sing_box_enabled = executable(paths.rc_dir + "/S99sing-box") ? 1 : 0;
    let job = running_service_job();
    // install.sh stops Forkop and replaces its packages: no action of the page runs meanwhile
    let busy = installer.active() ? "install" : job == null ? null : (job.action == "reload" ? "apply" : job.action);

    return {
        service: {
            forkop: {
                running: forkop_running,
                enabled: forkop_enabled,
                status: health.service_status_text(forkop_running, forkop_enabled),
                busy
            },
            sing_box: {
                running: sing_box_running,
                enabled: sing_box_enabled,
                status: health.service_status_text(sing_box_running, sing_box_enabled)
            }
        },
        capabilities: capabilities(),
        actions: { service: jobs(paths.service_actions) }
    };
}

// A new job for an action, unless one is running already: { status, job_id },
// with status 2 while another action or the installer runs.
function begin(action, source, pid) {
    if (!SERVICE_ACTIONS[action])
        return { status: 1, job_id: "" };
    if (installer.active())
        return { status: 2, job_id: "" };
    let owner = common.own_pid();
    if (!lock.acquire(paths.service_action_lock, owner, ACTION_LOCK_OWNER_GRACE))
        return { status: 2, job_id: "" };

    let result = { status: 2, job_id: "" };
    refresh();
    if (active_action() == "") {
        let now = clock();
        let id = sprintf("%d-%d", now[0], now[1]);
        let written = write_job(job_path(paths.service_actions, id), {
            success: true,
            running: true,
            kind: "service",
            action,
            source,
            message: "Service action is running",
            pid: match(common.as_string(pid), /^[0-9]+$/) ? common.as_string(pid) : null,
            started_at: common.now_seconds(),
            updated_at: null,
            exit_code: null
        });
        result = written ? { status: 0, job_id: id } : { status: 1, job_id: "" };
    }
    lock.release(paths.service_action_lock, owner);
    return result;
}

function finish_job(path, success, message, exit_code) {
    let value = read_job(path) ?? {};
    return write_job(path, { ...value, success, running: false, message, exit_code, updated_at: common.now_seconds() });
}

// A background worker running the init script for an action: { success, job_id }.
function start_worker(action, source, reason) {
    let begun = begin(action, source, null);
    if (begun.status != 0)
        return { success: false, job_id: "" };

    let path = job_path(paths.service_actions, begun.job_id);
    let pid = trim(exec.output([ "sh", "-c", "\"$@\" >/dev/null 2>&1 1000>&- & echo $!", "sh",
        constants.FORKOP_BIN, "service_action_worker", action, begun.job_id, reason ?? "" ]) ?? "");
    let value = read_job(path);
    if (match(pid, /^[0-9]+$/) && value?.running === true && write_job(path, { ...value, pid }))
        return { success: true, job_id: begun.job_id };

    if (match(pid, /^[0-9]+$/))
        exec.ok([ "kill", pid ]);
    finish_job(path, false, "Failed to write service action worker pid", 1);
    return { success: false, job_id: begun.job_id };
}

// A reload queued while an action ran goes next, as a job of its own - unless
// another reload owns the reload lock, which applies the request itself when it
// finishes.
function run_pending_reload(action, success) {
    if (!success || (action != "start" && action != "restart" && action != "reload"))
        return;
    if (lock.held(paths.reload_lock) || !lock.consume_request(paths.pending_reload))
        return;
    if (!start_worker("reload", "initd", "pending").success)
        lock.mark_request(paths.pending_reload, "pending");
}

// The init script's exit status is the answer: a start holds the lifecycle lock
// until the runtime is ready, a stop until sing-box is gone.
function finish(action, job_id, status) {
    let path = job_path(paths.service_actions, job_id);
    if (path == null || fs.stat(path) == null)
        return;
    let success = status == 0;
    if (finish_job(path, success, "Service " + action + (success ? " completed" : " failed"), status))
        run_pending_reload(action, success);
}

// The init script runs it, because only its start registers the service with procd.
function worker(action, job_id, reason) {
    let argv = [ "env", "FORKOP_UI_ACTION_TRACKED=1", constants.FORKOP_SERVICE_INIT, action ];
    if (reason != null && reason != "")
        push(argv, reason);
    finish(action, job_id, exec.status(argv));
}

function response(success, job_id, message) {
    return { success, job_id: job_id ?? "", message };
}

function start_action(action) {
    if (!SERVICE_ACTIONS[action])
        return response(false, "", "Invalid service action");
    let started = start_worker(action, "ui", "");
    if (started.success)
        return response(true, started.job_id, "Service " + action + " started");
    if (installer.active())
        return response(false, "", "The installer is running");
    return response(false, "", active_action() != "" ? "Another service action is already running" : "Failed to write service action worker pid");
}

function acknowledge(job_id) {
    let path = job_path(paths.service_actions, job_id);
    if (path == null)
        return response(false, "", "Invalid UI action job id");
    let value = read_job(path);
    if (fs.stat(path) == null)
        return response(true, job_id, "UI action already acknowledged");
    if (value?.running === true)
        return response(false, job_id, "UI action is still running");
    if (!write_job(path, value?.running === false ? { ...value, acked_at: common.now_seconds() } : (value ?? {})))
        return response(false, job_id, "Failed to acknowledge UI action");
    return response(true, job_id, "UI action acknowledged");
}

return {
    paths,
    refresh,
    current_state,
    current_ui_state: current_state,
    default_headers,
    active_action,
    begin,
    finish,
    worker,
    start_action,
    acknowledge
};
