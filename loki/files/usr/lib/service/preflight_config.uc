let fs = require("fs");

const CONFIG_LIMIT = 1048576;

function item(state, reason) {
    return { kind: "configuration", object: "candidate-config", state, reason };
}

function cleanup(config, delta, made_config, made_delta, made_files) {
    let okay = true;
    for (let name in made_files)
        if (fs.unlink(config + "/" + name) !== true) okay = false;
    if (made_delta && fs.rmdir(delta) !== true) okay = false;
    if (made_config && fs.rmdir(config) !== true) okay = false;
    return okay;
}

function stage(config, name, data, owner, made_files) {
    let path = config + "/" + name;
    let file = fs.open(path, "wx", 0600);
    if (file == null) return false;
    push(made_files, name);
    let written = null;
    let closed = false;
    try { written = file.write(data); }
    catch (e) { written = null; }
    try { closed = file.close(); }
    catch (e) { closed = false; }
    let stat = fs.lstat(path);
    return written === length(data) && closed === true && stat?.type == "file" &&
        stat.size == length(data) && stat.uid == owner && (stat.mode & 0777) == 0600 && stat.nlink == 1;
}

function dns_policy(sections) {
    let result = { kind: "dns-committed", object: "dnsmasq", state: "incomplete", reason: "dnsmasq-layout-unverified" };
    let instances = filter(sections ?? [], (section) => section[".type"] == "dnsmasq");
    if (length(instances) != 1) return result;
    let section = instances[0];
    if (section.port != null && section.port != "53") return result;
    if (section.noresolv != null && index([ "0", "1" ], section.noresolv) < 0) return result;
    if (section.resolvfile != null && section.resolvfile != "" && section.resolvfile != "/tmp/resolv.conf.d/resolv.conf.auto")
        return result;
    if (section.confdir != null && section.confdir != "" && section.confdir != "/tmp/dnsmasq.d") return result;
    let servers = section.server == null ? [] : type(section.server) == "string" ? [ section.server ] : section.server;
    if (type(servers) != "array") return result;
    for (let server in servers) {
        if (type(server) != "string" || index(server, "\u0000") >= 0) return result;
        let endpoint = server;
        if (substr(server, 0, 1) == "/") {
            let last = rindex(server, "/");
            let domains = substr(server, 1, last - 1);
            if (last <= 1 || !match(domains, /^[A-Za-z0-9.*_#\/-]+$/)) return result;
            endpoint = substr(server, last + 1);
            if (endpoint == "" || endpoint == "#") continue;
        }
        let pieces = split(endpoint, "#"), address = pieces[0], port = 53;
        if (length(pieces) > 2) return result;
        if (length(pieces) == 2) {
            if (!match(pieces[1], /^[1-9][0-9]{0,4}$/) || int(pieces[1]) > 65535) return result;
            port = int(pieces[1]);
        }
        if (substr(address, 0, 1) == "[" && substr(address, -1) == "]") address = substr(address, 1, length(address) - 2);
        let ip = require("core.ip"), candidate = require("singbox.constants").DNS_INBOUND_ADDRESS;
        if (!ip.valid_ip(address) || ip.prefix_contains("0.0.0.0/32", address) || ip.prefix_contains("::/128", address)) return result;
        if (port == 53 && (ip.prefix_contains(candidate + "/32", address) || ip.prefix_contains("::ffff:" + candidate + "/128", address))) {
            result.state = "conflict"; result.reason = "dnsmasq-forwards-to-candidate"; return result;
        }
        if (ip.prefix_contains("127.0.0.0/8", address) || ip.prefix_contains("::ffff:127.0.0.0/104", address) ||
            ip.prefix_contains("::1/128", address)) {
            result.reason = "local-dns-forwarder-origin-unverified"; return result;
        }
    }
    result.state = "checked"; result.reason = "dns-uci-policy-checked";
    return result;
}

function core_check(generated, core) {
    let result = { kind: "core-check", object: "candidate-core", state: "incomplete", reason: "candidate-core-check-failed" };
    let file = null;
    try {
        let runtime = require("singbox.runtime"), files = require("service.preflight_files");
        if (runtime.file_digest(core.path, core) != core.sha256) return result;
        let before = fs.lstat(core.path);
        file = fs.open(core.path, "re");
        if (file == null) return result;
        let descriptor = "/proc/" + require("core.common").own_pid() + "/fd/" + file.fileno();
        if (!files.same_node(before, fs.stat(descriptor))) die("core-changed");
        let digest = require("core.exec").capture([ "/bin/busybox", "sha256sum", descriptor ]);
        if (digest.status != 0 || digest.stdout != core.sha256 + "  " + descriptor + "\n") die("core-changed");
        // Go needs a large virtual address reservation; only the checksum-bound child lifts the soft VM cap.
        runtime.check(sprintf("%J\n", generated ?? { outbounds: [ { type: "direct", tag: "direct-out" } ], route: { final: "direct-out" } }), descriptor);
        if (!files.same_node(before, fs.stat(descriptor)) || !files.same_node(before, fs.lstat(core.path))) die("core-changed");
        result.state = "checked"; result.reason = "candidate-core-check-checked";
    }
    catch (e) {}
    try { if (file != null && file.close() !== true) result.state = "incomplete"; }
    catch (e) { result.state = "incomplete"; }
    if (result.state != "checked") result.reason = "candidate-core-check-failed";
    return result;
}

function generation(native, model, config, owner, made_files, platform, core, root, transaction) {
    let models = {};
    for (let name in [ "dhcp", "system" ]) {
        let data = platform?.[name];
        if (type(data) != "string")
            return [ item("incomplete", "candidate-platform-config-unavailable") ];
        if (length(data) > CONFIG_LIMIT || index(data, "\u0000") >= 0)
            return [ item("incomplete", "candidate-platform-config-invalid") ];
        if (!stage(config, name, data, owner, made_files))
            return [ item("incomplete", "candidate-platform-stage-failed") ];
        try {
            if (native.load(name) !== true)
                return [ item("incomplete", "candidate-platform-parse-failed") ];
            models[name] = require("config.migration").model_from_cursor(native, name);
            if (models[name] == null)
                return [ item("incomplete", "candidate-platform-parse-failed") ];
        }
        catch (e) { return [ item("incomplete", "candidate-platform-parse-failed") ]; }
    }
    let credential;
    try { credential = require("service.gateway_secret").generate(); }
    catch (e) { return [ item("incomplete", "candidate-credential-unavailable") ]; }
    try {
        let generated = require("singbox.generator").build_candidate(model, models, { controller_secret: credential });
        let result = [ item("checked", generated == null ? "uci-generation-empty" : "uci-generation-checked") ];
        if (transaction != null && root != null) {
            let settings = filter(model.sections, (section) => section[".type"] == "settings")[0];
            let budget = require("service.preflight_resources").transaction(root, { ...transaction, settings });
            push(result, budget);
            if (budget.state != "checked") core = null;
        }
        if (root != null) {
            let firewall = { kind: "nft-persisted", object: "firewall-includes", state: "incomplete", reason: "nft-persisted-config-unverified" };
            try {
                let data = platform?.firewall;
                if (type(data) == "string" && length(data) <= CONFIG_LIMIT && index(data, "\u0000") < 0 &&
                    stage(config, "firewall", data, owner, made_files) && native.load("firewall") === true) {
                    let snapshot = require("config.migration").model_from_cursor(native, "firewall");
                    firewall = require("service.preflight_nft").persisted(root, snapshot?.sections, transaction?.own_files);
                }
            }
            catch (e) {}
            push(result, firewall);
        }
        let dns = dns_policy(models.dhcp.sections);
        push(result, dns);
        if (core != null && dns.state == "checked") push(result, core_check(generated, core));
        return result;
    }
    catch (e) { return [ item("incomplete", "candidate-generation-failed") ]; }
}

function inspect(config, delta, data, owner, made_files, platform, core, root, transaction) {
    if (!stage(config, "loki", data, owner, made_files))
        return [ item("incomplete", "scratch-write-failed") ];
    let native = null;
    try { native = require("uci").cursor(config, delta, ""); }
    catch (e) { native = null; }
    if (native == null)
        return [ item("incomplete", "uci-unavailable") ];
    try {
        if (native.load("loki") !== true)
            return [ item("incomplete", "uci-load-failed") ];
    }
    catch (e) { return [ item("incomplete", "uci-load-failed") ]; }
    let decision = null;
    let model = null;
    try {
        let migration = require("config.migration");
        model = migration.model_from_cursor(native, "loki");
        if (model != null) decision = migration.decide(model);
    }
    catch (e) { decision = null; }
    let result = [ item("checked", "uci-syntax-checked") ];
    if (decision?.result != "current") {
        let reason = decision?.result == "migrate" ? "candidate-schema-migration-required" :
            decision?.result == "reject" && index([ "foreign", "schema", "missing", "invalid", "newer", "below_min", "unknown" ], decision.reason) >= 0
                ? "candidate-schema-" + decision.reason : "candidate-schema-unavailable";
        push(result, item("incomplete", reason));
        return result;
    }
    push(result, item("checked", "uci-schema-checked"));
    try { require("config.validator").validate_candidate(model); }
    catch (e) {
        push(result, item("incomplete", "candidate-config-values-invalid"));
        return result;
    }
    push(result, item("checked", "uci-values-checked"));
    for (let entry in generation(native, model, config, owner, made_files, platform, core, root, transaction)) push(result, entry);
    if (core == null) push(result, item("incomplete", "candidate-core-unverified"));
    return result;
}

function check(data, scratch, platform, core, root, transaction) {
    if (type(data) != "string" || index(data, "\u0000") >= 0)
        return [ item("incomplete", "candidate-config-invalid") ];
    if (length(data) > CONFIG_LIMIT)
        return [ item("incomplete", "candidate-config-size-limit") ];
    let directory = type(scratch) == "string" ? fs.lstat(scratch) : null;
    let owner = fs.stat("/proc/self/status")?.uid;
    if (type(scratch) != "string" || !match(scratch, /^\/[A-Za-z0-9_.+@\/-]+$/) ||
        index(scratch, "//") >= 0 || match(scratch, /\/(\.\.?)(\/|$)/) ||
        directory?.type != "directory" || (directory.mode & 0777) != 0700 ||
        owner == null || directory.uid != owner)
        return [ item("incomplete", "scratch-unsafe") ];

    let config = scratch + "/config";
    let delta = scratch + "/delta";
    let made_files = [];
    let made_config = fs.mkdir(config) === true;
    let made_delta = made_config && fs.mkdir(delta) === true;
    let result = [ item("incomplete", "scratch-write-failed") ];
    try {
        if (made_delta && fs.chmod(config, 0700) === true && fs.chmod(delta, 0700) === true)
            result = inspect(config, delta, data, owner, made_files, platform, core, root, transaction);
    }
    catch (e) { result = [ item("incomplete", "candidate-check-failed") ]; }
    let cleaned = false;
    try { cleaned = cleanup(config, delta, made_config, made_delta, made_files); }
    catch (e) { cleaned = false; }
    if (!cleaned)
        return [ item("incomplete", "scratch-cleanup-failed") ];
    return result;
}

function pending_names(path, budget) {
    require("core.cache_path").validate({ cache_path: path + "/dhcp" });
    let before = fs.lstat(path), names = [], seen = {};
    if (before == null) return { path, before, names };
    if (before.type != "directory" || before.uid != fs.stat("/proc/self").uid || (before.mode & 0777) != 0700)
        die("uci-pending-read-failed");
    let directory = fs.opendir(path);
    if (directory == null) die("uci-pending-read-failed");
    let reason = null;
    try {
        while (true) {
            fs.error();
            let name = directory.read();
            let error = fs.error();
            if (name == null) { if (error != null) reason = "uci-pending-read-failed"; break; }
            if (++budget.entries > 4096) { reason = "uci-pending-entry-limit"; break; }
            if (type(name) != "string" || name == "" || length(name) > 255 || index(name, "\u0000") >= 0 || index(name, "/") >= 0) {
                reason = "uci-pending-read-failed"; break;
            }
            if (substr(name, 0, 1) == ".") continue;
            if (seen[name]) { reason = "uci-pending-changed"; break; }
            seen[name] = true;
            push(names, name);
        }
    }
    catch (e) { reason = "uci-pending-read-failed"; }
    try { if (directory.close() !== true) reason = "uci-pending-read-failed"; }
    catch (e) { reason = "uci-pending-read-failed"; }
    if (reason != null) die(reason);
    return { path, before, names: sort(names) };
}

function empty_delta(path) {
    let before = fs.lstat(path);
    if (before?.type != "file" || before.uid != fs.stat("/proc/self").uid || before.nlink != 1 || (before.mode & 0022) != 0)
        die("uci-pending-read-failed");
    let file = fs.open(path, "re"), data, safe = false;
    if (file == null) die("uci-pending-read-failed");
    let files = require("service.preflight_files");
    try {
        let descriptor = "/proc/self/fd/" + file.fileno();
        if (files.same_node(before, fs.stat(descriptor))) {
            data = file.read(1);
            safe = file.error() == null && type(data) == "string" &&
                files.same_node(before, fs.stat(descriptor)) && files.same_node(before, fs.lstat(path));
        }
    }
    catch (e) {}
    try { safe = file.close() === true && safe; }
    catch (e) { safe = false; }
    if (!safe) die("uci-pending-read-failed");
    if (data != "" || before.size != 0) die("uci-pending-config-changes");
    return { path, before };
}

function pending(root) {
    root = root == "/" ? "" : root;
    let result = { kind: "dns-pending", object: "uci-deltas", state: "incomplete", reason: "uci-pending-read-failed" };
    try {
        let run = fs.realpath(root + "/var/run");
        if (index([ root + "/var/run", root + "/tmp/run" ], run) < 0) die("uci-pending-layout-unverified");
        let budget = { entries: 0 }, directories = [], files = [];
        let cli = pending_names(root + "/tmp/.uci", budget);
        let rpcd = pending_names(run + "/rpcd", budget);
        push(directories, cli, rpcd);
        // rpcd/uci.h defines the session stores and both possible rollback stores.
        for (let name in rpcd.names) {
            if (name == "snapshot-files" || name == "snapshot-delta" || match(name, /^uci-[a-fA-F0-9]{32}$/))
                push(directories, pending_names(rpcd.path + "/" + name, budget));
            else if (substr(name, 0, 4) == "uci-") die("uci-pending-layout-unverified");
        }
        for (let directory in directories)
            if (directory.path != rpcd.path)
                for (let name in directory.names) push(files, empty_delta(directory.path + "/" + name));
        for (let directory in directories) {
            let after = pending_names(directory.path, budget);
            if ((directory.before == null ? after.before != null : !require("service.preflight_files").same_node(directory.before, after.before)) ||
                sprintf("%J", directory.names) != sprintf("%J", after.names)) die("uci-pending-changed");
        }
        for (let file in files)
            if (!require("service.preflight_files").same_node(file.before, fs.lstat(file.path))) die("uci-pending-changed");
        if (fs.realpath(root + "/var/run") != run) die("uci-pending-changed");
        result.state = "checked"; result.reason = "uci-pending-snapshot-checked";
    }
    catch (e) {
        if (index([ "uci-pending-layout-unverified", "uci-pending-read-failed", "uci-pending-entry-limit",
            "uci-pending-changed", "uci-pending-config-changes" ], e.message) >= 0) result.reason = e.message;
    }
    return result;
}


function dns_path(root, path) {
    if (type(path) != "string" || !match(path, /^\/[A-Za-z0-9_./+-]+$/) || index(split(path, "/"), "..") >= 0 ||
        index(split(path, "/"), ".") >= 0 || index(path, "//") >= 0 || substr(path, -1) == "/") die("dns-runtime-path-unverified");
    let prefix = root == "/" ? "" : root;
    if (substr(path, 0, 5) == "/var/" && fs.lstat(prefix + "/var")?.type == "link") {
        let target = fs.readlink(prefix + "/var");
        if (target != "tmp" && target != "/tmp") die("dns-runtime-path-unverified");
        path = "/tmp/" + substr(path, 5);
    }
    let owner = fs.lstat(root)?.uid, current = prefix;
    let parts = split(path, "/");
    for (let i = 1; i < length(parts) - 1; i++) {
        current += "/" + parts[i];
        let node = fs.lstat(current);
        if (node?.type != "directory" || node.uid != owner || ((node.mode & 0022) != 0 && (node.mode & 01000) == 0))
            die("dns-runtime-path-unverified");
    }
    return prefix + path;
}

function dns_directory(path, budget) {
    let before = fs.lstat(path), owner = fs.stat("/proc/self").uid;
    if (before?.type != "directory" || before.uid != owner || (before.mode & 0022) != 0) die("dns-runtime-path-unverified");
    let directory = fs.opendir(path), names = [], failed = false;
    if (directory == null) die("dns-runtime-read-failed");
    try {
        while (true) {
            fs.error(); let name = directory.read(), error = fs.error();
            if (name == null) { if (error != null) failed = true; break; }
            if (++budget.entries > 4096) die("dns-runtime-entry-limit");
            if (name == "." || name == "..") continue;
            if (type(name) != "string" || name == "" || length(name) > 255 || index(name, "/") >= 0 || index(name, "\u0000") >= 0)
                die("dns-runtime-path-unverified");
            // dnsmasq ignores hidden files and editor backups in conf-dir.
            if (substr(name, 0, 1) == "." || substr(name, -1) == "~" || (substr(name, 0, 1) == "#" && substr(name, -1) == "#")) continue;
            push(names, name);
        }
    }
    catch (e) { failed = true; }
    try { if (directory.close() !== true) failed = true; }
    catch (e) { failed = true; }
    if (failed || !require("service.preflight_files").same_node(before, fs.lstat(path))) die("dns-runtime-read-failed");
    return { path, before, names: sort(names) };
}

function dns_runtime(root, path) {
    let result = { kind: "dns-runtime", object: "dnsmasq-config", state: "incomplete", reason: "dns-runtime-config-unverified" };
    try {
        let queue = [ path ], seen = {}, snapshots = [], directories = [], budget = { entries: 0 }, bytes = 0;
        let servers = [], noresolv = false, resolver = null, binding = false;
        let metadata = require("service.preflight").read_metadata;
        let read = (target) => {
            let name = dns_path(root, target), parent = require("core.common").parent_dir(name);
            let content = metadata(name, CONFIG_LIMIT, parent);
            if (content.error != null || (bytes += content.bytes) > CONFIG_LIMIT || length(snapshots) >= 128)
                die("dns-runtime-read-failed");
            push(snapshots, { path: name, parent, data: content.data, node: fs.lstat(name) });
            return content.data;
        };
        while (length(queue) > 0) {
            let target = shift(queue);
            if (seen[target]) die("dns-runtime-include-cycle");
            seen[target] = true;
            for (let line in split(read(target), "\n")) {
                line = trim(line);
                if (line == "" || substr(line, 0, 1) == "#") continue;
                let option = match(line, /^([a-z][a-z0-9-]*)([ \t]*=[ \t]*(.*))?$/);
                if (option == null) die("dns-runtime-syntax-unverified");
                let key = option[1], value = trim(option[3] ?? "");
                if (key == "server") push(servers, value);
                else if (key == "port" && value != "53") die("dns-runtime-port-unverified");
                else if (key == "bind-dynamic" || key == "bind-interfaces") { if (value != "") die("dns-runtime-bind-unverified"); binding = true; }
                else if (key == "no-resolv") { if (value != "") die("dns-runtime-resolver-unverified"); noresolv = true; }
                else if (key == "resolv-file") { if (resolver != null && resolver != value) die("dns-runtime-resolver-unverified"); resolver = value; }
                else if (key == "conf-file" || key == "servers-file") { if (value != "") push(queue, value); }
                else if (key == "conf-dir") {
                    let directory = dns_directory(dns_path(root, value), budget);
                    push(directories, directory);
                    for (let name in directory.names) push(queue, value + "/" + name);
                }
                else if (index([ "conf-script", "enable-dbus", "rev-server" ], key) >= 0) die("dns-runtime-dynamic-config-unverified");
            }
        }
        if (!binding) die("dns-runtime-bind-unverified");
        if (!noresolv) {
            if (resolver == null || resolver == "") die("dns-runtime-resolver-unverified");
            for (let line in split(read(resolver), "\n")) {
                line = trim(line);
                if (line == "" || substr(line, 0, 1) == "#" || substr(line, 0, 1) == ";") continue;
                let fields = split(line, /[ \t]+/);
                if (fields[0] == "nameserver") {
                    if (length(fields) != 2) die("dns-runtime-resolver-unverified");
                    push(servers, fields[1]);
                }
                else if (index([ "search", "domain", "options", "sortlist" ], fields[0]) < 0) die("dns-runtime-resolver-unverified");
            }
        }
        let policy = dns_policy([{ ".type": "dnsmasq", server: servers }]);
        if (policy.state != "checked") { result.state = policy.state; result.reason = policy.reason; return result; }
        for (let snapshot in snapshots) {
            let again = metadata(snapshot.path, CONFIG_LIMIT, snapshot.parent);
            if (again.error != null || again.data != snapshot.data || !require("service.preflight_files").same_node(snapshot.node, fs.lstat(snapshot.path)))
                die("dns-runtime-config-changed");
        }
        for (let directory in directories) {
            let again = dns_directory(directory.path, budget);
            if (join("\n", again.names) != join("\n", directory.names) || !require("service.preflight_files").same_node(directory.before, again.before))
                die("dns-runtime-config-changed");
        }
        result.state = "checked"; result.reason = "dns-runtime-config-checked";
    }
    catch (e) {
        result.reason = type(e.message) == "string" && match(e.message, /^dns-runtime-[a-z-]+$/) ? e.message : "dns-runtime-config-unverified";
    }
    return result;
}

return { check, dns_policy, pending, dns_runtime };
