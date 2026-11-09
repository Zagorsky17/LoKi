let fs = require("fs");
let exec = require("core.exec");
let files = require("service.preflight_files");

const RESPONSE_LIMIT = 262144;
const ENTRY_LIMIT = 4096;
const KNOWN = { loki: true, "loki-state": true, "loki-core": true,
    forkop: false, "forkop-state": false, "sing-box": false, podkop: false };

function observation(kind, object, state, reason) {
    return { kind, object, state, reason };
}

function parse(data, details) {
    if (type(data) != "string" || length(data) > RESPONSE_LIMIT || index(data, "\u0000") >= 0)
        return { error: "service-response-invalid" };
    let value;
    try { value = json(data); }
    catch (e) { return { error: "service-response-json-invalid" }; }
    if (type(value) != "object" || length(keys(value)) > ENTRY_LIMIT)
        return { error: "service-response-shape-invalid" };
    let known = [], dns = [], registrations = [];
    let count = 0;
    for (let name in sort(keys(value))) {
        let service = value[name];
        if (name == "" || length(name) > 255 || index(name, "\u0000") >= 0 || type(service) != "object" ||
            (exists(service, "autostart") && type(service.autostart) != "bool") ||
            (exists(service, "triggers") && type(service.triggers) != "array") ||
            (exists(service, "instances") && type(service.instances) != "object"))
            return { error: "service-response-shape-invalid" };
        let active = false;
        let pending = service.triggers != null && length(service.triggers) > 0;
        for (let id, instance in service.instances || {}) {
            count++;
            if (count > ENTRY_LIMIT || id == "" || length(id) > 255 || index(id, "\u0000") >= 0 ||
                type(instance) != "object" || type(instance.running) != "bool" ||
                (exists(instance, "respawn") && type(instance.respawn) != "object") ||
                (instance.running && (type(instance.pid) != "int" || instance.pid <= 0 || instance.pid > 4294967295)) ||
                (!instance.running && exists(instance, "pid")))
                return { error: "service-response-shape-invalid" };
            if (name == "dnsmasq" && instance.running) {
                let command = instance.command;
                let valid = type(command) == "array" && length(command) == 6 && command[0] == "/usr/sbin/dnsmasq" &&
                    command[1] == "-C" && type(command[2]) == "string" && match(command[2], /^\/var\/etc\/dnsmasq\.conf\.[A-Za-z0-9_]+$/) &&
                    command[3] == "-k" && command[4] == "-x" && command[5] == "/var/run/dnsmasq/dnsmasq." + substr(command[2], 22) + ".pid";
                push(dns, valid ? { pid: instance.pid, config: command[2] } : { error: "dns-runtime-command-unverified" });
            }
            active = active || instance.running;
            pending = pending || instance.respawn != null;
        }
        if (exists(KNOWN, name))
            push(known, { name, active, pending });
        if (details === true) push(registrations, { name, active, pending: pending || service.autostart === true });
    }
    let result = { known, services: length(keys(value)), instances: count, dns };
    // Full commands and environment stay inside collection, never in public observations.
    if (details === true) { result.registrations = registrations; result.snapshot = sprintf("%J", value); }
    return result;
}

function probe() {
    let result = exec.deadline([ "/usr/bin/env", "-i", "PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C",
        "ubus", "call", "service", "list", '{"verbose":true}' ], 5, RESPONSE_LIMIT);
    if (result.output_limit) return { error: "service-response-size-limit" };
    if (type(result.status) != "int" || result.status != 0 || result.output == "") return { error: "service-query-failed" };
    return parse(result.output, true);
}


function dns_sockets(root, pid) {
    let directory = (root == "/" ? "" : root) + "/proc/" + pid + "/fd";
    let handle = fs.opendir(directory), inodes = {}, count = 0, failed = false;
    if (handle == null) die("dns-runtime-sockets-unverified");
    try {
        while (true) {
            fs.error(); let entry = handle.read(), error = fs.error();
            if (entry == null) { if (error != null) failed = true; break; }
            if (++count > ENTRY_LIMIT) die("dns-runtime-sockets-unverified");
            if (entry == "." || entry == "..") continue;
            if (!match(entry, /^[0-9]+$/)) die("dns-runtime-sockets-unverified");
            let value = fs.readlink(directory + "/" + entry);
            if (value == null) die("dns-runtime-sockets-unverified");
            let socket = match(value, /^socket:\[([0-9]+)\]$/);
            if (socket != null) inodes[socket[1]] = true;
        }
    }
    catch (e) { failed = true; }
    try { if (handle.close() !== true) failed = true; }
    catch (e) { failed = true; }
    if (failed) die("dns-runtime-sockets-unverified");
    let owned = [], tcp = false, udp = false;
    for (let name in [ "tcp", "tcp6", "udp", "udp6" ]) {
        let table = require("service.preflight_listeners").read_table(root == "/" ? "" : root, name);
        if (table.error != null) die("dns-runtime-sockets-unverified");
        for (let binding in table.bindings) {
            if (binding.port != 53 || !inodes[binding.inode] || binding.remote_port != 0 || !match(binding.remote_address, /^0+$/)) continue;
            push(owned, name + ":" + sprintf("%J", binding));
            if (substr(name, 0, 3) == "tcp") tcp = true; else udp = true;
        }
    }
    if (!tcp || !udp) die("dns-runtime-sockets-unverified");
    return sort(owned);
}

function dns_binary(root, name, executable) {
    let paths = {}; paths[name] = "file";
    if (files.collect(root, paths)[0].reason != "candidate-existing-file-origin-unverified") return false;
    let node = fs.lstat((root == "/" ? "" : root) + name);
    return node != null && (node.mode & 0111) != 0 && files.same_node(node, executable);
}

function dns_children(root, pid) {
    let path = (root == "/" ? "" : root) + "/proc/" + pid + "/task/" + pid + "/children";
    let before = fs.lstat(path);
    if (before?.type != "file" || before.nlink != 1 || (before.mode & 0022) != 0 || before.size > 4096)
        die("dns-runtime-supervisor-unverified");
    let file = fs.open(path, "re"), data = null, failed = false;
    if (file == null) die("dns-runtime-supervisor-unverified");
    try {
        if (!files.same_node(before, fs.stat("/proc/self/fd/" + file.fileno()))) failed = true;
        else {
            // Procfs children files report size zero; bound the actual read.
            fs.error();
            data = file.read(4097);
            if (file.error() != null || !files.same_node(before, fs.stat("/proc/self/fd/" + file.fileno())) ||
                !files.same_node(before, fs.lstat(path))) failed = true;
        }
    }
    catch (e) { failed = true; }
    try { if (file.close() !== true) failed = true; }
    catch (e) { failed = true; }
    if (failed || type(data) != "string" || length(data) > 4096 || index(data, "\u0000") >= 0) die("dns-runtime-supervisor-unverified");
    let children = trim(data) == "" ? [] : split(trim(data), /[ \t\n]+/), seen = {};
    if (length(children) > 16) die("dns-runtime-supervisor-limit");
    for (let child in children) {
        if (!match(child, /^[1-9][0-9]{0,9}$/) || int(child) > 2147483647 || seen[child]) die("dns-runtime-supervisor-unverified");
        seen[child] = true;
    }
    return sort(children);
}

function dns_process(root, pid, budget) {
    let prefix = root == "/" ? "" : root, process = require("service.preflight_processes");
    let queue = [ { pid: "" + pid, depth: 0 } ], seen = {}, chain = [], found = null;
    let initial = fs.readlink(prefix + "/proc/1/ns/net");
    while (length(queue) > 0) {
        let item = shift(queue), current = item.pid;
        if (item.depth > 3 || length(keys(seen)) >= 16) die("dns-runtime-supervisor-limit");
        if (seen[current]) die("dns-runtime-supervisor-cycle");
        seen[current] = true;
        let first = process.read_stat(prefix + "/proc/" + current + "/stat", current, budget);
        let exe = process.executable(prefix + "/proc/" + current + "/exe", budget);
        let namespace = fs.readlink(prefix + "/proc/" + current + "/ns/net");
        if (first.error != null || exe.error != null || type(namespace) != "string" || namespace != initial)
            die("dns-runtime-process-unverified");
        if (dns_binary(root, "/usr/sbin/dnsmasq", exe.target)) {
            if (found != null) die("dns-runtime-child-ambiguous");
            found = { pid: current, start: first.start, executable: exe.target, namespace };
            continue;
        }
        if (!dns_binary(root, "/sbin/ujail", exe.target) && !dns_binary(root, "/usr/sbin/ujail", exe.target))
            die("dns-runtime-process-unverified");
        let children = dns_children(root, current), node = exe.target;
        push(chain, [ current, first.start, node.inode, node.dev.major, node.dev.minor, node.uid, node.mode,
            node.nlink, node.size, node.mtime, node.ctime, children ]);
        for (let child in children) push(queue, { pid: child, depth: item.depth + 1 });
    }
    if (found == null) die("dns-runtime-child-unavailable");
    found.chain = sprintf("%J", chain);
    return found;
}

function dns_runtime(root, services) {
    let result = observation("dns-runtime", "dnsmasq", "incomplete", "dns-runtime-service-unverified");
    if (services.error != null || length(services.dns ?? []) != 1 || services.dns[0].error != null) return result;
    try {
        let instance = services.dns[0], now = clock(true), budget = { bytes: 0, started: now[0] * 1000 + int(now[1] / 1000000) };
        let process = dns_process(root, instance.pid, budget), sockets = dns_sockets(root, process.pid);
        result = require("service.preflight_config").dns_runtime(root, instance.config);
        let final = dns_process(root, instance.pid, budget), final_sockets = dns_sockets(root, final.pid), again = probe();
        if (process.pid != final.pid || process.chain != final.chain || process.start != final.start || !files.same_node(process.executable, final.executable) || process.namespace != final.namespace ||
            sprintf("%J", sockets) != sprintf("%J", final_sockets) || again.error != null || sprintf("%J", services.dns) != sprintf("%J", again.dns))
            die("dns-runtime-process-changed");
    }
    catch (e) {
        result.state = "incomplete";
        result.reason = type(e.message) == "string" && match(e.message, /^dns-runtime-[a-z-]+$/) ? e.message : "dns-runtime-service-unverified";
    }
    return result;
}


const SYSTEM_HOOK_PACKAGES = [ "base-files", "busybox", "procd", "ubox", "logd", "netifd", "firewall4",
    "dnsmasq", "dnsmasq-full", "dnsmasq-dhcpv6", "odhcpd", "odhcpd-ipv6only", "dropbear", "rpcd", "uhttpd", "urngd", "urandom-seed",
    "hostapd-common", "wpad-basic-mbedtls", "wpad-basic-openssl", "wpad-basic-wolfssl", "wpad-mbedtls", "wpad-openssl", "wpad-wolfssl" ];

function hook_inventory(root) {
    let prefix = root == "/" ? "" : root, result = { paths: [], hooks: [], token: null };
    let queue = [ "/etc/init.d", "/etc/hotplug.d", "/etc/uci-defaults" ], nodes = [], count = 0;
    try {
        while (length(queue) > 0) {
            let target = shift(queue), path = prefix + target;
            let status = files.collect(root, { [target]: "directory" })[0];
            if (status.reason == "candidate-path-absent" && target != "/etc/init.d") continue;
            if (status.reason != "candidate-directory-safe") die("hook-directory-unverified");
            let before = fs.lstat(path), directory = fs.opendir(path), failed = false;
            if (directory == null) die("hook-directory-unavailable");
            try {
                while (true) {
                    fs.error(); let name = directory.read(), error = fs.error();
                    if (name == null) { if (error != null) failed = true; break; }
                    if (++count > ENTRY_LIMIT) die("hook-entry-limit");
                    if (substr(name, 0, 1) == ".") continue;
                    if (type(name) != "string" || name == "" || length(name) > 255 || index(name, "/") >= 0 || index(name, "\u0000") >= 0)
                        die("hook-entry-unverified");
                    let relative = target + "/" + name, node = fs.lstat(prefix + relative);
                    if (node == null) die("hook-entry-unavailable");
                    push(nodes, { path: relative, node });
                    if (node.type == "directory") {
                        if (target == "/etc/hotplug.d") push(queue, relative);
                        continue;
                    }
                    push(result.paths, relative);
                    if (target != "/etc/init.d") push(result.hooks, relative);
                }
            }
            catch (e) { failed = true; }
            try { if (directory.close() !== true) failed = true; }
            catch (e) { failed = true; }
            if (failed || !files.same_node(before, fs.lstat(path))) die("hook-directory-unverified");
            push(nodes, { path: target, node: before });
        }
        push(result.paths, "/etc/rc.local"); push(result.hooks, "/etc/rc.local");
        push(nodes, { path: "/etc/rc.local", node: fs.lstat(prefix + "/etc/rc.local") });
        result.paths = sort(result.paths); result.hooks = sort(result.hooks);
        nodes = sort(nodes, (a, b) => a.path < b.path ? -1 : a.path == b.path ? 0 : 1);
        // Read-only enumeration and inspection may update access times.
        for (let entry in nodes) if (entry.node != null) delete entry.node.atime;
        result.token = sprintf("%J", nodes);
    }
    catch (e) { result.error = "hook-inventory-unverified"; }
    return result;
}

function hook_origin(root, target, provenance) {
    let targets = {}; targets[target] = "file";
    let safe = files.collect(root, targets)[0];
    if (safe.reason == "candidate-path-absent") return { state: "checked", reason: "hook-path-absent" };
    if (safe.reason != "candidate-existing-file-origin-unverified") return { state: "incomplete", reason: "hook-file-unverified" };
    // rc.local is mutable system configuration; a package claim cannot prove its commands safe.
    if (target == "/etc/rc.local") {
        let path = (root == "/" ? "" : root) + target;
        let read = require("service.preflight").read_metadata(path, 65536, root);
        if (read.error != null) return { state: "incomplete", reason: "startup-local-unverified" };
        for (let line in split(read.data, "\n")) {
            line = trim(line);
            if (line != "" && substr(line, 0, 1) != "#" && !match(line, /^(exit|return)[ \t]+0$/))
                return { state: "incomplete", reason: "startup-local-unverified" };
        }
        return { state: "checked", reason: "startup-local-inert" };
    }
    if (!provenance?.complete) return { state: "incomplete", reason: "hook-package-inventory-unverified" };
    let claims = provenance.claims[target] || [];
    if (length(claims) != 1) return { state: "incomplete", reason: "hook-package-owner-unverified" };
    if (provenance.own[target]) return { state: "checked", reason: "hook-own-content-checked" };
    if (provenance.system && index(SYSTEM_HOOK_PACKAGES, claims[0]) >= 0)
        return { state: "checked", reason: "trusted-system-hook-checked" };
    return { state: "incomplete", reason: "hook-package-origin-unverified" };
}

function enabled_entry(root, directory, entry, name, provenance) {
    let path = directory + "/" + entry;
    let node = fs.lstat(path);
    let owner = root == "" ? 0 : fs.lstat(root)?.uid;
    if (node == null || node.uid != owner || node.nlink != 1)
        return { state: "incomplete", reason: "autostart-entry-unverified" };
    if (node.type == "link") {
        let target = fs.readlink(path);
        if (!files.same_node(node, fs.lstat(path)))
            return { state: "incomplete", reason: "autostart-entry-changed" };
        let init = "/etc/init.d/" + name;
        if (target != "../init.d/" + name && target != init)
            return { state: "incomplete", reason: "autostart-link-target-unverified" };
        let targets = {};
        targets[init] = "file";
        let result = files.collect(root || "/", targets)[0];
        if (result.reason == "candidate-path-absent")
            return { state: "checked", reason: "autostart-dangling-link" };
        if (result.reason != "candidate-existing-file-origin-unverified")
            return { state: "incomplete", reason: "autostart-entry-unverified" };
        path = root + init;
        node = fs.lstat(path);
    }
    if (node?.type != "file" || node.uid != owner || node.nlink != 1 || (node.mode & 0022) != 0)
        return { state: "incomplete", reason: "autostart-entry-unverified" };
    let executable = (node.mode & 0111) != 0;
    if (!files.same_node(node, fs.lstat(path)))
        return { state: "incomplete", reason: "autostart-entry-changed" };
    if (!executable) return { state: "checked", reason: "autostart-entry-not-executable" };
    if (provenance == null) return { state: "incomplete", reason: "enabled-service-origin-unverified" };
    let result = hook_origin(root || "/", substr(path, length(root)), provenance);
    if (KNOWN[name] === false && result.state == "incomplete") result.reason = "enabled-service-origin-unverified";
    return result.reason == "hook-path-absent" ? { state: "incomplete", reason: "autostart-entry-changed" } : result;
}

function autostart(root, provenance) {
    let directory = root + "/etc/rc.d";
    let checked = files.collect(root || "/", { "/etc/rc.d": "directory" })[0];
    if (checked.reason != "candidate-directory-safe")
        return [ observation("autostart", "rc-directory", "incomplete", "autostart-directory-unavailable") ];
    let before = fs.lstat(directory);
    fs.error();
    let handle = fs.opendir(directory);
    if (handle == null)
        return [ observation("autostart", "rc-directory", "incomplete", "autostart-directory-read-failed") ];
    let result = [];
    let count = 0;
    let error = null;
    let unknown = false;
    try {
        while (true) {
            if (count >= ENTRY_LIMIT) { error = "autostart-directory-entry-limit"; break; }
            fs.error();
            let entry = handle.read();
            let failure = fs.error();
            if (entry == null) {
                if (failure != null) error = "autostart-directory-read-failed";
                break;
            }
            count++;
            if (substr(entry, 0, 1) != "S") continue;
            let matched = match(entry, /^S[0-9][0-9]([A-Za-z0-9_-]+)$/);
            if (matched == null || !exists(KNOWN, matched[1]) && provenance == null) { unknown = true; continue; }
            let status = enabled_entry(root, directory, entry, matched[1], provenance);
            push(result, observation("autostart", exists(KNOWN, matched[1]) ? "service-" + matched[1] : "system-service-" + count, status.state, status.reason));
        }
    }
    catch (e) { error = "autostart-directory-read-failed"; }
    try { if (handle.close() !== true) error = "autostart-directory-read-failed"; }
    catch (e) { error = "autostart-directory-read-failed"; }
    if (!files.same_node(before, fs.lstat(directory)))
        error = "autostart-directory-changed";
    if (error != null)
        return [ observation("autostart", "rc-directory", "incomplete", error) ];
    if (unknown)
        push(result, observation("autostart", "rc-directory", "incomplete", "unclassified-autostart-entry"));
    push(result, observation("autostart", "rc-directory", "checked", "autostart-directory-read-complete"));
    return result;
}

function registration_origin(root, services, provenance) {
    let result = observation("services", "registration-origin", "incomplete", "service-process-and-origin-unverified");
    if (services.error != null || !provenance?.complete || !provenance.system) return result;
    for (let service in services.registrations) {
        if (!service.active && !service.pending) continue;
        if (!match(service.name, /^[A-Za-z0-9_][A-Za-z0-9_.+@-]*$/) || KNOWN[service.name] === false) return result;
        let state = hook_origin(root, "/etc/init.d/" + service.name, provenance);
        if (state.state != "checked" || state.reason == "hook-path-absent") return result;
    }
    let final = probe();
    if (final.error != null || final.snapshot != services.snapshot) {
        result.reason = "service-snapshot-changed-or-unavailable";
        return result;
    }
    // Registration origin does not replace the separate mandatory process identity checks.
    result.state = "checked"; result.reason = "service-registration-origin-checked";
    return result;
}

function collect(root, provenance) {
    root = root == "/" ? "" : root;
    let result = [];
    let services = probe();
    let registration = registration_origin(root || "/", services, provenance);
    if (services.error != null)
        push(result, observation("services", "procd-snapshot", "incomplete", services.error));
    else {
        for (let service in services.known) {
            let reason = service.active ? (KNOWN[service.name] ? "existing-service-origin-unverified" : "foreign-service-active-unverified")
                : service.pending ? "service-restart-trigger-unverified" : "known-service-inactive";
            let verified = KNOWN[service.name] && registration.state == "checked";
            push(result, observation("services", "service-" + service.name,
                verified || !service.active && !service.pending ? "checked" : "incomplete",
                verified ? "known-service-registration-checked" : reason));
        }
        push(result, observation("services", "procd-snapshot", "checked", "service-snapshot-read-complete"));
    }
    push(result, dns_runtime(root || "/", services));
    for (let item in autostart(root, provenance)) push(result, item);
    let hooks = provenance == null ? null : hook_inventory(root || "/"), ordinal = 0;
    if (provenance != null) {
        if (hooks.error != null || hooks.token != provenance.token)
            push(result, observation("hooks", "hook-inventory", "incomplete", "hook-inventory-changed-or-unavailable"));
        else for (let path in hooks.hooks) {
            let state = hook_origin(root || "/", path, provenance);
            push(result, observation("hooks", "hook-" + ++ordinal, state.state, state.reason));
        }
        let final = hook_inventory(root || "/");
        push(result, observation("hooks", "hook-inventory", final.error == null && final.token == provenance.token ? "checked" : "incomplete",
            final.error == null && final.token == provenance.token ? "hook-inventory-checked" : "hook-inventory-changed-or-unavailable"));
    }
    push(result, registration);
    if (provenance == null) push(result, observation("autostart", "hook-provenance", "incomplete", "autostart-hook-provenance-unverified"));
    return result;
}

return { collect, parse, hook_inventory };
