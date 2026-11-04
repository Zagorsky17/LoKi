// Test doubles for what the backend reaches outside ucode: shell commands, the
// environment, printed output and exit().

let fs = require("fs");

let real = {
    system: global.system,
    popen: fs.popen,
    getenv: global.getenv,
    exit: global.exit,
    clock: global.clock,
    print: global.print,
    warn: global.warn
};

// Splits a command line the way /bin/sh would for the quoting the backend
// produces, and drops redirections, so a fake sees the argv that was meant.
function split_shell(command) {
    let argv = [];
    let current = null;
    let i = 0;
    let n = length(command);

    while (i < n) {
        let c = substr(command, i, 1);
        if (c == " " || c == "\t" || c == "\n") {
            if (current != null)
                push(argv, current);
            current = null;
            i++;
            continue;
        }
        if (c == "'") {
            let end = index(substr(command, i + 1), "'");
            if (end < 0)
                die("unterminated quote in: " + command);
            current = (current ?? "") + substr(command, i + 1, end);
            i += end + 2;
            continue;
        }
        if (c == "\\" && i + 1 < n) {
            current = (current ?? "") + substr(command, i + 1, 1);
            i += 2;
            continue;
        }
        current = (current ?? "") + c;
        i++;
    }
    if (current != null)
        push(argv, current);

    let result = [];
    for (let arg in argv) {
        if (match(arg, /^[0-9]*[<>]/) || arg == "&" || arg == "&&" || arg == "||" || arg == ";")
            continue;
        push(result, arg);
    }
    return result;
}

let state = null;

function reply_for(command, argv) {
    for (let handler in state.handlers) {
        let pattern = handler[0];
        let hit = type(pattern) == "function" ? pattern(argv, command)
            : type(pattern) == "regexp" ? match(command, pattern) != null
            : join(" ", argv) == pattern || substr(join(" ", argv), 0, length(pattern) + 1) == pattern + " ";
        if (!hit)
            continue;

        let reply = handler[1];
        if (type(reply) == "function")
            reply = reply(argv, command);
        return reply ?? {};
    }

    die("unexpected command: " + command);
}

function record(command) {
    let argv = split_shell(command);
    let entry = { command, argv, stdin: "" };
    push(state.calls, entry);
    return entry;
}

// Each handler is [ match, reply ]: match is an argv prefix as one string, a regexp over the
// command line or a function of (argv, command); reply is { status, stdout } or a function
// returning one. A command no handler claims fails the test.
function commands(handlers) {
    state = { handlers: handlers ?? [], calls: [] };

    global.system = function(command) {
        let entry = record("" + command);
        let reply = reply_for(entry.command, entry.argv);
        return reply.status ?? 0;
    };

    fs.popen = function(command, mode) {
        let entry = record("" + command);
        let reply = reply_for(entry.command, entry.argv);
        let stdout = reply.stdout ?? "";
        let consumed = false;
        return {
            read: function(amount) {
                if (consumed)
                    return "";
                consumed = true;
                return stdout;
            },
            write: function(data) {
                entry.stdin += data;
                return length(data);
            },
            close: function() {
                return reply.status ?? 0;
            }
        };
    };

    return state;
}

function calls() {
    return state == null ? [] : state.calls;
}

// A handler that keeps the "[level] message" of every line Loki logs.
function logger(lines) {
    return [ "logger", (argv) => { push(lines, argv[length(argv) - 1]); return { status: 0 }; } ];
}

// Every recorded argv joined with spaces, which is what most assertions read.
function command_lines() {
    let result = [];
    for (let entry in calls())
        push(result, join(" ", entry.argv));
    return result;
}

function env(values) {
    global.getenv = function(name) {
        if (name == null)
            return real.getenv();
        return exists(values, name) ? values[name] : real.getenv(name);
    };
}

// What fn printed, with print() and warn() captured separately.
function capture(fn) {
    let out = "";
    let err = "";
    global.print = function(...args) {
        for (let arg in args)
            out += (type(arg) == "string" ? arg : sprintf("%s", arg));
    };
    global.warn = function(...args) {
        for (let arg in args)
            err += (type(arg) == "string" ? arg : sprintf("%s", arg));
    };
    let result;
    let failure = null;
    try {
        result = fn();
    }
    catch (e) {
        failure = e;
    }
    global.print = real.print;
    global.warn = real.warn;
    if (failure != null)
        die(failure.message);
    return { result, stdout: out, stderr: err };
}

// A clock standing at `seconds`, for checks against a time window: a VM can step its wall
// clock backwards mid-test.
function clock(seconds) {
    let ticks = 0;
    global.clock = function() {
        return [ seconds, ticks++ ];
    };
}

// A new instance of a module, for one whose load-time state a test changed.
function fresh(name) {
    delete global.modules[name];
    return require(name);
}

function restore() {
    global.system = real.system;
    fs.popen = real.popen;
    global.getenv = real.getenv;
    global.exit = real.exit;
    global.clock = real.clock;
    global.print = real.print;
    global.warn = real.warn;
    state = null;
}

// A fresh directory under the runner's scratch root.
let tmp_counter = 0;
function tmpdir() {
    let root = real.getenv("LOKI_TEST_TMP") || "/tmp";
    let now = real.clock();
    let path = sprintf("%s/loki-unit.%d.%d.%d", root, now[0], now[1], ++tmp_counter);
    real.system("mkdir -p '" + path + "'");
    return path;
}

return { split_shell, commands, calls, logger, command_lines, env, clock, capture, fresh, restore, tmpdir, real };
