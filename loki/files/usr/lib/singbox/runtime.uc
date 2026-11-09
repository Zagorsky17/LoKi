// Modified for LoKi on 2026-11-03: validate private cache paths before configuration writes.
// Modified for LoKi on 2026-11-03: product labels in user-facing messages.
// Modified for LoKi on 2026-11-01: preserve LAN reverse zones while routing external PTR by DNS policy.
let fs = require("fs");
let common = require("core.common");
let cache_path = require("core.cache_path");
let exec = require("core.exec");
let uci = require("core.uci");
let singbox_constants = require("singbox.constants");
let packages = require("core.packages");
let generator = require("singbox.generator");
let core_ip = require("core.ip");
let gateway_secret = require("service.gateway_secret");
let file_checks = require("service.preflight_files");
let health = require("service.health");

const CONFIG_NAME = "loki";

function settings() {
    return uci.get_all(CONFIG_NAME, "settings") ?? {};
}

function config_parts(path) {
    if (type(path) != "string" || !match(path, /^\/[ -~]+$/) || index(path, "\u0000") >= 0) return null;
    let parts = split(substr(path, 1), "/");
    for (let part in parts) if (part == "" || part == "." || part == "..") return null;
    return parts;
}

function protected_parents(path, allow_missing) {
    let parts = config_parts(path);
    if (parts == null) return null;
    let parents = [];
    let current = "";
    let owner = fs.stat("/proc/self").uid;
    fs.lstat("");
    let missing = fs.error();
    if (missing == null) return null;
    for (let i = 0; i < length(parts) - 1; i++) {
        current += "/" + parts[i];
        let node = fs.lstat(current);
        let failure = fs.error();
        if (node == null && allow_missing && failure == missing) return parents;
        if (node?.type != "directory" || (node.uid != owner && node.uid != 0) ||
            ((node.mode & 0022) != 0 && !(node.uid == 0 && (node.mode & 01000) != 0))) return null;
        push(parents, [ current, node ]);
    }
    return parents;
}

// Loki starts loki-core itself; the core's own autostart would start it without the rules
// around it.
function configure_service(config_path) {
    if (!uci.exists("loki-core.main") && !uci.set_section("loki-core.main", "loki-core"))
        die("Failed to create the loki-core service section in /etc/config/loki-core");

    let changed = [];
    for (let option in [ [ "enabled", "1" ], [ "user", "root" ], [ "conffile", config_path ?? common.option(settings(), "config_path", "") ] ]) {
        if (trim(uci.get("loki-core.main." + option[0])) == option[1])
            continue;
        if (!uci.set("loki-core.main." + option[0], option[1]))
            die("Failed to set loki-core.main." + option[0] + " in /etc/config/loki-core");
        push(changed, option[0] + "=" + option[1]);
    }
    if (length(changed) > 0) {
        if (!uci.commit("loki-core"))
            die("Failed to save the loki-core service settings in /etc/config/loki-core");
        exec.log("info", "Set up the loki-core service for LoKi: " + join(", ", changed));
    }

    if (fs.stat("/etc/rc.d/S99loki-core") == null)
        return;
    if (exec.ok([ "/etc/init.d/loki-core", "disable" ]))
        exec.log("info", "Disabled the loki-core autostart; LoKi starts loki-core itself");
    else
        exec.log("warn", "Failed to disable the loki-core autostart; at boot loki-core may start without LoKi");
}

function interface_ipv4_address(name) {
    let status = common.parse_json(exec.output([ "ubus", "call", "network.interface." + name, "status" ]));
    return common.as_string(status?.["ipv4-address"]?.[0]?.address);
}

function device_ipv4_address(device) {
    let matched = match(exec.output([ "ip", "-4", "addr", "show", "dev", device ]) ?? "", /inet[ \t]+([0-9.]+)\//);
    return matched ? matched[1] : "";
}

// The address the service inbounds listen on: the one configured, else the LAN's.
function listen_address(values) {
    values ??= settings();
    let configured = common.option(values, "service_listen_address", "");
    if (configured != "")
        return configured;

    let address = interface_ipv4_address("lan");
    for (let name in common.words(common.option(values, "source_network_interfaces", "br-lan"))) {
        if (address != "")
            break;
        address = interface_ipv4_address(name) || device_ipv4_address(name);
    }
    return address;
}

function local_prefixes(values) {
    let devices = common.words(common.option(values, "source_network_interfaces", "br-lan"));
    if (length(devices) > 64)
        return null;
    let seen = {};
    let prefixes = {};
    for (let device in devices) {
        if (seen[device])
            continue;
        seen[device] = true;
        let pipe = fs.popen(exec.command_line([ "ip", "-o", "addr", "show", "dev", device ]) + " 2>/dev/null", "r");
        if (!pipe)
            return null;
        // Bound each snapshot before expanding its addresses into reverse-zone matchers.
        let output = pipe.read(65537);
        let status = pipe.close();
        if (status != 0 || type(output) != "string" || output == "" || length(output) > 65536)
            return null;
        for (let line in split(trim(output), "\n")) {
            let entry = match(line, /^[0-9]+:[ \t]+([^ \t]+)[ \t]+(inet6?)[ \t]+([^ \t]+)([ \t]|$)/);
            if (entry == null || split(entry[1], "@")[0] != device || !core_ip.valid_ip_cidr(entry[3]) ||
                core_ip.ip_family(entry[3]) != (entry[2] == "inet" ? 4 : 6))
                return null;
            prefixes[entry[3]] = true;
            if (length(prefixes) > 256)
                return null;
        }
    }
    return sort(keys(prefixes));
}

// While mwan3 has an enabled interface and runs or will start, it owns egress routing, which a
// pinned output interface bypasses.
function mwan3_active() {
    if (((fs.stat("/etc/init.d/mwan3")?.mode ?? 0) & 0111) == 0 || (fs.stat("/etc/config/mwan3")?.size ?? 0) == 0)
        return false;
    if (length(filter(uci.section_objects("mwan3", "interface"), (s) => common.option(s, "enabled", "0") == "1")) == 0)
        return false;
    return exec.ok([ "/etc/init.d/mwan3", "status" ]) || exec.ok([ "/etc/init.d/mwan3", "enabled" ]);
}

// The first line a failed core command printed, which is its fatal error.
function failure_reason(result) {
    return filter(split(result.output, "\n"), (line) => trim(line) != "")[0] ?? "exit status " + result.status;
}

function check(text, binary) {
    let now = clock();
    let path = sprintf("/tmp/loki-core-check.%d.%d.json", now[0], now[1]);
    if (!common.write_private_file(path, text))
        die("Failed to write the generated loki-core configuration to " + path);
    let guard = path + ".guard";
    if (!fs.mkdir(guard, 0700)) {
        fs.unlink(path);
        die("Failed to create the private loki-core check watchdog directory");
    }
    // Reuse the RPC worker's guarded process group: stock BusyBox need not enable timeout.
    let script = 'umask 077; /bin/busybox mkfifo "$0/ready" || exit 125; exec 3<>"$0/ready"; ' +
        '( exec >/dev/null 2>&1; trap \'kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; exit 0\' TERM; ' +
        '/bin/busybox sleep 10 & sleeper=$!; printf "ready\\n" >&3; exec 3>&-; ' +
        'wait "$sleeper"; kill -KILL -- "-$$" ) & guard=$!; ' +
        'read -r -t 1 ready <&3; ready_status=$?; exec 3>&-; ' +
        'code=125; if [ "$ready_status" = 0 ] && [ "$ready" = ready ]; then "$@"; code=$?; fi; ' +
        'kill "$guard" 2>/dev/null; wait "$guard" 2>/dev/null; exit "$code"';
    let result;
    try {
        let command = binary == null ? [ "/usr/bin/loki-core" ] :
            [ "/bin/busybox", "ash", "-c", 'ulimit -S -v unlimited || exit 125; exec "$@"', "sh", binary ];
        result = exec.combined([ "/bin/busybox", "setsid", "/bin/busybox", "ash", "-c", script, guard,
            ...command, "--disable-color", "-c", path, "check" ], 65536);
    }
    catch (e) {
        fs.unlink(path);
        fs.unlink(guard + "/ready");
        fs.rmdir(guard);
        die(e.message);
    }
    fs.unlink(path);
    fs.unlink(guard + "/ready");
    fs.rmdir(guard);
    if (result.output_limit)
        die("loki-core configuration check exceeded its output limit");
    if (common.signal_from_status(result.status) == 9)
        die("loki-core configuration check was interrupted or exceeded its time limit");
    if (result.status == 0)
        return;
    die("loki-core refused the generated configuration: " + failure_reason(result));
}

// The file is written only once the core accepted it. Returns whether it changed; a start
// checks it regardless, since the core may have been replaced.
function prepare_config(checked, model) {
    let values = model == null ? settings() : filter(model.sections, (section) => section[".type"] == "settings")[0] ?? {};
    let path = common.option(values, "config_path", "");
    if (path == "")
        die("The loki-core configuration file path is not set in Settings");
    if (config_parts(path) == null)
        die("Use an absolute canonical loki-core configuration file path");
    if (protected_parents(path, true) == null)
        die("The loki-core configuration directory is unsafe or unavailable");

    // The private tmpfs directory is created only after the read-only path gate.
    cache_path.ensure(values);

    let output_interface = common.option(values, "output_network_interface", "");
    if (output_interface != "" && mwan3_active())
        exec.log("warn", "mwan3 is active, but the output interface is set to '" + output_interface + "': loki-core sends its traffic out of it, past mwan3");

    let text;
    try {
        let prefixes = local_prefixes(values);
        if (prefixes == null)
            exec.log("warn", "Cannot determine LAN prefixes; keeping all PTR queries with the local DNS resolver");
        text = sprintf("%J\n", generator.build({ local_prefixes: prefixes,
            controller_secret: gateway_secret.load() }, model));
    }
    catch (e) {
        die("Failed to generate the loki-core configuration: " + e.message);
    }
    let unchanged = fs.readfile(path) == text;
    if (checked || !unchanged)
        check(text);

    return { path, text, changed: !unchanged };
}

function install_config(prepared) {
    if (protected_parents(prepared.path, true) == null ||
        !common.ensure_dir(common.parent_dir(prepared.path)) || protected_parents(prepared.path) == null)
        die("The loki-core configuration directory is unsafe or unavailable");
    if (!prepared.changed)
        return false;
    if (!common.write_file_atomic(prepared.path, prepared.text))
        die("Failed to write the loki-core configuration to " + prepared.path);
    return true;
}

function write_config(checked) {
    return install_config(prepare_config(checked));
}

// Pin the private file while the trusted checksum tool reads its descriptor, not a changed pathname.
function file_digest(path, metadata) {
    let file;
    let digest = null;
    try {
        let parents = protected_parents(path);
        let before = fs.lstat(path);
        if (metadata != null && (type(metadata) != "object" || index([ 0600, 0644, 0700, 0755 ], metadata.mode) < 0 ||
            type(metadata.size) != "int" || metadata.size < 0 || metadata.size > 536870912)) return null;
        if (parents == null || before?.type != "file" || before.uid != fs.stat("/proc/self").uid ||
            (before.mode & 07777) != (metadata?.mode ?? 0600) || before.nlink != 1 ||
            metadata != null && before.size != metadata.size) return null;
        file = fs.open(path, "re");
        if (file == null) return null;
        let descriptor = "/proc/" + common.own_pid() + "/fd/" + file.fileno();
        if (file_checks.same_node(before, fs.stat(descriptor))) {
            let result = exec.capture([ "/bin/busybox", "sha256sum", descriptor ]);
            let found = match(result.stdout, /^([a-f0-9]{64})  \/proc\/[0-9]+\/fd\/[0-9]+\n$/);
            if (result.status == 0 && found != null && file_checks.same_node(before, fs.stat(descriptor)) &&
                file_checks.same_node(before, fs.lstat(path))) {
                digest = found[1];
                for (let parent in parents) {
                    let now = fs.lstat(parent[0]);
                    if (now?.type != "directory" || now.inode != parent[1].inode ||
                        now.dev.major != parent[1].dev.major || now.dev.minor != parent[1].dev.minor ||
                        now.uid != parent[1].uid || now.mode != parent[1].mode) digest = null;
                }
            }
        }
    }
    catch (e) {}
    try { if (file == null || file.close() !== true) return null; }
    catch (e) { return null; }
    return digest;
}

function fingerprint(text) {
    let path = "/tmp/loki-core-digest." + gateway_secret.generate() + ".tmp";
    if (!common.write_private_file(path, text)) return null;
    let digest = file_digest(path);
    if (!fs.unlink(path)) return null;
    return digest;
}

function identity(config_path) {
    try {
        let instances = health.sing_box_service_list(true)?.["loki-core"]?.instances;
        if (type(instances) != "object") return null;
        let result = null;
        for (let _, instance in instances) {
            if (instance.running !== true) continue;
            if (result != null || type(instance.pid) != "int" || instance.pid <= 0 ||
                type(instance.command) != "array" || length(instance.command) < 4 ||
                instance.command[0] != "/usr/bin/loki-core" || instance.command[1] != "run" ||
                instance.command[2] != "-c" || instance.command[3] != config_path) return null;
            let pid = "" + instance.pid;
            let ticks = health.start_ticks(pid);
            if (ticks == null || fs.readlink("/proc/" + pid + "/exe") != "/usr/bin/loki-core") return null;
            let file = fs.open("/proc/" + pid + "/cmdline", "re");
            if (file == null) return null;
            let command;
            let valid = false;
            try {
                fs.error();
                command = file.read(65537);
                valid = file.error() == null && type(command) == "string" && length(command) <= 65536 &&
                    command == join("\u0000", instance.command) + "\u0000" &&
                    health.start_ticks(pid) == ticks;
            }
            catch (e) {}
            try { if (file.close() !== true) return null; }
            catch (e) { return null; }
            if (!valid) return null;
            result = { pid, start_ticks: "" + ticks, command: instance.command };
        }
        return result;
    }
    catch (e) { return null; }
}

// The devices the running configuration binds the core's own sockets to.
function bound_devices(config_path) {
    let config = common.read_json_file(config_path ?? common.option(settings(), "config_path", ""));
    let bound = map(config?.outbounds ?? [], (item) => item?.bind_interface);
    let devices = [];
    for (let name in [ config?.route?.default_interface, ...bound ])
        if (type(name) == "string" && name != "" && index(devices, name) < 0)
            push(devices, name);
    return sort(devices);
}

function version() {
    let value = packages.version("loki-core") || trim(fs.readfile(packages.paths.sing_box_version) ?? "");
    return replace(value, /~/g, "-");
}

// The service's core only: the state service runs the binary for its version on every restart.
function process_running() {
    return exec.ok([ "pgrep", "-f", "^/usr/bin/loki-core[[:space:]]+run([[:space:]]|$)" ]);
}

return {
    configure_service, check, prepare_config, install_config, write_config, file_digest, fingerprint, identity, listen_address, device_ipv4_address,
    mwan3_active, bound_devices, version, process_running
};
