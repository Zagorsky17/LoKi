#!/usr/bin/env ucode

// The service state, served from a resident process, so a status refresh costs no interpreter
// start. It is recomputed when something could have changed: procd service events over ubus,
// the mtimes of the action directories, the reload lock and the autostart link, once a second
// while an action runs, and a slow sweep for what nothing announces.
//
// state_wait parks a request until the state or the log moves past what the caller has seen.
// A page parks one request: a browser keeps six connections to a host, and every other LuCI
// request queues behind parked ones.

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let constants = require("core.constants");
let ui = require("service.ui");
let installer = require("service.installer");
let uci = require("core.uci");
let health = require("service.health");
let features = require("singbox.features");

const OBJECT_NAME = getenv("LOKI_STATE_SERVICE_OBJECT") || "loki";

const WATCH_INTERVAL_MS = 500;
const BUSY_REFRESH_MS = 1000;
// The runtime keeps settling after an action finishes (loki-core age, nft table, routing), and
// nothing stats that, so it is watched closely for a while after every change.
const SETTLE_MS = 10000;
const SWEEP_INTERVAL_MS = 20000;
// Inside uhttpd's network timeout and LuCI's own request ceiling.
const MAX_WAIT_MS = 15000;
// loki-core closes and reopens its inbounds on a reload and a respawn, so a running service is
// reported stopped only once the flip outlasts this while its process exists. A stop, or a
// crash procd gave up on, removes the process and shows at once.
const DOWN_GRACE_MS = 15000;

const LOG_PATTERN = constants.LOKI_LOG_PATTERN;
// Deep enough that a poll cannot miss lines between two reads on a busy router.
const LOG_TAIL_LINES = 200;
const LOG_BUFFER_LINES = 400;
const LOG_POLL_MS = 1500;
// Log polling stops when nobody has asked for a while.
const LOG_INTEREST_MS = 60000;

let paths = {
    config: "/etc/config/loki",
    // Both package managers record installs and removals in these files; watching them is a stat,
    // reading the versions a CLI run.
    package_databases: [ "/usr/lib/opkg/status", "/lib/apk/db/installed" ],
    // The rpcd ACL lets the page upload a configuration here and nowhere else.
    import_file: "/tmp/loki-import.conf",
    import_answer: "/tmp/loki-import.answer"
};

const IMPORT_FAILED = { success: false, reason: "failed", detail: "The import command gave no answer" };
let import_runs = 0;

function path_signature(path) {
    let stat = fs.stat(path);
    if (stat == null)
        return "-";
    return stat.inode + ":" + stat.ctime + ":" + stat.mtime + ":" + stat.size;
}

// Everything that can change the state without this process being told, compared by a few
// stat calls.
function watch_signature() {
    return path_signature(paths.config) + "|" +
        path_signature(ui.paths.service_actions) + "|" +
        path_signature(ui.paths.reload_lock) + "|" +
        path_signature(installer.paths.state) + "|" +
        path_signature(ui.paths.rc_dir + "/S" + constants.LOKI_START_PRIORITY + "loki");
}

let state = { revision: 0, payload: null, text: "" };
let system_info = { value: null, signature: "" };
let log_lines = [];
let log_cursor = 0;
let last_log_interest_ms = 0;
let last_log_poll_ms = 0;
let waiters = [];
let last_watch = "";
let last_config = "";
let last_sweep_ms = 0;
let last_busy_refresh_ms = 0;
let settle_until_ms = 0;
let down_since_ms = 0;

function read_log_tail() {
    let data = exec.output([ "logread", "-l", LOG_TAIL_LINES, "-e", LOG_PATTERN ]);
    return filter(split(data ?? "", "\n"), (line) => line != "");
}

// Matching the last known line rather than counting survives unrelated entries between two
// reads; if it scrolled past, the whole tail is new.
function new_log_lines(tail) {
    if (length(log_lines) == 0)
        return tail;

    let last = log_lines[length(log_lines) - 1].line;
    for (let i = length(tail) - 1; i >= 0; i--)
        if (tail[i] == last)
            return slice(tail, i + 1);

    return tail;
}

function append_log_lines(lines) {
    if (length(lines) == 0)
        return false;

    for (let line in lines)
        push(log_lines, { cursor: ++log_cursor, line });

    if (length(log_lines) > LOG_BUFFER_LINES)
        log_lines = slice(log_lines, length(log_lines) - LOG_BUFFER_LINES);

    return true;
}

function log_reply(cursor) {
    cursor = int(cursor || 0);
    let lines = [];
    let redact = require("service.gateway_secret").redactor();

    for (let entry in log_lines)
        if (entry.cursor > cursor)
            push(lines, redact(entry.line));

    return { cursor: log_cursor, lines };
}

function reply_payload() {
    let payload = state.payload == null ? {} : state.payload;
    return {
        revision: state.revision,
        service: payload.service,
        capabilities: payload.capabilities,
        actions: payload.actions
    };
}

// A caller that sends no cursor waits for the state alone.
function follows_log(waiter) {
    return waiter.cursor != null;
}

function wait_reply(waiter) {
    let reply = reply_payload();
    if (follows_log(waiter)) {
        let log = log_reply(waiter.cursor);
        reply.cursor = log.cursor;
        reply.lines = log.lines;
    }
    return reply;
}

function answer_waiters(pending) {
    for (let waiter in pending) {
        try {
            waiter.request.reply(wait_reply(waiter));
        }
        catch (e) {
        }
    }
}

function wake_waiters() {
    let pending = waiters;
    waiters = [];
    answer_waiters(pending);
}

// A new line answers only the requests that asked for the log.
function wake_log_waiters() {
    let pending = filter(waiters, follows_log);
    waiters = filter(waiters, (waiter) => !follows_log(waiter));
    answer_waiters(pending);
}

// The interval is the log's clock and reads on every tick; a request reads only
// when the last read is older than an interval.
function poll_log(force) {
    let now = common.monotonic_ms();
    if (!force && now - last_log_poll_ms < LOG_POLL_MS)
        return false;

    last_log_poll_ms = now;
    if (!append_log_lines(new_log_lines(read_log_tail())))
        return false;

    wake_log_waiters();
    return true;
}

function log_interest() {
    last_log_interest_ms = common.monotonic_ms();
}

function log_is_watched() {
    return length(filter(waiters, follows_log)) > 0 ||
        common.monotonic_ms() - last_log_interest_ms < LOG_INTEREST_MS;
}

function package_db_signature() {
    let signature = path_signature(paths.config) + "|";
    for (let path in paths.package_databases)
        signature += path_signature(path) + "|";
    return signature;
}

// Through the CLI: requiring diagnostics/runtime.uc would keep its whole require chain in this
// process for a question asked once per package change.
function read_system_info() {
    let value = common.parse_json(exec.output([ constants.LOKI_BIN, "get_system_info" ]));
    return type(value) == "object" ? value : null;
}

// An answer read while an install is still writing the database is stamped
// with the database as it was, so the next change reads it again.
function refresh_system_info() {
    let signature = package_db_signature();
    if (system_info.value != null && signature == system_info.signature)
        return false;

    let value = read_system_info();
    if (value == null)
        return false;

    system_info = { value, signature };
    return true;
}

function needs_close_refresh(now, busy, deadline, last_refresh) {
    now = int(now);
    if (!busy && now >= int(deadline || 0))
        return false;
    return now - int(last_refresh || 0) >= BUSY_REFRESH_MS;
}

function state_is_busy() {
    let payload = state.payload;
    return payload != null && payload.service.loki.busy != null;
}

// Pure, so the grace can be tested without a clock: the caller owns down_since and passes it back.
function settled_running(observed_running, process_alive, prev_running, down_since, now_ms, grace_ms) {
    if (observed_running)
        return { running: true, down_since_ms: 0 };
    if (!process_alive || !prev_running)
        return { running: false, down_since_ms: 0 };
    if (int(down_since || 0) == 0)
        return { running: true, down_since_ms: int(now_ms) };
    if (int(now_ms) - int(down_since) >= int(grace_ms))
        return { running: false, down_since_ms: int(down_since) };
    return { running: true, down_since_ms: int(down_since) };
}

// While the grace holds a flip back, the running-derived fields follow the held value.
function apply_settled_running(payload) {
    let loki = payload.service.loki;
    let previous = state.payload;
    let prev_running = previous != null && previous.service.loki.running == 1;

    let settled = settled_running(
        loki.running == 1,
        health.sing_box_service_running(),
        prev_running,
        down_since_ms,
        common.monotonic_ms(),
        DOWN_GRACE_MS
    );
    down_since_ms = settled.down_since_ms;

    if (!settled.running || loki.running == 1)
        return;

    loki.running = 1;
    loki.status = health.service_status_text(1, loki.enabled);
    // Held only while the process exists, so the loki-core row agrees.
    payload.service.sing_box.running = 1;
    payload.service.sing_box.status = health.service_status_text(1, payload.service.sing_box.enabled);
}

// A changed configuration is read again rather than answered from memory.
function reread_changed_config() {
    let config = path_signature(paths.config);
    if (config != last_config) {
        last_config = config;
        uci.reset();
    }
}

// The revision moves only when the answer does, so a parked request stays parked.
function recompute() {
    reread_changed_config();

    let payload = ui.current_ui_state();
    // Read from the binary once, and again only once it changes.
    payload.capabilities.core = features.report();
    apply_settled_running(payload);
    let text = sprintf("%J", payload);
    if (text == state.text)
        return false;

    state = { revision: state.revision + 1, payload, text };
    // Every change restarts the settle window.
    settle_until_ms = common.monotonic_ms() + SETTLE_MS;
    wake_waiters();
    return true;
}

function tick() {
    let now = common.monotonic_ms();
    let signature = watch_signature();
    let due_sweep = now - last_sweep_ms >= SWEEP_INTERVAL_MS;
    // A pending down-flip needs the close cadence too, so the grace expires on a look rather than
    // on the next slow sweep.
    let due_close = needs_close_refresh(now, state_is_busy() || down_since_ms != 0, settle_until_ms, last_busy_refresh_ms);

    if (signature == last_watch && !due_sweep && !due_close)
        return;

    last_watch = signature;
    if (due_sweep)
        last_sweep_ms = now;
    if (due_close)
        last_busy_refresh_ms = now;

    recompute();

    if (due_sweep)
        refresh_system_info();
}

function log_tick() {
    if (log_is_watched())
        poll_log(true);
}

function cleanup_import() {
    let path = paths.import_file;
    let node = fs.lstat(path);
    return node == null ? require("service.lock").unmarked(path) :
        node.type == "file" && node.uid == fs.stat("/proc/self").uid && node.nlink == 1 && fs.unlink(path) === true;
}

function object_methods() {
    return {
        rpc_read: {
            call: (request) => require("service.rpc").invoke(request, "rpc_read"),
            args: { argv: [], request_id: "", ubus_rpc_session: "" }
        },
        rpc_write: {
            call: (request) => require("service.rpc").invoke(request, "rpc_write"),
            args: { argv: [], request_id: "", ubus_rpc_session: "" }
        },
        rpc_read_prepare: {
            call: (request) => require("service.rpc").prepare(request, "rpc_read"),
            args: { argv: [], ubus_rpc_session: "" }
        },
        rpc_write_prepare: {
            call: (request) => require("service.rpc").prepare(request, "rpc_write"),
            args: { argv: [], ubus_rpc_session: "" }
        },
        rpc_read_result: {
            call: (request) => require("service.rpc").result(request, "rpc_read"),
            args: { id: "", part: "", offset: 0, ubus_rpc_session: "" }
        },
        rpc_write_result: {
            call: (request) => require("service.rpc").result(request, "rpc_write"),
            args: { id: "", part: "", offset: 0, ubus_rpc_session: "" }
        },
        state: {
            call: function(request) {
                return reply_payload();
            },
            args: { ubus_rpc_session: "" }
        },
        // Held until the state moves past the caller's revision, a line arrives past its log cursor,
        // or the ceiling. A cursor from before this process started gets the current one back.
        state_wait: {
            call: function(request) {
                let waiter = { request, cursor: null };
                if (request.args.cursor != null) {
                    log_interest();
                    waiter.cursor = int(request.args.cursor);
                }

                if (state.payload == null || state.revision != int(request.args.revision || 0) ||
                    (follows_log(waiter) && waiter.cursor != log_cursor))
                    return wait_reply(waiter);

                request.defer();
                push(waiters, waiter);
                return null;
            },
            args: { revision: 0, cursor: 0, ubus_rpc_session: "" }
        },
        // A command of its own checks or stages the upload, keeping the migrations out of this process;
        // the caller's LuCI session goes in its environment, as any process can read a command line.
        import_config: {
            call: function(request) {
                if (request.args.cleanup === true) {
                    return { success: cleanup_import() };
                }
                let directory = paths.import_answer + "." + ++import_runs;
                if (!fs.mkdir(directory, 0700)) return IMPORT_FAILED;
                let answer = directory + "/answer";
                let finish = (reply) => {
                    fs.unlink(answer);
                    fs.rmdir(directory);
                    cleanup_import();
                    request.reply(reply);
                };
                request.defer();
                let child = require("uloop").process("/bin/sh", [ "-c", "umask 077; set -C; ulimit -f 2048; exec \"$@\" > \"$0\"", answer,
                    constants.LOKI_BIN, request.args.stage ? "import_config" : "import_config_check", paths.import_file ],
                    { ...getenv(), LOKI_RPC_SESSION: request.args.ubus_rpc_session ?? "" },
                    () => finish(common.read_json_file(answer) ?? IMPORT_FAILED));
                if (child == null)
                    finish(IMPORT_FAILED);
                return null;
            },
            args: { stage: false, cleanup: false, ubus_rpc_session: "" }
        },
        // Where the log stands now, for a page to wait from.
        logs: {
            call: function(request) {
                log_interest();
                poll_log(false);
                return { cursor: log_cursor };
            },
            args: { ubus_rpc_session: "" }
        },
        // The whole log the Logs tab shows, read again only once a line arrived past the caller's
        // cursor: the tab asks every two seconds, and the read is what costs. Through a file, as a
        // log longer than a pipe holds would be cut by logread's exit.
        log_text: {
            call: function(request) {
                log_interest();
                poll_log(false);
                if (request.args.cursor != null && int(request.args.cursor) == log_cursor)
                    return { cursor: log_cursor, unchanged: true };
                let read = exec.capture_parallel([ [ "logread", "-e", LOG_PATTERN ] ])[0];
                return { cursor: log_cursor, text: require("service.gateway_secret").redactor()(read.status == 0 ? read.stdout : "") };
            },
            args: { cursor: 0, ubus_rpc_session: "" }
        },
        // Installed versions and the device, held until the installed packages change.
        system_info: {
            call: function(request) {
                refresh_system_info();
                return system_info.value == null
                    ? { available: false }
                    : { available: true, system_info: system_info.value };
            },
            args: { ubus_rpc_session: "" }
        },
        // The configuration the service runs from: rpcd lays a LuCI session's unsaved changes over
        // every uci read the page makes, and the core was never given them.
        config: {
            call: function(request) {
                reread_changed_config();
                return { sections: require("service.rpc").public_sections(uci.section_objects(constants.LOKI_CONFIG_NAME)) };
            },
            args: { ubus_rpc_session: "" }
        },
        config_private: {
            call: function(request) {
                reread_changed_config();
                return { sections: uci.section_objects(constants.LOKI_CONFIG_NAME) };
            },
            args: { ubus_rpc_session: "" }
        },
        // What the core costs the router now and how long it has run.
        usage: {
            call: function(request) {
                return health.sing_box_usage();
            },
            args: { ubus_rpc_session: "" }
        },
        // For a caller that has just changed something and does not want to wait
        // for the watch to notice - an apply.
        refresh: {
            call: function(request) {
                recompute();
                refresh_system_info();
                return reply_payload();
            },
            args: { ubus_rpc_session: "" }
        }
    };
}

function run() {
    let ubus = require("ubus");
    let uloop = require("uloop");

    uloop.init();
    // libubox's SIGTERM handler only raises a flag uloop.run() clears, so a stop arriving before
    // the loop runs would be lost and procd would kill the service; this handler is queued.
    uloop.signal("SIGTERM", () => uloop.end());

    let connection = ubus.connect();
    if (connection == null) {
        exec.log("error", "The state service could not connect to ubus");
        return 1;
    }

    if (connection.publish(OBJECT_NAME, object_methods()) == null) {
        exec.log("error", "The state service could not publish the ubus object " + OBJECT_NAME);
        return 1;
    }

    // procd reports loki-core starting and stopping, which no mtime reflects; other services are ignored.
    let subscriber = connection.subscriber(function(notification) {
        if (notification.data?.service == "loki-core")
            recompute();
    }, function(id) {});
    if (subscriber != null)
        subscriber.subscribe("service");

    recompute();
    last_sweep_ms = common.monotonic_ms();
    refresh_system_info();

    uloop.interval(WATCH_INTERVAL_MS, function() {
        tick();
    });

    uloop.interval(LOG_POLL_MS, function() {
        log_tick();
    });

    // Enforced here, inside what the transport in front of a parked request will wait for.
    uloop.interval(MAX_WAIT_MS, function() {
        wake_waiters();
    });

    uloop.run();
    require("service.rpc").shutdown();
    return 0;
}

if ((sourcepath(1) != null && sourcepath(1) != "") || ARGV[0] == null)
    return {
        MAX_WAIT_MS,
        LOG_POLL_MS,
        paths,
        needs_close_refresh,
        settled_running,
        new_log_lines,
        remember_log_line: function(line) { append_log_lines([ line ]); },
        object_methods,
        run
    };

let mode = ARGV[0] || "";

if (mode == "run")
    exit(run());

warn("Usage: service/state_service.uc run\n");
exit(1);
