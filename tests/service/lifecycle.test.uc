// The lifecycle against a model of the router: loki-core, the nft table and the
// workers are state the fakes change, and every action is judged by the order of
// what it did.

let t = require("t");
let stub = require("stub");
let fs = require("fs");
let repo = require("repo");
let validator = require("config.validator");
let generator = require("singbox.generator");
let runtime = require("singbox.runtime");
let real_prepare_config = runtime.prepare_config;
let nft = require("nft.apply");
let nft_state = require("nft.state");
let rulesets = require("nft.ruleset_sync");
let health = require("service.health");
let watch = require("service.singbox_watch");
let migration = require("config.migration");
let fixture = require("fixture");
let lifecycle = require("service.lifecycle");
let start_request = require("service.start_request");
let lock = require("service.lock");
let context = require("service.ruleset_context");
let credential = require("service.gateway_secret");
let generation = 100;
let digest = sprintf("%064x", 90);
credential.generate = () => sprintf("%064x", ++generation);

let world = null;
let real_sleep = global.sleep;

const CHANGED_TABLE = "table inet loki\nadd rule inet loki mangle jump x\n";
const NOTHING_TO_RUN = "[warn] LoKi has nothing to run: no section with connections is enabled. Set up a section, then start LoKi";

function event(name) {
    push(world.events, name);
}

function seed_ready() {
    let active = { generation: sprintf("%064x", ++generation), sections: [],
        config_path: world.dir + "/core-config.json", config_digest: digest, nft_digest: digest,
        controller: { endpoint: "/tmp/loki/controller.sock", secret: digest } };
    t.ok(context.write({ schema: 1, phase: "applying", active: null, candidate: active }));
    t.ok(context.write({ schema: 1, phase: "ready", active: { ...active, pid: "" + world.pid,
        start_ticks: "" + world.ticks, command: [ "/usr/bin/loki-core", "run", "-c", active.config_path ] }, candidate: null }));
}


function reset(options) {
    let dir = stub.tmpdir();
    start_request.paths.pending = dir + "/start.retry";
    start_request.paths.lock = dir + "/request.lock";
    start_request.paths.autostart = dir + "/rc.d/S99loki";
    lifecycle.paths.config = dir + "/loki.config";
    lifecycle.paths.lock = dir + "/start.lock";
    lifecycle.paths.pending_reload = dir + "/reload.pending";
    lifecycle.paths.planned_stop = dir + "/planned-stop";
    lifecycle.paths.applied_nft = dir + "/runtime.nft";
    lifecycle.paths.rc_dir = dir + "/rc.d";
    lifecycle.paths.sing_box_init = dir + "/loki-core";
    context.paths.base = dir + "/runtime";
    rulesets.paths.lock = lifecycle.paths.lock;
    rulesets.paths.planned_stop = lifecycle.paths.planned_stop;
    fs.writefile(lifecycle.paths.sing_box_init, "#!/bin/sh\n");
    fs.chmod(lifecycle.paths.sing_box_init, 0755);
    fs.writefile(lifecycle.paths.config, "config loki\n");
    fixture.seed({ settings: { config_format: "loki", config_version: options?.config_version ?? "2.0.0", cache_path: dir + "/private/cache.db" } });

    world = {
        dir,
        events: [],
        logs: [],
        pid: 0,
        registered: false,
        ticks: 100,
        ports: false,
        network: false,
        capture: true,
        script: "table inet loki\n",
        config_changed: false,
        slept: 0,
        // What the core does on its own between two looks of a wait.
        on_sleep: null,
        watcher: false,
        ...(options ?? {})
    };

    require("service.update").start_admission = () => world.admission_error ?? null;
    migration.start = () => {
        world.migration_checks = (world.migration_checks ?? 0) + 1;
        if (world.config_version != null || world.migration_fails)
            event("configuration migrated");
        return !world.migration_fails;
    };
    validator.check_requirements = () => { if (world.requirements_fail) die("requirements"); };
    validator.validate = () => {
        if (world.invalid) die("Section 'x' is broken. Aborted.");
        return { sections: require("core.uci").section_objects("loki") };
    };
    generator.runnable = () => !world.nothing_to_run;
    runtime.configure_service = () => { if (world.on_mutation != null) world.on_mutation("service"); };
    runtime.prepare_config = (checked) => {
        event(checked ? "config checked" : "config written");
        if (world.config_fails)
            die("Failed to generate loki-core configuration: broken");
        return { path: dir + "/core-config.json", changed: world.config_changed,
            text: sprintf("%J", { experimental: { clash_api: {
                external_controller_unix: "/tmp/loki/controller.sock", secret: digest } } }) };
    };
    runtime.install_config = (prepared) => {
        if (world.on_mutation != null) world.on_mutation("config");
        return prepared.changed;
    };
    runtime.fingerprint = () => digest;
    runtime.file_digest = () => world.digest_mismatch ? null : digest;
    runtime.identity = (path) => world.pid > 0 && !world.forked ? {
        pid: "" + world.pid, start_ticks: "" + world.ticks,
        command: [ "/usr/bin/loki-core", "run", "-c", path ] } : null;
    nft.ensure_bridge_netfilter_disabled = () => {
        if (world.on_mutation != null) world.on_mutation("bridge");
        return !world.bridge_fails;
    };
    nft.build = () => {
        if (world.build_fails)
            die("duplicate nft section: x");
        return { script: world.script, skipped: [], sections: [] };
    };
    nft.apply = (built) => {
        if (world.nft_fails)
            die("nft refused the ruleset: Error: broken");
        event("nft applied");
        world.network = true;
        if (world.on_apply != null)
            world.on_apply();
    };
    runtime.bound_devices = (path) => { world.bound_path = path; return world.bound ?? []; };
    nft.route_bound_devices = (devices) => {
        if (world.bound_rules_fail && length(devices) > 0)
            die("Failed to add the IPv4 routing rule of interface wwan0");
        if (length(devices) > 0 || length(world.bound_rules ?? []) > 0)
            event("bound to " + (length(devices) > 0 ? join(" ", devices) : "nothing"));
        world.bound_rules = devices;
    };
    // A network restart takes the routing and leaves the table.
    nft.ensure_tproxy_routing = () => {
        if (world.routing_fails)
            die("Failed to add the IPv4 TProxy routing rule");
        event("routing restored");
        world.routing_lost = false;
    };
    nft_state.table_present = () => world.network;
    for (let name in [ "tproxy_marking_rule4_present", "tproxy_marking_rule6_present", "tproxy_route4_present", "tproxy_route6_present", "source_check_rule4_present" ])
        nft_state[name] = () => false;
    nft_state.ipv6_enabled = () => !world.ipv6_off;
    health.sing_box_service_pid_runtime = () => world.pid;
    health.sing_box_service_registered = () => world.registered;
    health.pid_is_sing_box = (pid) => pid == world.pid && pid > 0 && !world.forked;
    health.start_ticks = (pid) => pid == world.pid ? world.ticks : null;
    health.sing_box_runtime_ports_ready = () => world.ports;
    health.loki_runtime_network_configured = () => world.network && world.capture && !world.routing_lost;
    health.sing_box_service_running = () => world.pid > 0;
    health.loki_running = () => world.pid > 0 && world.ports && world.network && world.capture && !world.routing_lost;
    watch.start_worker = () => {
        event("watcher started");
        world.watcher = !world.watcher_fails;
        if (world.on_watch != null)
            world.on_watch();
        return world.watcher;
    };
    watch.stop_worker = () => { event("watcher stopped"); world.watcher = false; return true; };
    watch.worker_current = () => {
        if (world.on_watch_check != null)
            world.on_watch_check();
        return world.watcher;
    };
    rulesets.start_worker = (active) => {
        event("rule-set worker started");
        world.worker_generation = active?.generation;
        if (world.on_mutation != null) world.on_mutation("worker");
        return !world.ruleset_fails;
    };
    rulesets.stop_worker = () => { event("rule-set worker stopped"); return true; };
    rulesets.worker_current = () => !world.worker_stale;

    if (world.pid > 0) seed_ready();

    global.sleep = function(ms) {
        world.slept++;
        if (world.on_sleep != null)
            world.on_sleep();
    };

    stub.commands([
        stub.logger(world.logs),
        [ "pgrep", () => ({ status: world.stray_sing_box ? 0 : 1 }) ],
        [ "dmesg", () => ({ stdout: world.kernel_log ?? "" }) ],
        [ "netstat -lnt", () => ({ stdout: world.netstat ?? "" }) ],
        [ dir + "/loki-core start", () => {
            event("loki-core started");
            world.registered = true;
            world.pid = 4242;
            world.ticks = 100;
            world.ports = true;
            return {};
        } ],
        [ dir + "/loki-core reload", () => {
            event("loki-core reloaded");
            if (!world.capture)
                event("reloaded with the capture paused");
            world.ports = false;
            world.on_sleep = () => { world.ports = !world.reload_never_ready; };
            return { status: world.reload_fails ? 1 : 0 };
        } ],
        [ dir + "/loki-core stop", () => {
            event("loki-core stopped");
            if (world.stop_fails)
                return { status: 1 };
            world.registered = false;
            world.pid = 0;
            world.ports = false;
            return {};
        } ],
        [ join(" ", nft.capture_command(false)), () => {
            event("capture paused");
            world.capture = false;
            return { status: world.pause_fails ? 1 : 0 };
        } ],
        [ join(" ", nft.capture_command(true)), () => {
            if (world.ports)
                event("capture resumed");
            else
                event("capture resumed before loki-core was ready");
            world.capture = true;
            return { status: world.resume_fails ? 1 : 0 };
        } ],
        [ "nft delete table inet loki", () => {
            event("nft table deleted");
            if (!world.table_delete_fails)
                world.network = false;
            return { status: world.table_delete_fails ? 1 : 0 };
        } ]
    ]);
}

function finish() {
    stub.restore();
    global.sleep = real_sleep;
}

function run(action) {
    let result = stub.capture(action);
    finish();
    return result;
}

function started() {
    reset();
    run(() => lifecycle.start());
    let previous = world;
    return previous;
}


function running(options) {
    reset(options);
    world.watcher = !options?.watcher_missing;
    world.registered = true;
    world.pid = 4242;
    world.ticks = 100;
    world.ports = true;
    world.network = true;
    seed_ready();
    fs.writefile(lifecycle.paths.applied_nft, "table inet loki\n");
}

function failures_logged() {
    return filter(world.logs, (line) => match(line, /^\[(error|fatal)\]/) != null);
}

function reloaded(options, reason) {
    running(options);
    let result = run(() => lifecycle.reload(reason ?? "on_config_change"));
    return result;
}

// The Python harness kills this real interpreter at the first interception. Router effects
// remain isolated fakes, but no exception handler or failed-start cleanup can run afterward.
let context_snapshot = getenv("LOKI_TEST_CONTEXT_SNAPSHOT");
let context_recover = getenv("LOKI_TEST_CONTEXT_RECOVER");
if (context_recover != null) {
    let interrupted = json(fs.readfile(context_recover));
    reset({ invalid: true, config_fails: true, build_fails: true });
    context.paths.base = interrupted.dir + "/runtime";
    lifecycle.paths.lock = interrupted.dir + "/start.lock";
    lifecycle.paths.planned_stop = interrupted.dir + "/planned-stop";
    rulesets.paths.lock = lifecycle.paths.lock;
    rulesets.paths.planned_stop = lifecycle.paths.planned_stop;
    world.pid = 4242; world.ticks = 100; world.ports = true; world.network = true; world.watcher = true;
    let status = stub.capture(() => lifecycle.start()).result;
    let state = context.read().model;
    print(sprintf("%J", { status, phase: state.phase, generation: state.active?.generation,
        candidate: state.candidate?.generation, events: world.events, pid: world.pid }));
    exit(0);
}
if (context_snapshot != null) {
    running({ config_changed: true, script: CHANGED_TABLE });
    let previous = context.read().model.active.generation;
    let point = getenv("LOKI_TEST_CONTEXT_POINT");
    let checkpoint = (step) => {
        if (step != point) return;
        let state = context.read().model;
        if (!require("core.common").write_file_atomic(context_snapshot, sprintf("%J", {
            dir: world.dir, previous, phase: state.phase, generation: state.active?.generation,
            candidate: state.candidate?.generation, events: world.events }))) exit(3);
        real_sleep(30000);
    };
    let write = context.write;
    context.write = (value) => {
        if (value.phase == "applying") checkpoint("before-applying");
        let ok = write(value);
        if (ok) checkpoint(value.phase);
        return ok;
    };
    world.on_mutation = checkpoint;
    world.on_apply = () => checkpoint("nft");
    lifecycle.reload("manual");
    exit(2);
}

let fatal_snapshot = getenv("LOKI_TEST_FATAL_SNAPSHOT");
let recover_snapshot = getenv("LOKI_TEST_RECOVER_SNAPSHOT");
if (recover_snapshot != null) {
    let interrupted = json(fs.readfile(recover_snapshot));
    reset();
    lifecycle.paths.lock = interrupted.dir + "/start.lock";
    lifecycle.paths.planned_stop = interrupted.dir + "/planned-stop";
    world.network = true;
    lifecycle.crash_pause("4242");
    print(sprintf("%J", { capture: world.capture, events: world.events }));
    exit(0);
}
if (fatal_snapshot != null) {
    reset();
    fs.writefile(lifecycle.paths.planned_stop, "previous stop\n");
    world.on_apply = () => {
        require("core.common").write_file_atomic(fatal_snapshot, sprintf("%J", {
            dir: world.dir,
            watcher: world.watcher,
            planned_stop: fs.stat(lifecycle.paths.planned_stop) != null,
            network: world.network,
            context_phase: context.read().model.phase,
            events: world.events
        }));
        real_sleep(30000);
    };
    lifecycle.start();
    exit(2);
}

t.test("unsafe cache paths stop start and reload before migration or runtime changes", () => {
    for (let active in [ false, true ]) {
        if (active)
            running();
        else
            reset();
        fs.mkdir(world.dir + "/shared-cache", 0755);
        fixture.seed({ settings: { config_format: "loki", config_version: "2.0.0", cache_path: world.dir + "/shared-cache/cache.db" } });
        let result = run(() => active ? lifecycle.reload("manual") : lifecycle.start());
        t.eq(result.result, 1);
        t.eq(world.migration_checks ?? 0, 0);
        t.eq(world.events, [], "the refusal neither reconfigures nor cleans up the runtime");
        t.eq(world.pid, active ? 4242 : 0);
        t.eq(world.network, active);
        t.eq(fs.stat(world.dir + "/shared-cache").mode & 0777, 0755);
        t.eq(fs.lstat(world.dir + "/shared-cache/cache.db"), null);
        t.ok(index(sprintf("%J", world.logs), world.dir) < 0, "the refusal does not disclose a custom path");
    }
});

t.test("a start waits for loki-core and arms the crash watcher before turning the table on", () => {
    reset();
    let result = run(() => lifecycle.start());
    t.eq(result.result, 0, sprintf("%J", world.logs));
    t.eq(world.events, [ "config checked", "rule-set worker started", "loki-core started", "watcher started", "nft applied" ]);
    t.eq(fs.readfile(lifecycle.paths.applied_nft), world.script, "the applied table is recorded");
    t.eq(world.logs, [ "[info] Starting LoKi", "[info] LoKi started" ]);
    t.eq(result.stdout, "", "a start prints nothing");
});

t.test("what the core sends bound to a device is routed from before it starts until it stops", () => {
    reset({ bound: [ "eth1", "wwan0" ] });
    t.eq(run(() => lifecycle.start()).result, 0);
    t.eq(world.events, [ "config checked", "rule-set worker started", "bound to eth1 wwan0", "loki-core started", "watcher started", "nft applied" ]);
    run(() => lifecycle.stop());
    t.contains(world.events, "bound to nothing");
    t.eq(world.bound_rules, []);

    reset({ bound: [ "wwan0" ], bound_rules_fail: true });
    let result = run(() => lifecycle.start());
    t.eq(result.result, 1);
    t.eq(failures_logged(), [ "[error] Failed to add the IPv4 routing rule of interface wwan0" ]);
    t.eq(filter(world.events, (e) => e == "loki-core started"), []);
});

t.test("a restored LoKi configuration is checked before anything else of a start", () => {
    reset({ config_version: "2.0.0" });
    let result = run(() => lifecycle.start());
    t.eq(result.result, 0);
    t.eq(world.events[0], "configuration migrated");
    t.contains(world.events, "loki-core started");

    reset({ config_version: "2.0.0", migration_fails: true });
    result = run(() => lifecycle.start());
    t.eq(result.result, 1);
    t.eq(filter(world.events, (e) => e == "config checked" || e == "loki-core started"), [],
        "a configuration it could not migrate is never validated or run");
    t.eq(world.migration_checks, 1, "even a current version reaches the shared format guard");
});

t.test("a start on a router with IPv6 off says that only IPv4 is routed", () => {
    reset({ ipv6_off: true });
    t.eq(run(() => lifecycle.start()).result, 0);
    t.eq(world.logs, [ "[info] Starting LoKi", "[info] IPv6 is off on the router; only IPv4 traffic is routed", "[info] LoKi started" ]);
});

t.test("a start of a running Loki does nothing", () => {
    running();
    let result = run(() => lifecycle.start());
    t.eq([ result.result, world.events ], [ 0, [] ]);
    t.contains(world.logs, "[info] LoKi is already running");
});

t.test("the crash watcher is armed at the first interception even if the starter cannot finish", () => {
    reset();
    fs.writefile(lifecycle.paths.planned_stop, "previous stop\n");
    let intercepted;
    world.on_apply = () => {
        intercepted = { watcher: world.watcher, planned_stop: fs.stat(lifecycle.paths.planned_stop) != null };
    };
    t.eq(run(() => lifecycle.start()).result, 0);
    t.eq(intercepted, { watcher: true, planned_stop: false });
});

t.test("Start repairs only the missing watcher under the lifecycle lock without reading new UCI", () => {
    running({ watcher_missing: true, invalid: true, config_fails: true, build_fails: true });
    let held = false;
    world.on_watch = () => { held = lock.held(lifecycle.paths.lock); };
    let result = stub.capture(() => lifecycle.start());
    t.eq(result.result, 0);
    t.ok(held);
    t.eq(world.events, [ "watcher started" ]);
    t.eq(world.migration_checks ?? 0, 0);
    t.eq([ world.pid, world.network ], [ 4242, true ]);
    t.eq(stub.capture(() => lifecycle.start()).result, 0);
    t.eq(world.events, [ "watcher started" ], "a repeated Start keeps the repaired watcher");
    finish();
});

t.test("failed watcher repair reports failure while preserving the applied runtime", () => {
    running({ watcher_missing: true, watcher_fails: true });
    t.eq(run(() => lifecycle.start()).result, 1);
    t.eq(world.events, [ "watcher started" ]);
    t.eq([ world.pid, world.network ], [ 4242, true ]);
});

t.test("a planned stop prevents a healthy runtime from being silently rearmed", () => {
    running({ watcher_missing: true });
    fs.writefile(lifecycle.paths.planned_stop, "1\n");
    t.eq(run(() => lifecycle.start()).result, 1);
    t.eq(world.events, []);
    t.ok(fs.stat(lifecycle.paths.planned_stop) != null);
});

t.test("cancelled repair cannot register a watcher after waiting for the lifecycle lock", () => {
    running({ watcher_missing: true });
    t.eq(run(() => lifecycle.start(() => !lock.held(lifecycle.paths.lock))).result, 0);
    t.eq(world.events, []);
    t.ok(!world.watcher);
});

t.test("cancellation during the procd health query prevents watcher registration", () => {
    running({ watcher_missing: true });
    let token = start_request.begin();
    world.on_watch_check = () => start_request.cancel(token);
    t.eq(run(() => lifecycle.start(() => start_request.current(token))).result, 0);
    t.eq(world.events, []);
    t.ok(!world.watcher);
});

t.test("a core that dies during watcher repair is not reported as already running", () => {
    running({ watcher_missing: true });
    world.on_watch = () => { world.pid = 0; world.ports = false; };
    t.eq(run(() => lifecycle.start()).result, 1);
    t.eq(world.events, [ "watcher started" ]);
});

t.test("manual repair works with autostart disabled and a following Stop removes the watcher", () => {
    running({ watcher_missing: true });
    t.ok(!start_request.enabled());
    t.eq(stub.capture(() => lifecycle.start()).result, 0);
    t.ok(world.watcher);
    t.eq(run(() => lifecycle.stop()).result, 0);
    t.eq([ world.pid, world.watcher, world.network ], [ 0, false, false ]);
    t.ok(fs.stat(lifecycle.paths.planned_stop) != null);
});

t.test("WAN restoration repairs the watcher through shared Start without applying newly saved UCI", () => {
    let initd = require("service.initd");
    let ui = require("service.ui");
    let begin = ui.begin;
    ui.begin = () => ({ job_id: "" });
    for (let failure in [ false, true ]) {
        running({ routing_lost: true, watcher_missing: true, watcher_fails: failure,
            invalid: true, config_fails: true, build_fails: true });
        health.loki_stably_running = () => health.loki_running();
        fs.mkdir(world.dir + "/rc.d");
        fs.symlink("../init.d/loki", start_request.paths.autostart);
        let token = start_request.begin();
        let result = stub.capture(() => initd.wan_up());
        t.eq(result.result, failure ? 1 : 0);
        t.eq(world.events, [ "routing restored", "watcher started" ]);
        t.eq([ world.pid, world.network, world.routing_lost ], [ 4242, true, false ]);
        t.eq(world.migration_checks ?? 0, 0);
        t.eq(start_request.token(), failure ? token : "");
        if (!failure) {
            start_request.begin();
            t.eq(stub.capture(() => initd.wan_up()).result, 0);
            t.eq(world.events, [ "routing restored", "watcher started" ], "repeat keeps the repaired watcher");
        }
        finish();
    }
    ui.begin = begin;
});

t.test("cancellation while registering the watcher removes it before any interception", () => {
    reset();
    let token = start_request.begin();
    world.on_watch = () => start_request.cancel(token);
    t.eq(run(() => lifecycle.start(() => start_request.current(token))).result, 1);
    t.ok(index(world.events, "nft applied") < 0);
    t.eq([ world.pid, world.watcher, world.network ], [ 0, false, false ]);
});

t.test("failure to remove the planned-stop guard refuses interception and cleans up", () => {
    reset();
    fs.mkdir(lifecycle.paths.planned_stop);
    t.eq(run(() => lifecycle.start()).result, 1);
    t.ok(index(world.events, "nft applied") < 0);
    t.eq([ world.pid, world.watcher, world.network ], [ 0, false, false ]);
});

t.test("readiness lost during watcher registration prevents interception", () => {
    reset();
    world.on_watch = () => { world.ports = false; };
    t.eq(run(() => lifecycle.start()).result, 1);
    t.ok(index(world.events, "nft applied") < 0);
    t.eq([ world.pid, world.watcher, world.network ], [ 0, false, false ]);
});

t.test("a start with nothing to run warns once, runs nothing and succeeds", () => {
    reset({ nothing_to_run: true });
    let result = run(() => lifecycle.start());
    t.eq(result.result, 0);
    t.eq(world.logs, [ "[info] Starting LoKi", NOTHING_TO_RUN ]);
    t.eq(filter(world.events, (e) => e == "config checked" || e == "loki-core started" || e == "nft applied"), []);
    t.eq([ result.stdout, result.stderr ], [ "", "" ]);
});

t.test("an incomplete applied runtime requires explicit Apply before newly saved empty UCI tears it down", () => {
    running({ nothing_to_run: true, capture: false });
    t.eq(stub.capture(() => lifecycle.start()).result, 1);
    t.eq(world.events, []);
    t.eq(run(() => lifecycle.reload("manual")).result, 0);
    t.contains(world.events, "nft table deleted");
    t.contains(world.events, "loki-core stopped");
    t.eq(filter(world.events, (e) => e == "loki-core started"), []);
});

t.test("a stopped Loki with nothing to run is not started by a reload", () => {
    reset({ nothing_to_run: true });
    let result = run(() => lifecycle.reload("interface_up:wwan"));
    t.eq(result.result, 0);
    t.eq(world.logs, [ "[info] Reapplying configuration: interface 'wwan' came up", NOTHING_TO_RUN ]);
    t.eq(filter(world.events, (e) => e == "loki-core started"), []);
});

t.test("a start that fails before loki-core ran stops no loki-core service, which procd does not hold", () => {
    reset({ config_fails: true });
    t.eq(run(() => lifecycle.start()).result, 1);
    t.eq(filter(world.events, (e) => e == "loki-core stopped"), []);
});

t.test("a configuration the validator refuses stops a start before anything runs, and says why on stderr", () => {
    reset({ invalid: true });
    let result = run(() => lifecycle.start());
    t.eq(result.result, 1);
    t.eq(filter(world.events, (e) => e == "loki-core started" || e == "nft applied"), []);
    t.eq(result.stderr, "Section 'x' is broken. Aborted.\n", "the refusal is said once");
    t.eq(result.stdout, "");
});

t.test("a start that fails after loki-core came up takes everything down again", () => {
    reset({ nft_fails: true });
    let result = run(() => lifecycle.start());
    t.eq(result.result, 1);
    t.eq(world.logs, [ "[info] Starting LoKi", "[error] nft refused the ruleset: Error: broken" ],
        "the reason, once, and nothing about the cleanup behind it");
    t.contains(world.events, "loki-core stopped");
    t.eq(world.pid, 0);
});

t.test("a start whose Clash API address is taken stops before loki-core, and kills nothing", () => {
    reset({ netstat: "tcp 0 0 0.0.0.0:9090 0.0.0.0:* LISTEN\n" });
    let config = world.dir + "/config.json";
    fs.writefile(config, "{\"experimental\":{\"clash_api\":{\"external_controller\":\"192.168.1.1:9090\"}}}");
    require("fixture").seed({ settings: { config_path: config } });
    let result = run(() => lifecycle.start());
    t.eq(result.result, 1);
    t.contains(world.logs, "[error] Clash API address 192.168.1.1:9090 is already in use by another process");
    t.eq(filter(world.events, (e) => e == "loki-core started"), []);
});

t.test("a start refuses to run a second loki-core", () => {
    reset({ stray_sing_box: true });
    let result = run(() => lifecycle.start());
    t.eq(result.result, 1);
    t.eq(filter(world.events, (e) => e == "loki-core started"), []);
    t.contains(result.stderr, "Another loki-core process is running outside LoKi; stop it before starting LoKi");
});

t.test("each failed step of a start names itself in the log as an error", () => {
    for (let failure in [
        [ { bridge_fails: true }, "Failed to disable bridge netfilter for transparent proxying" ],
        [ { watcher_fails: true }, "Failed to start the loki-core crash watcher" ],
        [ { ruleset_fails: true }, "Failed to start the rule-set sync worker" ],
        [ { requirements_fail: true }, "requirements" ],
        [ { invalid: true }, "Section 'x' is broken. Aborted." ]
    ]) {
        reset(failure[0]);
        let result = run(() => lifecycle.start());
        t.eq(result.result, 1, failure[1]);
        t.eq(failures_logged(), [ "[error] " + failure[1] ], failure[1]);
    }
});

t.test("an unchanged apply confirms a new generation without signalling the core", () => {
    let result = reloaded();
    t.eq(result.result, 0);
    t.eq(world.events, [ "config written", "rule-set worker started" ]);
    t.contains(world.logs, "[info] Configuration applied");
});

t.test("a changed loki-core configuration is reloaded with the capture paused until the core is ready again, and a worker waits for the new generation", () => {
    let result = reloaded({ config_changed: true });
    t.eq(result.result, 0);
    t.eq(world.events, [ "config written", "rule-set worker started", "capture paused", "loki-core reloaded", "reloaded with the capture paused",
        "capture resumed" ]);
    t.contains(world.logs, "[info] Configuration applied");
    t.ok(world.slept > 0, "the reload waited out its window");
});

t.test("a change to the providers a section reads alone starts the rule-set worker again, and is applied", () => {
    let result = reloaded({ worker_stale: true });
    t.eq(result.result, 0);
    t.eq(world.events, [ "config written", "rule-set worker started" ]);
    t.contains(world.logs, "[info] Configuration applied");
});

t.test("a changed table is rebuilt after registering its waiting rule-set worker, and loki-core is left alone", () => {
    let result = reloaded({ script: CHANGED_TABLE });
    t.eq(result.result, 0);
    t.eq(world.events, [ "config written", "rule-set worker started", "nft applied" ]);
    t.eq(world.logs, [ "[info] Applying configuration", "[info] Configuration applied" ]);
});

t.test("a reload routes the devices the new configuration binds before the core reads it", () => {
    let result = reloaded({ config_changed: true, bound: [ "eth1", "wwan0" ], bound_rules: [ "eth1", "gone0" ] });
    t.eq(result.result, 0);
    t.eq(world.events, [ "config written", "rule-set worker started", "bound to eth1 wwan0", "capture paused", "loki-core reloaded",
        "reloaded with the capture paused", "capture resumed" ]);

    result = reloaded({ bound: [ "wwan0" ], bound_rules: [ "wwan0" ] });
    t.eq(world.events, [ "config written", "rule-set worker started", "bound to wwan0" ], "an unchanged configuration has them checked");
    t.contains(world.logs, "[info] Configuration applied");

    result = reloaded({ config_changed: true, bound: [ "wwan0" ], bound_rules_fail: true });
    t.eq(result.result, 1);
    t.eq(failures_logged(), [ "[error] Failed to add the IPv4 routing rule of interface wwan0" ]);
    t.eq(world.logs[length(world.logs) - 1], "[warn] Configuration not applied; LoKi is stopped");
    t.eq(filter(world.events, (e) => e == "loki-core reloaded"), []);
});

t.test("a configuration refused while it is generated leaves the running runtime and its table alone, and is said once", () => {
    let result = reloaded({ config_fails: true, config_changed: true, script: CHANGED_TABLE });
    t.eq(result.result, 1);
    t.eq(world.events, [ "config written" ]);
    t.eq(fs.readfile(lifecycle.paths.applied_nft), "table inet loki\n", "the table applied last is still the live one");
    t.eq(failures_logged(), [ "[error] Failed to generate loki-core configuration: broken" ]);
    t.eq(result.stderr, "Failed to generate loki-core configuration: broken\n");
    t.eq(world.logs[length(world.logs) - 1], "[warn] Configuration not applied; LoKi keeps running the previous one");
});

t.test("a table that cannot be built is said in one line and touches nothing", () => {
    let result = reloaded({ build_fails: true, config_changed: true });
    t.eq(result.result, 1);
    t.eq(world.events, [ ]);
    t.eq(failures_logged(), [ "[error] Failed to build the nftables rules: duplicate nft section: x" ]);
});

t.test("a reload asked for by hand reloads loki-core even when nothing changed, and registers a worker for the new generation", () => {
    let result = reloaded({}, "");
    t.eq(result.result, 0);
    t.eq(world.events, [ "config written", "rule-set worker started", "capture paused", "loki-core reloaded", "reloaded with the capture paused", "capture resumed" ]);
});

t.test("a queued reload applies what changed without forcing loki-core", () => {
    let result = reloaded({}, "pending");
    t.eq(world.events, [ "config written", "rule-set worker started" ]);
});

t.test("each failed step of a reload after the runtime was touched names itself once and takes the runtime down", () => {
    for (let failure in [
        [ { pause_fails: true, config_changed: true }, "[error] Failed to pause the traffic capture before reloading loki-core", false ],
        [ { reload_fails: true, config_changed: true }, "[error] Failed to reload loki-core", true ],
        [ { resume_fails: true, config_changed: true }, "[error] Failed to resume the traffic capture after reloading loki-core", true ],
        [ { nft_fails: true, script: CHANGED_TABLE }, "[error] nft refused the ruleset: Error: broken", false ],
        [ { ruleset_fails: true, worker_stale: true, config_changed: true }, "[error] Failed to start the rule-set sync worker", false ]
    ]) {
        let result = reloaded(failure[0]);
        t.eq(result.result, 1, failure[1]);
        t.eq(failures_logged(), [ failure[1] ], failure[1]);
        t.contains(result.stderr, substr(failure[1], 8));
        t.eq(world.logs[length(world.logs) - 1], "[warn] Configuration not applied; LoKi is stopped", failure[1]);
        t.contains(world.events, "loki-core stopped", failure[1]);
        t.eq(index(world.events, "loki-core reloaded") >= 0, failure[2], failure[1] + ": whether loki-core was signalled");
    }
});

t.test("a core that does not come back after its reload stops the runtime", () => {
    let result = reloaded({ config_changed: true, reload_never_ready: true });
    t.eq(result.result, 1);
    t.contains(world.logs, "[error] loki-core did not become ready after it was reloaded");
    t.eq(filter(world.events, (e) => substr(e, 0, 15) == "capture resumed"), [], "the capture never resumes on a dead core");
});

t.test("a reload of a runtime that is not complete restarts it", () => {
    running();
    world.network = false;
    let result = run(() => lifecycle.reload("on_config_change"));
    t.eq(result.result, 0);
    t.eq(world.logs, [ "[info] Applying configuration", "[info] LoKi is not fully running; restarting it", "[info] Configuration applied" ]);
    t.ok(index(world.events, "loki-core stopped") < index(world.events, "loki-core started"));
    t.contains(world.events, "nft applied");
});

t.test("a configuration changed while a reload ran queues another one", () => {
    running({ config_changed: true });
    let prepare = runtime.prepare_config;
    runtime.prepare_config = (checked) => {
        fs.writefile(lifecycle.paths.config, "config loki changed\n");
        return prepare(checked);
    };
    run(() => lifecycle.reload("on_config_change"));
    t.matches(fs.readfile(lifecycle.paths.pending_reload), /^reason=config_changed_during_reload\n/);
});

t.test("a stop marks itself planned, closes the ports and takes everything down", () => {
    running();
    let result = run(() => lifecycle.stop());
    t.eq(result.result, 0);
    t.eq(world.events, [ "watcher stopped", "rule-set worker stopped", "nft table deleted", "loki-core stopped" ]);
    t.ok(fs.stat(lifecycle.paths.planned_stop) != null);
    t.ok(fs.stat(lifecycle.paths.applied_nft) == null, "no table is recorded once it is gone");
});

t.test("a core without its init script already counts as stopped, and a core that refuses to stop fails the stop", () => {
    running();
    world.pid = 0;
    fs.unlink(lifecycle.paths.sing_box_init);
    t.eq(run(() => lifecycle.stop()).result, 0);

    running();
    fs.chmod(lifecycle.paths.sing_box_init, 0644);
    world.pid = 0;
    t.eq(run(() => lifecycle.stop()).result, 0, "an init script that cannot run");

    running();
    let dir = world.dir;
    world.pid = 0;
    stub.commands([ [ dir + "/loki-core stop", { status: 2 } ], [ "pgrep", { status: 1 } ], [ () => true, {} ] ]);
    let status = lifecycle.stop();
    finish();
    t.eq(status, 1);
});

t.test("a core that refuses to stop is named in the log as an error", () => {
    running({ stop_fails: true });
    let result = run(() => lifecycle.stop());
    t.eq(result.result, 1);
    t.contains(world.logs, "[error] Failed to stop loki-core");
    t.contains(world.logs, "[error] loki-core is still running after it was stopped");
});

t.test("a stop whose table cannot be removed fails", () => {
    running({ table_delete_fails: true });
    let result = run(() => lifecycle.stop());
    t.eq(result.result, 1);
    t.contains(result.stderr, "Failed to remove the LoKi nftables table");
});

t.test("a crash cleanup leaves a planned stop and a running runtime alone, and takes a dead one down", () => {
    running();
    world.pid = 0;
    world.ports = false;
    fs.writefile(lifecycle.paths.planned_stop, "1\n");
    let result = run(() => lifecycle.crash_cleanup("137"));
    t.eq([ result.result, world.events ], [ 0, [] ], "a stop LoKi made itself");

    running();
    t.eq([ run(() => lifecycle.crash_cleanup("137")).result, world.events ], [ 0, [] ], "a runtime that recovered");

    running();
    world.pid = 0;
    world.ports = false;
    t.eq(run(() => lifecycle.crash_cleanup("137")).result, 0);
    t.contains(world.logs, "[error] loki-core stopped after repeated crashes (exit code 137); LoKi is stopped");
    t.contains(world.events, "nft table deleted");
    t.eq(length(filter(world.events, (e) => e == "watcher stopped")), 1, "the watcher runs the cleanup and is stopped once it finished");
});

function crashed(options) {
    running(options);
    world.pid = 0;
    world.ports = false;
}

t.test("a core procd is about to respawn pauses the capture until the new one listens", () => {
    crashed();
    t.eq(run(() => lifecycle.crash_pause()).result, 0);
    t.eq(world.events, [ "capture paused" ]);
    t.contains(world.logs, "[warn] loki-core exited unexpectedly; the capture is paused until procd restarts it");

    running({ capture: false });
    t.eq(run(() => lifecycle.crash_resume()).result, 0);
    t.eq(world.events, [ "capture resumed" ], "resumed only once the respawned core listens");
    t.contains(world.logs, "[info] loki-core restarted; traffic capture resumed");
});

t.test("the crash resume waits for a core procd has forked but not yet run", () => {
    running({ capture: false, forked: true });
    world.on_sleep = () => { world.forked = false; };
    t.eq(run(() => lifecycle.crash_resume()).result, 0);
    t.eq(world.events, [ "capture resumed" ]);

    running({ capture: false, forked: true });
    t.eq(run(() => lifecycle.crash_resume()).result, 0);
    t.eq(world.events, [], "a child that never becomes loki-core");
    t.ok(world.slept < 10, "is given up after a few looks");
});

t.test("the crash pause says so when the kernel killed the core for memory", () => {
    let oom = (pid) => "[2093230.465149] Out of memory: Killed process " + pid + " (loki-core) total-vm:1386056kB, anon-rss:79772kB, file-rss:0kB\n";
    crashed({ kernel_log: oom(17203) + "[2093231.000000] br-lan: port 1(lan2) entered disabled state\n" + oom(8632) });
    run(() => lifecycle.crash_pause("8632"));
    t.contains(world.logs, "[warn] The router ran out of memory and the kernel killed loki-core; the capture is paused until procd restarts it");

    crashed({ kernel_log: oom(8632) + oom(17203) });
    run(() => lifecycle.crash_pause("8632"));
    t.contains(world.logs, "[warn] loki-core exited unexpectedly; the capture is paused until procd restarts it",
        "an older kill of an earlier process with the same pid");

    crashed({ kernel_log: oom(8632) });
    run(() => lifecycle.crash_pause(""));
    t.contains(world.logs, "[warn] loki-core exited unexpectedly; the capture is paused until procd restarts it", "a watcher that saw no core");
});

t.test("the crash pause leaves alone what a lifecycle action or a live core owns", () => {
    crashed();
    fs.writefile(lifecycle.paths.planned_stop, "1\n");
    run(() => lifecycle.crash_pause());
    t.eq(world.events, [], "a stop LoKi made itself");

    crashed();
    fs.mkdir(lifecycle.paths.lock);
    run(() => lifecycle.crash_pause());
    t.eq(world.events, [], "an action holding the lock");

    running();
    run(() => lifecycle.crash_pause());
    t.eq(world.events, [], "a core that is already back");

    crashed();
    world.network = false;
    run(() => lifecycle.crash_pause());
    t.eq(world.events, [], "no table to pause");

    running({ capture: false });
    world.network = false;
    run(() => lifecycle.crash_resume());
    t.eq(world.events, [], "a table the cleanup removed is not created again");

    running();
    run(() => lifecycle.crash_resume());
    t.eq(world.events, [], "a capture that is not paused");
});

t.test("the routing a network restart took is put back under a running core and its table", () => {
    running({ routing_lost: true, bound: [ "wwan0" ] });
    let result = run(() => lifecycle.restore_routing());
    t.eq([ result.result, world.events ], [ true, [ "routing restored", "bound to wwan0" ] ]);
    t.eq(world.logs, [ "[info] The WAN came up without LoKi's routing; restored it" ]);

    running({ routing_lost: true, routing_fails: true });
    result = run(() => lifecycle.restore_routing());
    t.eq(result.result, false);
    t.eq(failures_logged(), [ "[error] Failed to add the IPv4 TProxy routing rule" ]);
});

t.test("restoring the routing leaves alone what a stop, an action or a crash owns, and a routing in place", () => {
    running({ routing_lost: true });
    fs.writefile(lifecycle.paths.planned_stop, "1\n");
    t.eq([ run(() => lifecycle.restore_routing()).result, world.events ], [ false, [] ], "a stop LoKi made itself");

    running({ routing_lost: true });
    fs.mkdir(lifecycle.paths.lock);
    t.eq([ run(() => lifecycle.restore_routing()).result, world.events ], [ false, [] ], "an action holding the lock");

    crashed({ routing_lost: true });
    t.eq([ run(() => lifecycle.restore_routing()).result, world.events ], [ false, [] ], "a core procd is bringing back");

    running({ routing_lost: true });
    world.network = false;
    t.eq([ run(() => lifecycle.restore_routing()).result, world.events ], [ false, [] ], "no table");

    running();
    t.eq([ run(() => lifecycle.restore_routing()).result, world.events, world.logs ], [ false, [], [] ], "nothing lost");
});

t.test("a start clears the planned stop, so a later crash is cleaned up", () => {
    reset();
    fs.writefile(lifecycle.paths.planned_stop, "1\n");
    run(() => lifecycle.start());
    t.ok(fs.stat(lifecycle.paths.planned_stop) == null);
});

function waited(options, window, hold) {
    reset(options);
    let status = lifecycle.wait_ready(window, hold, false);
    finish();
    return { status, slept: world.slept };
}

t.test("the readiness wait sits out its window and needs the hold at the end of it", () => {
    let ready = { pid: 4242, ports: true };
    t.eq(waited(ready, 2, 2), { status: true, slept: 2 });
    t.eq(waited(ready, 8, 2), { status: true, slept: 8 }, "ready the whole time still waits the window out");

    let rebinding = 0;
    t.eq(waited({ pid: 4242, ports: false, on_sleep: () => { world.ports = ++rebinding >= 3; } }, 2, 2), { status: true, slept: 5 },
        "readiness that comes back after the window still has to hold");

    let late = 0;
    t.eq(waited({ pid: 0, on_sleep: () => { if (++late == 2) { world.pid = 4242; world.ports = true; } } }, 8, 2).status, true,
        "a process procd forks after answering is waited for");
    t.eq(waited({ pid: 0 }, 2, 2), { status: false, slept: 2 }, "no process by the end of the window is a failed start");

    let replaced = 0;
    t.eq(waited({ pid: 4242, ports: true, on_sleep: () => { if (++replaced == 1) world.ticks = 999; } }, 8, 2), { status: false, slept: 1 },
        "a process replaced mid-wait is not the runtime that was built");
    t.eq(waited({ pid: 4242, ports: false }, 2, 2), { status: false, slept: 300 }, "a process that never answers is given up on");
});

t.test("a start whose loki-core exits on the way up points at the core's own reason", () => {
    reset({ on_sleep: () => { world.pid = 0; world.ports = false; } });
    let result = run(() => lifecycle.start());
    t.eq(result.result, 1);
    t.eq(failures_logged(), [ "[error] loki-core exited after it was started; its own log lines above say why" ]);
});

t.test("a stop is reported from its start to its end, and a stop with nothing running says nothing", () => {
    running();
    run(() => lifecycle.stop());
    t.eq(world.logs, [ "[info] Stopping LoKi", "[info] LoKi stopped" ]);

    reset();
    t.eq(run(() => lifecycle.stop()).result, 0);
    t.eq(world.logs, [], "the stop of an upgrade after the one of the installer");
});

t.test("a forced reload says what set it off", () => {
    reloaded({}, "");
    t.eq(world.logs[0], "[info] Reapplying configuration");
    reloaded({}, "interface_up:wan");
    t.eq(world.logs[0], "[info] Reapplying configuration: interface 'wan' came up");
    t.eq(world.logs[length(world.logs) - 1], "[info] Configuration applied");
});

t.test("every action opens with a line the page knows", () => {
    let contract = json(fs.readfile(repo.path("tests/fixtures/page_contract.json")));
    let openings = [];
    reset();
    run(() => lifecycle.start());
    push(openings, world.logs[0]);
    running();
    run(() => lifecycle.stop());
    push(openings, world.logs[0]);
    reloaded();
    push(openings, world.logs[0]);
    reloaded({}, "");
    push(openings, world.logs[0]);
    t.eq(openings, map(contract.action_openings, (opening) => "[info] " + opening));
});

t.test("autostart is the rc.d link and nothing else", () => {
    reset();
    finish();
    t.eq(lifecycle.enable(), 0);
    t.eq(fs.readlink(lifecycle.paths.rc_dir + "/S99loki"), "../init.d/loki");
    t.eq(lifecycle.enable(), 0, "enabling twice");
    fs.symlink("../init.d/loki", lifecycle.paths.rc_dir + "/K99loki");
    t.eq(lifecycle.disable(), 0);
    t.ok(fs.lstat(lifecycle.paths.rc_dir + "/S99loki") == null && fs.lstat(lifecycle.paths.rc_dir + "/K99loki") == null);
    t.eq(lifecycle.disable(), 0, "disabling twice");
});

t.test("re-enabling autostart keeps its existing entry when a new symlink cannot be created", () => {
    reset();
    finish();
    t.eq(lifecycle.enable(), 0);
    let link = lifecycle.paths.rc_dir + "/S99loki";
    let before = fs.lstat(link);
    t.ok(type(before.inode) == "int" && before.inode > 0, "native inode is available");
    let symlink = fs.symlink;
    let attempts = 0;
    let status;
    try {
        fs.symlink = () => { attempts++; return null; };
        status = lifecycle.enable();
    }
    catch (e) {
        fs.symlink = symlink;
        die(e);
    }
    fs.symlink = symlink;
    t.eq(status, 0);
    t.eq(attempts, 0, "an already enabled service needs no replacement");
    t.eq(fs.readlink(link), "../init.d/loki");
    t.eq(fs.lstat(link)?.inode, before.inode, "the durable entry was not replaced");
});

t.test("unexpected autostart objects are refused without deleting their data", () => {
    for (let kind in [ "file", "directory", "link", "dangling", "hardlink" ]) {
        reset();
        finish();
        fs.mkdir(lifecycle.paths.rc_dir, 0755);
        let link = lifecycle.paths.rc_dir + "/S99loki";
        let victim = world.dir + "/victim";
        fs.writefile(victim, "preserved synthetic data");
        if (kind == "directory") {
            fs.mkdir(link, 0700);
            fs.writefile(link + "/keep", "preserved");
        }
        else if (kind == "file")
            fs.writefile(link, "preserved");
        else if (kind == "hardlink")
            t.eq(require("core.exec").status([ "ln", victim, link ]), 0);
        else
            fs.symlink(kind == "dangling" ? world.dir + "/missing" : victim, link);
        let before = fs.lstat(link);
        t.ok(type(before.inode) == "int" && before.inode > 0, "native inode is available");
        t.eq(lifecycle.enable(), 1, kind);
        t.eq(fs.lstat(link)?.inode, before.inode, kind);
        t.eq(fs.readfile(victim), "preserved synthetic data", kind);
        if (kind == "file") t.eq(fs.readfile(link), "preserved");
        if (kind == "directory") t.eq(fs.readfile(link + "/keep"), "preserved");
        if (kind == "hardlink") t.eq(fs.lstat(victim).nlink, 2);
        if (kind == "link" || kind == "dangling") t.ok(fs.readlink(link) != null);
    }
});

t.test("disabling autostart preserves an unexpected entry, including a dangling link", () => {
    for (let prefix in [ "S", "K" ]) {
        for (let kind in [ "file", "directory", "link", "dangling", "hardlink" ]) {
            reset();
            finish();
            fs.mkdir(lifecycle.paths.rc_dir, 0755);
            let link = lifecycle.paths.rc_dir + "/" + prefix + "99loki";
            let victim = world.dir + "/victim";
            fs.writefile(victim, "preserved synthetic data");
            if (kind == "directory")
                fs.mkdir(link, 0700);
            else if (kind == "file")
                fs.writefile(link, "preserved");
            else if (kind == "hardlink")
                t.eq(require("core.exec").status([ "ln", victim, link ]), 0);
            else
                fs.symlink(kind == "dangling" ? world.dir + "/missing" : victim, link);
            let before = fs.lstat(link);
            t.ok(type(before.inode) == "int" && before.inode > 0, "native inode is available");
            t.eq(lifecycle.disable(), 1, prefix + ":" + kind);
            t.eq(fs.lstat(link)?.inode, before.inode, prefix + ":" + kind);
            t.eq(fs.readfile(victim), "preserved synthetic data");
        }
    }
});

t.test("autostart creation errors keep the service disabled and an unavailable parent is untouched", () => {
    reset();
    finish();
    let link = lifecycle.paths.rc_dir + "/S99loki";
    let symlink = fs.symlink;
    fs.symlink = () => null;
    let status = lifecycle.enable();
    fs.symlink = symlink;
    t.eq(status, 1);
    t.ok(fs.lstat(link) == null);
    fs.rmdir(lifecycle.paths.rc_dir);
    fs.writefile(lifecycle.paths.rc_dir, "preserved parent");
    t.eq(lifecycle.enable(), 1);
    t.eq(fs.readfile(lifecycle.paths.rc_dir), "preserved parent");
});

t.test("concurrent enable accepts the correct link created by the other call", () => {
    reset();
    finish();
    let symlink = fs.symlink;
    fs.symlink = (target, link) => {
        symlink(target, link);
        return null;
    };
    let status = lifecycle.enable();
    fs.symlink = symlink;
    t.eq(status, 0);
    t.eq(fs.readlink(lifecycle.paths.rc_dir + "/S99loki"), "../init.d/loki");
});

t.test("disable refuses foreign entries before removing any own link and reports unlink failure", () => {
    reset();
    finish();
    t.eq(lifecycle.enable(), 0);
    let start = lifecycle.paths.rc_dir + "/S99loki";
    let stop = lifecycle.paths.rc_dir + "/K99loki";
    fs.writefile(stop, "preserved foreign entry");
    t.eq(lifecycle.disable(), 1);
    t.eq(fs.readlink(start), "../init.d/loki");
    t.eq(fs.readfile(stop), "preserved foreign entry");
    fs.unlink(stop);
    let unlink = fs.unlink;
    fs.unlink = () => null;
    let status = lifecycle.disable();
    fs.unlink = unlink;
    t.eq(status, 1);
    t.eq(fs.readlink(start), "../init.d/loki");
});

t.test("disable reports an incomplete filesystem check instead of claiming the service is disabled", () => {
    reset();
    finish();
    let lstat = fs.lstat;
    let error = fs.error;
    let failed = false;
    fs.lstat = (path) => {
        failed = path == lifecycle.paths.rc_dir + "/S99loki";
        return failed ? null : lstat(path);
    };
    fs.error = () => failed ? "synthetic input/output error" : error();
    let status = lifecycle.disable();
    fs.lstat = lstat;
    fs.error = error;
    t.eq(status, 1);
});

t.test("repeated service cycles cannot prepare retired servers or tunnels", () => {
    let uci = require("uci");
    reset();
    fixture.seed({ settings: { config_format: "loki", config_version: "2.0.0" }, server: [
        { ".name": "server-private-name", enabled: "1", protocol: "vless", security: "reality", open_firewall: "1", listen_port: "18443" },
        { ".name": "json-private-name", enabled: "1", protocol: "json_inbound", inbound_json: "invalid-private-json" }
    ], tunnel: [
        { ".name": "tailnet", section: "missing", kind: "tailscale", tailscale_auth_key: "synthetic-private-key" },
        { ".name": "warp", section: "missing", kind: "warp", warp_profile_auth_token: "synthetic-private-token" }
    ] });
    let result = stub.capture(() => {
        let statuses = [];
        for (let cycle = 0; cycle < 2; cycle++) {
            push(statuses, lifecycle.start());
            push(statuses, lifecycle.reload("manual"));
            push(statuses, lifecycle.stop());
        }
        return statuses;
    });
    let commands = stub.command_lines();
    finish();
    t.eq(result.result, [ 0, 0, 0, 0, 0, 0 ]);
    t.eq(filter(commands, (line) => match(line, /firewall|reality-keypair|server-certs|loki-servers|tailscale|warp-profile/) != null), []);
    t.eq(uci.__commits(), [], "server defaults are never written");
    t.excludes(join("\n", world.logs), "private-");
});

t.test("a cancelled start does no work before or after waiting for the lifecycle lock", () => {
    reset();
    t.eq(run(() => lifecycle.start(() => false)).result, 0);
    t.eq(world.events, []);
    t.eq(world.migration_checks, null);
    reset();
    t.eq(run(() => lifecycle.start(() => !lock.held(lifecycle.paths.lock))).result, 0);
    t.eq(world.events, []);
    t.eq(world.migration_checks, null);
});

t.test("cancellation during readiness stops the new core without applying interception", () => {
    reset();
    let token = start_request.begin();
    world.on_sleep = () => start_request.cancel(token);
    t.eq(run(() => lifecycle.start(() => start_request.current(token))).result, 1);
    t.ok(index(world.events, "loki-core started") >= 0);
    t.ok(index(world.events, "nft applied") < 0);
    t.eq(world.pid, 0);
    t.eq(world.network, false);
    t.ok(world.slept < 8, "cancellation interrupts the bounded readiness wait");
});

t.test("a cancellation after the readiness observation is checked before nft apply", () => {
    reset();
    let cancelled = false;
    health.sing_box_runtime_ports_ready = () => {
        if (world.slept >= 8)
            cancelled = true;
        return true;
    };
    t.eq(run(() => lifecycle.start(() => !cancelled)).result, 1);
    t.ok(cancelled);
    t.ok(index(world.events, "nft applied") < 0);
    t.eq(world.pid, 0);
});

t.test("Stop cancels pending intent before waiting for lifecycle and releases the request lock", () => {
    running();
    start_request.begin();
    let acquire = lock.acquire_wait;
    let observed = false;
    lock.acquire_wait = (path, owner, timeout, grace) => {
        if (path == lifecycle.paths.lock) {
            observed = true;
            t.eq(start_request.token(), "");
            t.eq(lock.held(start_request.paths.lock), false);
        }
        return acquire(path, owner, timeout, grace);
    };
    let result = run(() => lifecycle.stop());
    lock.acquire_wait = acquire;
    t.eq(result.result, 0);
    t.ok(observed);
    t.eq(world.pid, 0);
});

t.test("Disable cancels retry without stopping an already healthy runtime", () => {
    running();
    lifecycle.enable();
    start_request.begin();
    t.eq(lifecycle.disable(), 0);
    t.eq(start_request.token(), "");
    t.eq(world.events, []);
    t.eq(world.pid, 4242);
    t.ok(world.network);
    finish();
});

t.test("Stop and Disable expose failed cancellation instead of reporting success", () => {
    for (let action in [ "stop", "disable" ]) {
        running();
        lifecycle.enable();
        let token = start_request.begin();
        let unlink = fs.unlink;
        fs.unlink = (path) => path == start_request.paths.pending ? false : unlink(path);
        let result = stub.capture(() => lifecycle[action]());
        fs.unlink = unlink;
        t.eq(result.result, 1, action);
        t.eq(start_request.token(), token);
        if (action == "disable") {
            t.eq(world.events, []);
            t.eq(fs.readlink(start_request.paths.autostart), "../init.d/loki");
        }
        else
            t.eq(world.pid, 0, "Stop still cleans up the current runtime");
        finish();
    }
});

t.test("applying is durable before worker registration, service, config, bridge and nft mutations", () => {
    reset();
    let observed = [];
    world.on_mutation = (step) => {
        let state = context.read().model;
        t.eq(state.phase, "applying", step);
        t.eq(state.active, null, step);
        push(observed, step);
    };
    world.on_apply = () => t.eq(context.read().model.phase, "applying");
    t.eq(run(() => lifecycle.start()).result, 0);
    t.eq(observed, [ "worker", "bridge", "service", "config" ]);
    let state = context.read().model;
    t.eq(state.phase, "ready");
    t.eq(state.active.generation, world.worker_generation);
    t.eq([ state.active.pid, state.active.start_ticks ], [ "4242", "100" ]);
});

function interrupt_apply() {
    let active = context.read().model.active;
    let candidate = { ...active, generation: credential.generate() };
    for (let key in [ "pid", "start_ticks", "command" ]) delete candidate[key];
    t.ok(context.write({ schema: 1, phase: "applying", active, candidate }));
    return candidate;
}

t.test("Start and automatic reload cannot finish an interrupted apply from saved UCI", () => {
    for (let reason in [ null, "pending", "on_config_change", "interface_up:wan" ]) {
        running({ invalid: true, config_fails: true, build_fails: true });
        let candidate = interrupt_apply();
        let result = run(() => reason == null ? lifecycle.start() : lifecycle.reload(reason));
        t.eq(result.result, 1);
        t.eq(world.events, []);
        t.eq(world.migration_checks ?? 0, 0);
        t.eq(context.read().model.candidate.generation, candidate.generation);
        t.eq([ world.pid, world.network ], [ 4242, true ]);
    }
});

t.test("explicit Apply or completed Stop then Start can replace an interrupted generation", () => {
    for (let action in [ "apply", "stop-start" ]) {
        running();
        let interrupted = interrupt_apply();
        if (action == "apply")
            t.eq(stub.capture(() => lifecycle.reload("manual")).result, 0);
        else {
            t.eq(stub.capture(() => lifecycle.stop()).result, 0);
            t.eq(context.read().model.phase, "stopped");
            t.eq(stub.capture(() => lifecycle.start()).result, 0);
        }
        t.eq(context.read().model.phase, "ready");
        t.ok(context.read().model.active.generation != interrupted.generation);
        finish();
    }
});

t.test("ready commit failure cleans runtime and never promotes its candidate", () => {
    reset();
    let write = context.write;
    context.write = (value) => value.phase == "ready" ? false : write(value);
    let result = stub.capture(() => lifecycle.start());
    context.write = write;
    finish();
    t.eq(result.result, 1);
    t.eq([ world.pid, world.network ], [ 0, false ]);
    t.eq(context.read().model.phase, "stopped");
    t.ok(fs.lstat(lifecycle.paths.planned_stop) != null);
});

t.test("a stop that cannot revoke worker permission changes no running component", () => {
    running();
    fs.mkdir(lifecycle.paths.planned_stop);
    t.eq(run(() => lifecycle.stop()).result, 1);
    t.eq(world.events, []);
    t.eq([ world.pid, world.network ], [ 4242, true ]);
    t.eq(context.read().model.phase, "ready");
});

t.test("repair rebinds a confirmed generation to the respawned core but refuses a changed config digest", () => {
    running({ worker_stale: true, invalid: true, config_fails: true, build_fails: true });
    let before = context.read().model.active;
    world.pid = 5151; world.ticks = 777;
    t.eq(stub.capture(() => lifecycle.start()).result, 0);
    let rebound = context.read().model.active;
    t.eq([ rebound.generation, rebound.sections, rebound.config_digest ],
        [ before.generation, before.sections, before.config_digest ]);
    t.eq([ rebound.pid, rebound.start_ticks ], [ "5151", "777" ]);
    t.eq(world.events, [ "rule-set worker started" ]);
    world.events = []; world.digest_mismatch = true;
    t.eq(run(() => lifecycle.start()).result, 1);
    t.eq(world.events, []);
    t.eq(context.read().model.active, rebound);
});

t.test("WAN routing repair uses the confirmed config path without following saved UCI B", () => {
    running({ routing_lost: true, bound: [ "applied0" ] });
    let active = context.read().model.active;
    fixture.seed({ settings: { config_path: world.dir + "/saved-B.json" } });
    t.eq(run(() => lifecycle.restore_routing()).result, true);
    t.eq(world.bound_path, active.config_path);
    t.eq(context.read().model.active.generation, active.generation);
});

t.test("an unsafe prepared config directory leaves applied A and its generation unchanged", () => {
    running();
    let before = fs.readfile(context.paths.base + "/rulesets/context.json");
    let shared = world.dir + "/shared";
    fs.mkdir(shared, 0700); fs.chmod(shared, 0777);
    fixture.seed({ settings: fixture.settings({ config_format: "loki", config_version: "2.0.0",
        config_path: shared + "/new/config.json", cache_path: world.dir + "/private/cache.db" }) });
    runtime.prepare_config = real_prepare_config;
    t.eq(run(() => lifecycle.reload("manual")).result, 1);
    t.eq(world.events, []);
    t.eq([ world.pid, world.network ], [ 4242, true ]);
    t.eq(fs.readfile(context.paths.base + "/rulesets/context.json"), before);
    t.eq(fs.lstat(shared + "/new"), null);
});

t.test("queued service changes cannot pass a newer update lease", () => {
    let update = require("service.update");
    let allowed = update.allowed, acquire = lock.acquire_wait;
    for (let action in [ lifecycle.start, lifecycle.stop, () => lifecycle.reload("manual"), lifecycle.enable, lifecycle.disable ]) {
        running();
        let token = start_request.begin();
        let before = fs.readfile(context.paths.base + "/rulesets/context.json");
        update.allowed = () => false;
        let result = run(action);
        update.allowed = allowed;
        t.eq(result.result, 1);
        t.eq([ world.pid, world.network, world.events, start_request.token() ], [ 4242, true, [], token ]);
        t.eq(fs.readfile(context.paths.base + "/rulesets/context.json"), before);
        t.eq(fs.lstat(lifecycle.paths.rc_dir + "/S99loki"), null);
        t.eq(lock.held(lifecycle.paths.lock), false);
    }
    running();
    lock.acquire_wait = (path, owner, timeout) => {
        let acquired = acquire(path, owner, timeout);
        if (path == lifecycle.paths.lock) update.allowed = () => false;
        return acquired;
    };
    let result = run(() => lifecycle.reload("manual"));
    lock.acquire_wait = acquire;
    update.allowed = allowed;
    t.eq(result.result, 1);
    t.eq(world.events, []);
    t.eq(lock.held(lifecycle.paths.lock), false);
});

t.test("an update snapshot refuses saved B and never stops or reapplies running A", () => {
    let read_credential = credential.current;
    credential.current = () => digest;
    for (let difference in [ "none", "config", "path", "rules", "failure" ]) {
        running();
        let before = fs.readfile(context.paths.base + "/rulesets/context.json");
        let fingerprint = runtime.fingerprint;
        runtime.fingerprint = (text) => difference == "config" && text == "saved-B" || difference == "rules" && text == world.script
            ? sprintf("%064x", 91) : digest;
        runtime.prepare_config = () => {
            if (difference == "failure") die("synthetic-private-snapshot-data");
            return { path: world.dir + (difference == "path" ? "/saved-B.json" : "/core-config.json"), text: "saved-B" };
        };
        let result = run(() => lifecycle.update_snapshot()).result;
        runtime.fingerprint = fingerprint;
        t.eq(result.error, difference == "none" ? null : difference == "failure"
            ? "update-service-snapshot-failed" : "update-saved-config-not-applied", difference);
        if (difference == "none") t.eq(result.running, true);
        t.excludes(sprintf("%J", result), "synthetic-private-snapshot-data");
        t.eq([ world.events, world.pid, world.network ], [ [], 4242, true ]);
        t.eq(fs.readfile(context.paths.base + "/rulesets/context.json"), before);
        t.eq(lock.held(lifecycle.paths.lock), false);
    }
    credential.current = read_credential;
});

t.test("a stopped update snapshot creates no runtime and preserves the autostart decision", () => {
    reset();
    let result = run(() => lifecycle.update_snapshot()).result;
    t.eq(result, { running: false, enabled: false, cache_path: world.dir + "/private/cache.db" });
    t.eq(world.events, []);
    t.eq(fs.lstat(world.dir + "/private"), null);
});

t.test("cold Start and Apply refuse admission before migration, core or network changes", () => {
    for (let action in [ lifecycle.start, () => lifecycle.reload("manual") ]) {
        reset({ admission_error: "preflight-dns-pending-unverified" });
        let before = fs.readfile(lifecycle.paths.config);
        let result = run(action);
        t.eq(result.result, 1);
        t.eq(world.events, []);
        t.eq(world.migration_checks ?? 0, 0);
        t.eq([ world.pid, world.network ], [ 0, false ]);
        t.eq(fs.readfile(lifecycle.paths.config), before);
        t.eq(fs.lstat(world.dir + "/core-config.json"), null);
        t.ok(index(join("\n", world.logs), "preflight-dns-pending-unverified") >= 0);
        reset();
        t.eq(run(action).result, 0, "an explicit retry uses a new admission result");
        t.eq(world.network, true);
    }
});

t.test("an already running confirmed generation does not repeat cold-start admission", () => {
    running();
    require("service.update").start_admission = () => die("unexpected-cold-start-admission");
    t.eq(run(lifecycle.start).result, 0);
    t.eq([ world.pid, world.network ], [ 4242, true ]);
});

t.done();
