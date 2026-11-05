// Modified for LoKi on 2026-11-03: cover private cache creation and unsafe custom paths.
// Modified for LoKi on 2026-11-01: cover LAN prefix discovery and conservative PTR fallback.
let t = require("t");
let stub = require("stub");
let fixture = require("fixture");
let fs = require("fs");
let uci = require("uci");
let core_uci = require("core.uci");
let packages = require("core.packages");
let runtime = require("singbox.runtime");
let cli = require("service.cli");

require("service.gateway_secret").load = () => fixture.CONTROLLER_SECRET;

function configuration(dir, extra) {
    fs.chmod(dir, 0700);
    return {
        settings: fixture.settings({
            config_path: dir + "/etc/loki-core/config.json",
            cache_path: dir + "/tmp/loki-core/cache.db",
            service_listen_address: "127.0.0.1",
            ...(extra ?? {})
        }),
        section: [ { ".name": "main", action: "connection" } ],
        connection_link: fixture.links("main", [ "vless://u@a.example:443#A" ])
    };
}

let logs = [];
const LAN_ADDRESSES = "2: br-lan    inet 192.168.1.1/24 brd 192.168.1.255 scope global br-lan\\\n" +
    "2: br-lan    inet6 2001:db9:abcd:10::1/64 scope global\\\n";

function tools(extra) {
    logs = [];
    stub.commands([
        stub.logger(logs),
        ...(extra ?? []),
        [ "ip -o addr show dev", { stdout: LAN_ADDRESSES } ]
    ]);
}

// pgrep over a process table: -x by the process name, -f by the whole command line.
function processes(command_lines) {
    return [ "pgrep", (argv) => {
        let hit = argv[1] == "-x"
            ? filter(command_lines, (line) => replace(split(line, " ")[0], /.*\//, "") == argv[2])
            : filter(command_lines, (line) => match(line, regexp(argv[2])) != null);
        return { status: length(hit) > 0 ? 0 : 1 };
    } ];
}

t.test("the running core is the service's loki-core run, not a one-shot command", () => {
    tools([ processes([ "/usr/bin/loki-core version", "/usr/bin/loki-core generate warp-profile --json" ]) ]);
    t.eq(runtime.process_running(), false, "the state service asking the version during an install");
    tools([ processes([ "/usr/bin/loki-core run -c /etc/loki-core/config.json -D /usr/share/loki-core" ]) ]);
    t.eq(runtime.process_running(), true);
    stub.restore();
});

const CHECK = /'\/usr\/bin\/loki-core' '--disable-color' '-c' .* 'check'/;

t.test("the one-shot core reads a private configuration which is removed after success or refusal", () => {
    for (let status in [ 0, 1 ]) {
        let dir = stub.tmpdir();
        fixture.seed(configuration(dir));
        let checked_path = "";
        let mode = null;
        let content = "";
        tools([ [ CHECK, (argv) => {
            checked_path = argv[3];
            mode = fs.stat(checked_path)?.mode & 0777;
            content = fs.readfile(checked_path);
            return { status, stdout: status ? "synthetic refusal\n" : "" };
        } ] ]);
        let error = null;
        try { runtime.write_config(true); }
        catch (e) { error = e; }
        stub.restore();
        t.eq(error == null, status == 0);
        t.eq(mode, 0600, "the check input is private before the child sees it");
        t.contains(content, "vless://u@a.example:443#A");
        t.ok(checked_path != "");
        t.eq(fs.lstat(checked_path), null);
        t.eq(fs.stat(dir + "/etc/loki-core/config.json") != null, status == 0);
    }
});

t.test("a core execution exception removes its secret check input and preserves the running file", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    tools([ [ CHECK, {} ] ]);
    runtime.write_config(true);
    let path = dir + "/etc/loki-core/config.json";
    let running = fs.readfile(path);
    fixture.seed(configuration(dir, { log_level: "debug" }));
    let checked_path = "";
    tools([ [ CHECK, (argv) => {
        checked_path = argv[3];
        die("synthetic spawn failure");
    } ] ]);
    let error = null;
    try { runtime.write_config(true); }
    catch (e) { error = e; }
    stub.restore();
    t.ok(error != null);
    t.contains(error.message, "synthetic spawn failure");
    t.ok(checked_path != "");
    let remaining = fs.lstat(checked_path);
    if (remaining != null)
        fs.unlink(checked_path);
    t.eq(remaining, null, "exceptions cannot leave a check input behind");
    t.eq(fs.readfile(path), running);
});

function checks_run() {
    return length(filter(stub.command_lines(), (line) => match(line, / check$/)));
}

t.test("a pre-existing check-input symlink is refused without invoking the core or unlinking foreign data", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    let ticks = [ 3456789, int(require("core.common").own_pid()) ];
    let temporary = sprintf("/tmp/loki-core-check.%d.%d.json", ticks[0], ticks[1]);
    t.eq(fs.lstat(temporary), null, "a unique fixture path is required");
    fs.writefile(dir + "/victim", "foreign-data\n");
    t.ok(fs.symlink(dir + "/victim", temporary));
    tools([ [ CHECK, {} ] ]);
    global.clock = () => ticks;
    let error = null;
    try { runtime.write_config(true); }
    catch (e) { error = e; }
    let commands = checks_run();
    stub.restore();
    let entry = fs.lstat(temporary);
    fs.unlink(temporary);
    t.ok(error != null);
    t.eq(commands, 0);
    t.eq(fs.readfile(dir + "/victim"), "foreign-data\n");
    t.eq(entry?.type, "link", "a refused collision is not ours to delete");
    t.eq(fs.stat(dir + "/etc/loki-core/config.json"), null);
});

t.test("the configuration is written where the service reads it, and only when it changed", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    tools([ [ CHECK, {} ] ]);
    t.eq(runtime.write_config(false), true);
    let written = fs.readfile(dir + "/etc/loki-core/config.json");
    t.eq(json(written).outbounds != null, true);
    t.ok(fs.stat(dir + "/tmp/loki-core")?.type == "directory", "the cache directory exists for the core to open");

    let inode = fs.stat(dir + "/etc/loki-core/config.json").inode;
    t.eq(runtime.write_config(false), false);
    t.eq(fs.stat(dir + "/etc/loki-core/config.json").inode, inode, "an unchanged configuration is not rewritten");
    t.eq(checks_run(), 1, "the core checked the changed configuration, and only that one");
    t.eq(logs, [], "writing the file is a step of the apply, which reports its outcome");
    stub.restore();
});

// The core follows the memory the system can still give with Go's limit; a memory_limit in the
// configuration would fix it instead.
t.test("the written configuration leaves the memory limit to the core", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    tools([ [ CHECK, {} ] ]);
    runtime.write_config(false);
    stub.restore();
    t.eq(json(fs.readfile(dir + "/etc/loki-core/config.json")).experimental.debug, null);
});

t.test("a configuration the core refuses is reported by its first line and never written", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    tools([ [ CHECK, { status: 42, stdout: "\nFATAL[0000] route: missing outbound tag\nmore\n" } ] ]);
    let e = t.throws(() => runtime.write_config(true));
    stub.restore();
    t.eq(e.message, "loki-core refused the generated configuration: FATAL[0000] route: missing outbound tag");
    t.ok(fs.stat(dir + "/etc/loki-core/config.json") == null);
    let prefix = "loki-core-check.";
    t.eq(filter(fs.lsdir("/tmp"), (name) => substr(name, 0, length(prefix)) == prefix && index(name, ".json") > 0), [],
        "the file checked is removed");
});

t.test("a changed configuration the core refuses leaves the file the running core was started with", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    tools([ [ CHECK, {} ] ]);
    runtime.write_config(false);
    let running = fs.readfile(dir + "/etc/loki-core/config.json");
    fixture.seed(configuration(dir, { log_level: "debug" }));
    tools([ [ CHECK, { status: 1, stdout: "FATAL[0000] initialize dns router: validate dns rule[9]\n" } ] ]);
    let e = t.throws(() => runtime.write_config(false));
    stub.restore();
    t.eq(e.message, "loki-core refused the generated configuration: FATAL[0000] initialize dns router: validate dns rule[9]");
    t.eq(fs.readfile(dir + "/etc/loki-core/config.json"), running);
});

t.test("a LAN without an IPv4 address does not change the private controller", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir, { service_listen_address: "" }));
    tools([ [ CHECK, {} ], [ /network\.interface/, { stdout: "{}" } ], [ "ip -4 addr show", { stdout: "" } ] ]);
    t.eq(runtime.listen_address(), "");
    t.eq(logs, [], "a diagnostics check asking for it");
    runtime.write_config(false);
    stub.restore();
    t.eq(logs, []);
    t.eq(json(fs.readfile(dir + "/etc/loki-core/config.json")).experimental.clash_api,
        { external_controller_unix: "/tmp/loki/controller.sock", secret: fixture.CONTROLLER_SECRET });
});

t.test("a private credential failure preserves the existing configuration before any core check", () => {
    let dir = stub.tmpdir();
    let config = configuration(dir);
    fixture.seed(config);
    let path = config.settings.config_path;
    t.ok(require("core.common").ensure_dir(require("core.common").parent_dir(path)));
    t.ok(fs.writefile(path, "previous owned configuration\n") != null);
    tools([ [ CHECK, {} ] ]);
    let provider = require("service.gateway_secret");
    let original = provider.load;
    provider.load = () => { die("Private controller credential unavailable"); };
    let failure;
    try { runtime.write_config(true); }
    catch (e) { failure = e; }
    provider.load = original;
    let checked = checks_run();
    stub.restore();
    t.ok(failure != null);
    t.contains(failure.message, "controller credential unavailable");
    t.eq(checked, 0);
    t.eq(fs.readfile(path), "previous owned configuration\n");
});

t.test("a checked configuration is checked even when it did not change", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    tools([ [ CHECK, {} ] ]);
    runtime.write_config(true);
    runtime.write_config(true);
    t.eq(checks_run(), 2);
    stub.restore();
});

t.test("the service runs the generated file as root, committed only when something changed", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    uci.__seed("loki-core", [ { ".name": "main", ".type": "loki-core", enabled: "0", user: "loki-core", conffile: "/etc/loki-core/config.json" } ]);
    core_uci.reset();
    tools();
    runtime.configure_service();
    core_uci.reset();
    t.eq([ core_uci.get("loki-core.main.enabled"), core_uci.get("loki-core.main.user"), core_uci.get("loki-core.main.conffile") ],
        [ "1", "root", dir + "/etc/loki-core/config.json" ]);
    t.eq(logs, [ "[info] Set up the loki-core service for LoKi: enabled=1, user=root, conffile=" + dir + "/etc/loki-core/config.json" ]);
    let commits = length(uci.__commits());
    runtime.configure_service();
    t.eq(length(uci.__commits()), commits, "a configured service is not committed again");
    t.eq(length(logs), 1, "nor reported again");
    stub.restore();
});

t.test("native UCI failures stop service setup before reporting success or disabling autostart", () => {
    let real_cursor = uci.cursor;
    for (let failure in [ "load", "section", "set", "commit" ]) {
        let dir = stub.tmpdir();
        fixture.seed(configuration(dir));
        let previous = failure == "section" ? [] : [
            { ".name": "main", ".type": "loki-core", enabled: "0", user: "loki-core", conffile: "/etc/loki-core/config.json" }
        ];
        uci.__seed("loki-core", previous);
        previous = uci.__sections("loki-core");
        core_uci.reset();
        tools();
        uci.cursor = (...args) => {
            let c = real_cursor(...args);
            if (failure == "load") {
                let real_load = c.load;
                c.load = (name) => name == "loki-core" ? null : real_load(name);
            }
            else {
                c[failure == "section" ? "set" : failure] = () => null;
            }
            return c;
        };
        let error = null;
        try { runtime.configure_service(); }
        catch (e) { error = e; }
        let commands = stub.command_lines();
        uci.cursor = real_cursor;
        core_uci.reset();
        stub.restore();
        t.ok(error != null, "native " + failure + " failure must abort service setup");
        t.matches(error.message, /^Failed to (create|set|save)/);
        t.eq(uci.__commits(), []);
        t.eq(uci.__sections("loki-core"), previous);
        t.eq(logs, [], "failed setup cannot report completed settings");
        t.eq(commands, [], "failed setup cannot disable the core's autostart");
    }
});

t.test("the devices the core binds are the default interface and every bind_interface of the running file", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    t.eq(runtime.bound_devices(), [], "no file yet");
    fs.mkdir(dir + "/etc");
    fs.mkdir(dir + "/etc/loki-core");
    fs.writefile(dir + "/etc/loki-core/config.json", sprintf("%J", {
        route: { default_interface: "eth1", final: "direct-out" },
        outbounds: [ { type: "direct", tag: "direct-out" }, { type: "direct", tag: "lte", bind_interface: "wwan0" },
            { type: "vless", tag: "json", bind_interface: "eth1", server: "a.example" } ],
        endpoints: [ { type: "wireguard", tag: "ignored", bind_interface: "pppoe-wan" } ]
    }));
    t.eq(runtime.bound_devices(), [ "eth1", "wwan0" ]);
});

t.test("the core version is the package's, with the release spelling", () => {
    let dir = stub.tmpdir();
    packages.paths.opkg_status = dir + "/status";
    fs.writefile(packages.paths.opkg_status, "Package: loki-core\nVersion: 1.13.14~extended~2.5.3~f1\nStatus: install ok installed\n");
    packages.paths.sing_box_version = dir + "/missing";
    stub.commands([ [ "sh -c command -v apk", { status: 1 } ] ]);
    t.eq(runtime.version(), "1.13.14-extended-2.5.3-f1");
    stub.restore();
});

t.test("LAN prefix discovery is limited to configured devices and refreshed on reload", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir, { source_network_interfaces: [ "br-lan", "br-guest", "br-lan" ] }));
    let commands = [];
    tools([ [ CHECK, {} ], [ "ip -o addr show dev", (argv) => {
        push(commands, argv);
        return { stdout: argv[5] == "br-guest" ? "3: br-guest inet 203.0.114.190/25 scope global br-guest\n" : LAN_ADDRESSES };
    } ] ]);
    runtime.write_config(false);
    let path = dir + "/etc/loki-core/config.json";
    let first = json(fs.readfile(path));
    let ptr = filter(first.dns.rules, (r) => r.server == "dnsmasq-server" && r.query_type?.[0] == "PTR")[0];
    t.ok(ptr.domain_regex != null, "known LAN prefixes enable narrow PTR routing");
    t.eq(map(commands, (argv) => argv[5]), [ "br-lan", "br-guest" ], "neither WAN nor duplicate devices are queried");
    t.ok(length(filter(ptr.domain_regex, (pattern) => match("1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.1.0.0.d.c.b.a.9.b.d.0.1.0.0.2.ip6.arpa", regexp(substr(pattern, 4), "i")) != null)) > 0,
        "the public IPv6 prefix reaches the generator");
    tools([ [ CHECK, {} ], [ "ip -o addr show dev", (argv) => ({ stdout: "2: " + argv[5] + " inet 203.0.115.1/24 scope global " + argv[5] + "\n" }) ] ]);
    t.eq(runtime.write_config(false), true, "a changed LAN snapshot changes the generated file");
    t.ok(fs.readfile(path) != sprintf("%J\n", first));
    t.eq(logs, []);
    stub.restore();
});

t.test("failed, empty, malformed or excessive address snapshots retain PTR locally and log no input", () => {
    for (let reply in [ { status: 1, stdout: LAN_ADDRESSES }, { stdout: "" }, { stdout: "malformed secret-fixture" },
        { stdout: "2: br-lan inet 203.0.114.1/33 scope global br-lan\n" },
        { stdout: "2: br-lan inet 2001:db9::1/64 scope global br-lan\n" },
        { stdout: "3: wan inet 203.0.114.1/24 scope global wan\n" },
        { stdout: join("", map([ 1, 2, 3, 4 ], () => sprintf("%20000s", "x"))) } ]) {
        let dir = stub.tmpdir();
        fixture.seed(configuration(dir));
        tools([ [ CHECK, {} ], [ "ip -o addr show dev", reply ] ]);
        runtime.write_config(false);
        let config = json(fs.readfile(dir + "/etc/loki-core/config.json"));
        let ptr = filter(config.dns.rules, (r) => r.server == "dnsmasq-server" && r.query_type?.[0] == "PTR")[0];
        t.eq(ptr.domain_regex, null);
        t.eq(logs, [ "[warn] Cannot determine LAN prefixes; keeping all PTR queries with the local DNS resolver" ]);
        stub.restore();
    }
});

t.test("interface names stay in one quoted argument and a partial snapshot is not trusted", () => {
    let dir = stub.tmpdir();
    let device = "guest;$(id)";
    fixture.seed(configuration(dir, { source_network_interfaces: [ "br-lan", device ] }));
    tools([ [ CHECK, {} ], [ "ip -o addr show dev", (argv) => {
        t.eq(length(argv), 6, "an interface name cannot add a shell command or option");
        return argv[5] == "br-lan" ? { stdout: LAN_ADDRESSES } : { status: 1 };
    } ] ]);
    runtime.write_config(false);
    let commands = filter(stub.calls(), (entry) => entry.argv[0] == "ip");
    t.eq(commands[1].argv[5], device);
    t.contains(commands[1].command, "'guest;$(id)'");
    let config = json(fs.readfile(dir + "/etc/loki-core/config.json"));
    t.eq(filter(config.dns.rules, (r) => r.query_type?.[0] == "PTR")[0].domain_regex, null);
    t.eq(logs, [ "[warn] Cannot determine LAN prefixes; keeping all PTR queries with the local DNS resolver" ]);
    stub.restore();
});

t.test("address discovery bounds device and prefix counts and accepts an explicitly empty device list", () => {
    let devices = [];
    let addresses = "";
    for (let i = 0; i < 257; i++) {
        if (i < 65)
            push(devices, "dev" + i);
        addresses += "2: br-lan inet 203.0." + (114 + int(i / 256)) + "." + (i % 256) + "/32 scope global br-lan\n";
    }
    for (let sample in [ { devices, output: LAN_ADDRESSES }, { devices: [ "br-lan" ], output: addresses }, { devices: [], output: null } ]) {
        let dir = stub.tmpdir();
        fixture.seed(configuration(dir, { source_network_interfaces: sample.devices }));
        tools([ [ CHECK, {} ], [ "ip -o addr show dev", { stdout: sample.output } ] ]);
        runtime.write_config(false);
        let config = json(fs.readfile(dir + "/etc/loki-core/config.json"));
        let ptr = filter(config.dns.rules, (r) => r.query_type?.[0] == "PTR")[0];
        t.eq(ptr.domain_regex != null, length(sample.devices) == 0);
        t.eq(length(logs), length(sample.devices) == 0 ? 0 : 1);
        stub.restore();
    }
});

t.test("the runtime creates a private cache directory under the effective process owner", () => {
    let dir = stub.tmpdir();
    fixture.seed(configuration(dir));
    tools([ [ CHECK, {} ] ]);
    runtime.write_config(false);
    stub.restore();
    t.eq(fs.stat(dir + "/tmp/loki-core").mode & 0777, 0700, "the directory cannot expose cached subscription bodies");
});

t.test("an unsafe custom cache parent is refused without running the core or changing its mode", () => {
    let dir = stub.tmpdir();
    fs.mkdir(dir + "/public-cache", 0755);
    fs.chmod(dir + "/public-cache", 0755);
    fixture.seed(configuration(dir, { cache_path: dir + "/public-cache/cache.db" }));
    tools([ [ CHECK, {} ] ]);
    let error = t.throws(() => runtime.write_config(false));
    let commands = stub.command_lines();
    stub.restore();
    t.ok(index(error.message, dir) < 0, "the reason does not expose the custom path");
    t.eq(commands, [], "unsafe storage is refused before command execution");
    t.eq(fs.stat(dir + "/public-cache").mode & 0777, 0755, "a selected directory is not chmodded");
    t.eq(fs.stat(dir + "/etc/loki-core/config.json"), null);
});

t.done();
