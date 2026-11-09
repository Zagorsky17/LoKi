// A stand-in for the ucode uloop module: nothing runs on its own, a test fires
// the recorded timers and intervals itself.

let timers = [];
let running = false;
let on_run = null;
let signals = {};
let pending_signals = [];
let processes = [];

function schedule(kind, ms, callback) {
    let entry = { kind, ms, callback, cancelled: false };
    push(timers, entry);
    return {
        cancel: function() { entry.cancelled = true; return true; },
        set: function(next_ms) { entry.ms = next_ms; entry.cancelled = false; return true; },
        remaining: function() { return entry.ms; }
    };
}

function __fire(kind) {
    let fired = 0;
    for (let entry in timers) {
        if (entry.cancelled || (kind != null && entry.kind != kind))
            continue;
        if (entry.kind == "timer")
            entry.cancelled = true;
        entry.callback();
        fired++;
    }
    return fired;
}

// A handler registered with signal() runs in the loop, at once or as soon as it starts; without
// one, libubox's own handler ends a running loop, and a loop started later never hears of it.
function __raise(name) {
    if (signals[name] == null) {
        running = false;
        return;
    }
    if (running)
        signals[name]();
    else
        push(pending_signals, name);
}

// A process is recorded, never started; a test ends it with __exit and its callback runs.
function process(executable, args, env, callback) {
    let entry = { executable, args, env, callback, pid: 40000 + length(processes), exited: false };
    push(processes, entry);
    return {
        pid: function() { return entry.pid; },
        delete: function() { return true; }
    };
}

function __exit(index, code) {
    let entry = processes[index];
    entry.exited = true;
    entry.callback(code);
}

function __reset() {
    timers = [];
    running = false;
    on_run = null;
    signals = {};
    pending_signals = [];
    processes = [];
}

// What happens while the loop runs; run() returns once it is done.
function __on_run(fn) {
    on_run = fn;
}

return {
    init: function() { return true; },
    run: function() {
        running = true;
        let queued = pending_signals;
        pending_signals = [];
        for (let name in queued)
            signals[name]();
        if (running && on_run != null)
            on_run();
        running = false;
        return 0;
    },
    end: function() { running = false; return true; },
    running: function() { return running; },
    timer: function(ms, callback) { return schedule("timer", ms, callback); },
    interval: function(ms, callback) { return schedule("interval", ms, callback); },
    signal: function(name, callback) { signals[name] = callback; return true; },
    process,
    __fire,
    __raise,
    __reset,
    __on_run,
    __exit,
    __timers: function() { return timers; },
    __processes: function() { return processes; }
};
