// One durable intent record; package children inherit the update lease on fd 9.
let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let lock = require("service.lock");
let process = require("core.process");

const FORMAT = "loki-update-1";
const LIMIT = 4096;
const TERMINAL = [ "committed", "rolled-back", "aborted" ];
const NEXT = {
    preparing: [ "prepared", "aborted" ],
    prepared: [ "applying", "aborted" ],
    applying: [ "health", "rollback", "recovery-required" ],
    health: [ "committed", "rollback", "recovery-required" ],
    rollback: [ "rolled-back", "recovery-required" ],
    "recovery-required": [ "rollback" ]
};
let paths = {
    state: "/etc/loki/update/state.json",
    lock: "/var/lock/loki-install.lock",
    boot: "/proc/sys/kernel/random/boot_id",
    fsync: [ "/bin/busybox", "fsync" ],
    cli: "/usr/bin/loki",
    log: "/tmp/loki-installer/install.log",
    databases: { ipk: "/usr/lib/opkg/status", apk: "/lib/apk/db/installed" },
    payload_root: "/",
    configurations: [ "/etc/config/loki", "/etc/config/loki-core" ]
};

function hash(value) {
    return type(value) == "string" && length(value) == 64 && index(value, "\u0000") < 0 && match(value, /^[a-f0-9]+$/) != null;
}

function epoch() {
    let file = fs.open(paths.boot, "re");
    if (file == null) return null;
    let body, error = true, closed = false;
    fs.error();
    try { body = file.read(65); error = file.error(); }
    catch (e) {}
    try { closed = file.close() === true; }
    catch (e) {}
    if (!closed || error != null || type(body) != "string" || length(body) != 37 || substr(body, -1) != "\n")
        return null;
    let value = substr(body, 0, 36);
    return match(value, /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/) ? value : null;
}

function valid(value) {
    return type(value) == "object" && join(",", sort(keys(value))) == "epoch,format,id,operation,owner,phase,plan,ticks" &&
        value.format == FORMAT && hash(value.id) && value.id != sprintf("%064d", 0) && hash(value.plan) &&
        type(value.epoch) == "string" && length(value.epoch) == 36 && index(value.epoch, "\u0000") < 0 &&
        match(value.epoch, /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/) != null &&
        type(value.operation) == "string" && index(value.operation, "\u0000") < 0 &&
        index([ "install", "update", "uninstall" ], value.operation) >= 0 &&
        type(value.owner) == "string" && length(value.owner) <= 10 && index(value.owner, "\u0000") < 0 &&
        match(value.owner, /^[1-9][0-9]*$/) != null && int(value.owner) <= 2147483647 &&
        type(value.ticks) == "string" && length(value.ticks) <= 19 && index(value.ticks, "\u0000") < 0 && match(value.ticks, /^[0-9]+$/) != null &&
        int(value.ticks) >= 0 && "" + int(value.ticks) == value.ticks &&
        type(value.phase) == "string" && index(value.phase, "\u0000") < 0 &&
        (exists(NEXT, value.phase) || index(TERMINAL, value.phase) >= 0);
}

function encode(value) {
    return sprintf('{"format":%J,"id":%J,"operation":%J,"plan":%J,"epoch":%J,"owner":%J,"ticks":%J,"phase":%J}\n',
        value.format, value.id, value.operation, value.plan, value.epoch, value.owner, value.ticks, value.phase);
}

function private_read(path, limit) {
    let stat = fs.lstat(path);
    if (stat?.type != "file" || (stat.mode & 0777) != 0600 || stat.uid != fs.stat("/proc/self").uid)
        return null;
    let read = require("service.preflight").read_metadata(path, limit, common.parent_dir(path));
    return read.error == null ? read.data : null;
}

function read() {
    try {
        if (lock.unmarked(paths.state)) return null;
        require("core.cache_path").validate({ cache_path: paths.state });
        let directory = common.parent_dir(paths.state);
        if (private_read(directory + "/format", length(FORMAT) + 1) != FORMAT + "\n")
            return { error: true };
        let body = private_read(paths.state, LIMIT);
        let value = common.parse_json(body);
        return valid(value) && body == encode(value) ? value : { error: true };
    }
    catch (e) { return { error: true }; }
}

function context(value) {
    return value.id + ":" + value.epoch + ":" + value.owner + ":" + value.ticks;
}

function lease_owner(owner, ticks) {
    try {
        if (!lock.held(paths.lock)) return false;
        let read = require("service.preflight").read_metadata(paths.lock + "/pid", 128, paths.lock);
        return read.error == null && read.data == owner + "\n" + ticks + "\n";
    }
    catch (e) { return false; }
}

function own_lease() {
    let owner = common.own_pid();
    let ticks = process.start_ticks(owner);
    let anchor = fs.lstat(paths.lock + "/.kernel");
    let inherited = fs.stat("/proc/self/fd/9");
    return ticks != null && anchor?.type == "file" && inherited?.type == "file" &&
        anchor.inode == inherited.inode && anchor.dev.major == inherited.dev.major &&
        anchor.dev.minor == inherited.dev.minor && lease_owner(owner, "" + ticks);
}

function pending() {
    let value = read();
    return !lock.unmarked(common.parent_dir(paths.state) + "/busy") ||
        value != null && (value.error || index(TERMINAL, value.phase) < 0);
}

function allowed() {
    try {
        let value = read();
        let held = lock.held(paths.lock);
        if (value == null) return !held && !pending();
        if (value.error) return false;
        if (!held) return !pending();
        return getenv("LOKI_UPDATE_CONTEXT") == context(value) && value.epoch == epoch() &&
            "" + process.start_ticks(value.owner) == value.ticks && lease_owner(value.owner, value.ticks);
    }
    catch (e) { return false; }
}

function ready() {
    require("core.cache_path").ensure({ cache_path: paths.state });
    let directory = common.parent_dir(paths.state);
    let marker = directory + "/format";
    if (lock.unmarked(marker)) {
        let names = fs.lsdir(directory);
        if (type(names) != "array" || length(names) != 0 || !common.write_private_file(marker, FORMAT + "\n"))
            return false;
    }
    if (private_read(marker, length(FORMAT) + 1) != FORMAT + "\n" ||
        exec.status([ ...paths.fsync, marker ]) != 0)
        return false;
    // A newly created /etc/loki prefix must be durable before any package change.
    for (let parent = directory; parent != ""; parent = common.parent_dir(parent))
        if (exec.status([ ...paths.fsync, parent ]) != 0) return false;
    return exec.status([ ...paths.fsync, "/" ]) == 0;
}

function write(value) {
    try {
        if (!valid(value) || value.owner != common.own_pid() || value.epoch != epoch() ||
            value.ticks != "" + process.start_ticks(common.own_pid()) || !own_lease() || !ready()) return false;
        let directory = common.parent_dir(paths.state);
        let temporary = directory + "/.state.new";
        if (!lock.unmarked(temporary)) {
            let stat = fs.lstat(temporary);
            if (stat?.type != "file" || stat.uid != fs.stat("/proc/self").uid || stat.nlink != 1 ||
                (stat.mode & 0777) != 0600 || stat.size > LIMIT || !fs.unlink(temporary))
                return false;
        }
        if (!common.write_private_file(temporary, encode(value))) return false;
        if (exec.status([ ...paths.fsync, temporary ]) != 0 || !fs.rename(temporary, paths.state)) {
            fs.unlink(temporary);
            return false;
        }
        // Failure after rename is uncertain; retain the intent and stop the caller.
        return exec.status([ ...paths.fsync, directory ]) == 0;
    }
    catch (e) { return false; }
}

function begin(operation, plan) {
    try {
        if (pending()) return null;
        let value = {
            format: FORMAT, id: require("service.gateway_secret").generate(), operation, plan,
            epoch: epoch(), owner: common.own_pid(), ticks: "" + process.start_ticks(common.own_pid()), phase: "preparing"
        };
        return write(value) ? value : null;
    }
    catch (e) { return null; }
}

// A terminal rename whose directory sync failed must not unlock a later transaction.
function busy(value, create) {
    let path = common.parent_dir(paths.state) + "/busy";
    let body = value.id + "\n" + value.plan + "\n";
    if (lock.unmarked(path)) {
        if (!create) return true;
        if (!own_lease() || value.owner != common.own_pid() ||
            value.ticks != "" + process.start_ticks(common.own_pid()) || value.epoch != epoch() ||
            !common.write_private_file(path, body) || exec.status([ ...paths.fsync, path ]) != 0 ||
            exec.status([ ...paths.fsync, common.parent_dir(path) ]) != 0) return false;
    }
    if (private_read(path, 130) != body) return false;
    if (create) return true;
    return fs.unlink(path) && exec.status([ ...paths.fsync, common.parent_dir(path) ]) == 0;
}

function advance(value, phase) {
    if (!valid(value)) return null;
    let previous = read();
    if (previous == null || previous.error || encode(previous) != encode(value) ||
        index(NEXT[value.phase] ?? [], phase) < 0) return null;
    if (phase == "prepared" && !busy(value, true)) return null;
    let next = { ...value, phase };
    return write(next) && (index(TERMINAL, phase) < 0 || busy(next, false)) ? next : null;
}

function recover() {
    let value = read();
    if (value == null || value.error || index(TERMINAL, value.phase) >= 0 && !pending() || !own_lease()) return null;
    let current_epoch = epoch();
    if (current_epoch == null || value.epoch == current_epoch && "" + process.start_ticks(value.owner) == value.ticks)
        return null;
    let next = { ...value, epoch: current_epoch, owner: common.own_pid(), ticks: "" + process.start_ticks(common.own_pid()),
        phase: index(TERMINAL, value.phase) >= 0 ? "recovery-required" : value.phase };
    return write(next) ? next : null;
}

function refuse(reason) { die(reason); }

function candidate(directory, expected) {
    let manifest = directory + "/candidate-manifest.json";
    require("core.cache_path").validate({ cache_path: manifest });
    let data = private_read(manifest, 2097152);
    if (!hash(expected) || require("singbox.runtime").file_digest(manifest) != expected)
        refuse("candidate-manifest-checksum-failed");
    let parsed = require("service.preflight_manifest").parse(data);
    if (parsed.error != null || parsed.component_policy?.state != "checked")
        refuse("candidate-component-set-unverified");
    let components = json(data).components;
    let packages = [], names = [], ordered = [];
    for (let role in [ "core", "backend", "luci", "locale" ])
        for (let component in components)
            if (component.role == role) {
                let path = directory + "/packages/" + component.artifact.name;
                require("core.cache_path").validate({ cache_path: path });
                let node = fs.lstat(path);
                if (node?.size != component.artifact.size || require("singbox.runtime").file_digest(path) != component.artifact.sha256)
                    refuse("candidate-package-checksum-failed");
                push(packages, path); push(names, component.package); push(ordered, component);
            }
    return { directory, digest: expected, manifest, data, format: parsed.format, packages, names, components: ordered };
}

function package_command(value, operation, simulate) {
    let arguments = value.format == "ipk" ? [ "opkg", "--nodeps" ] :
        [ "apk", "--network=no", "--cache=no", "--logfile=no", "--repositories-file", "/dev/null", "--preserve-env=yes" ];
    if (simulate) push(arguments, value.format == "ipk" ? "--noaction" : "--simulate");
    if (value.format == "ipk" && operation == "rollback") push(arguments, "--force-downgrade");
    if (operation == "uninstall") {
        // Removal must retain the package manager's dependency protection.
        if (value.format == "ipk") arguments = filter(arguments, (argument) => argument != "--nodeps");
        push(arguments, value.format == "ipk" ? "remove" : "del");
        for (let i = length(value.names) - 1; i >= 0; i--) push(arguments, value.names[i]);
    }
    else {
        let reinstall = operation == "rollback" || value.reinstall === true;
        if (value.format == "ipk" && reinstall) push(arguments, "--force-reinstall");
        if (value.format == "apk") push(arguments, "--allow-untrusted");
        push(arguments, value.format == "ipk" ? "install" : "add");
        if (value.format == "apk" && reinstall) push(arguments, "--force-reinstall");
        push(arguments, ...value.packages);
    }
    return arguments;
}

function package_plan(value, operation, output, installed) {
    if (type(output) != "string" || length(output) > 65536 || index(output, "\u0000") >= 0)
        return false;
    let seen = {};
    for (let line in split(output, "\n")) {
        if (match(line, /^Downloading /)) return false;
        let action = value.format == "apk" ? match(line, /^\([0-9]+\/[0-9]+\) (Installing|Upgrading|Downgrading|Reinstalling|Replacing|Purging) ([a-z0-9][a-z0-9+_.-]*) /) :
            match(line, /^(Installing|Upgrading|Downgrading|Reinstalling|Removing package|Configuring) ([a-z0-9][a-z0-9+_.-]*)( |\.)/);
        if (action != null) {
            if (index(value.names, action[2]) < 0) return false;
            if ((operation == "uninstall") != (action[1] == "Purging" || action[1] == "Removing package")) return false;
            seen[action[2]] = true;
        }
        else if (match(line, /^\([0-9]+\/[0-9]+\)/) ||
            match(lc(line), /(installing|upgrading|downgrading|reinstalling|replacing|purging|removing package|configuring)/))
            return false;
    }
    for (let component in value.components)
        if (!seen[component.package] && (operation == "uninstall" ? installed[component.package] != null :
            installed[component.package] != component.version)) return false;
    return true;
}

function invoke(value, arguments, capture) {
    let command = [ "/usr/bin/env", "-i", "PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C", "LOKI_UPDATE_CONTEXT=" + context(value), "/bin/busybox", "ash", "-c", 'exec "$@" </dev/null', "sh", ...arguments ];
    return capture ? exec.combined(command, 65536) : exec.run(command);
}

function database(format) {
    let path = paths.databases[format];
    let read = require("service.preflight").read_metadata(path, 4194304, common.parent_dir(path));
    if (read.error != null) refuse("installed-package-database-unavailable");
    let packages = format == "ipk" ? require("service.preflight").package_records_from_status(read.data) :
        require("service.preflight_apk").parse(read.data).packages;
    if (type(packages) != "array") refuse("installed-package-database-invalid");
    let versions = {};
    for (let package in packages) versions[package.name] = package.version;
    return { body: read.data, versions };
}

function durable(path) {
    if (exec.status([ ...paths.fsync, path ]) != 0) refuse("transaction-storage-sync-failed");
}

function copy_private(source, destination, expected) {
    if (!lock.unmarked(destination) || require("singbox.runtime").file_digest(source) != expected ||
        exec.status([ "/bin/busybox", "cp", source, destination ]) != 0 || !fs.chmod(destination, 0600) ||
        require("singbox.runtime").file_digest(destination) != expected ||
        require("singbox.runtime").file_digest(source) != expected)
        refuse("transaction-copy-failed");
    durable(destination);
}

function stage(value, directory) {
    if (!fs.mkdir(directory, 0700) || !fs.mkdir(directory + "/packages", 0700))
        refuse("transaction-directory-unavailable");
    copy_private(value.manifest, directory + "/candidate-manifest.json", value.digest);
    for (let component in value.components)
        copy_private(value.directory + "/packages/" + component.artifact.name,
            directory + "/packages/" + component.artifact.name, component.artifact.sha256);
    durable(directory + "/packages"); durable(directory);
    return candidate(directory, value.digest);
}

function unchanged(configuration) {
    for (let item in configuration)
        if (item.sha256 == null ? !lock.unmarked(item.path) :
            require("singbox.runtime").file_digest(item.path) != item.sha256) return false;
    return true;
}

function configuration_files() {
    let files = [];
    for (let path in paths.configurations) {
        if (lock.unmarked(path)) { push(files, { path, sha256: null }); continue; }
        let digest = require("singbox.runtime").file_digest(path);
        if (digest == null) refuse("own-configuration-unavailable");
        push(files, { path, sha256: digest });
    }
    return files;
}

function state_tree(roots) {
    let queue = [ ...roots ], count = 0, bytes = 0, archive_bytes = 10240, devices = {}, reads = 0;
    let files = require("service.preflight_files");
    while (length(queue) > 0) {
        if (++count > 16384) refuse("own-state-entry-limit");
        let path = shift(queue), node = fs.lstat(path);
        if (node == null || node.uid != fs.stat("/proc/self").uid || (node.mode & 0022) != 0 ||
            node.type == "directory" && (node.mode & 0077) != 0 ||
            (node.type != "file" && node.type != "directory") || node.type == "file" && node.nlink != 1)
            refuse("own-state-path-unverified");
        if (length(path) >= 4096 || type(node.size) != "int" || node.size < 0 || node.size > 2147483647)
            refuse("own-state-byte-limit");
        if (node.type == "file") {
            bytes += node.size;
            archive_bytes += int((node.size + 511) / 512) * 512;
        }
        // Cover tar headers, long canonical path names and block padding without reading file bodies.
        archive_bytes += 8192;
        devices[node.dev.major + ":" + node.dev.minor] = true;
        if (bytes > 2147483647 || archive_bytes > 2147483647) refuse("own-state-byte-limit");
        if (node.type == "directory") {
            let directory = fs.opendir(path), failure = null;
            if (directory == null) refuse("own-state-unavailable");
            try {
                if (!files.same_node(node, fs.stat("/proc/self/fd/" + directory.fileno()))) failure = "own-state-path-unverified";
                while (failure == null) {
                    fs.error(); let name = directory.read(), error = fs.error();
                    if (name == null) { if (error != null) failure = "own-state-unavailable"; break; }
                    if (++reads > 49152) { failure = "own-state-entry-limit"; break; }
                    if (name == "." || name == "..") continue;
                    if (type(name) != "string" || name == "" || length(name) > 255 || index(name, "/") >= 0 || index(name, "\u0000") >= 0) {
                        failure = "own-state-path-unverified"; break;
                    }
                    if (count + length(queue) >= 16384) { failure = "own-state-entry-limit"; break; }
                    push(queue, path + "/" + name);
                }
            }
            catch (e) { failure = "own-state-unavailable"; }
            try { if (directory.close() !== true && failure == null) failure = "own-state-unavailable"; }
            catch (e) { failure = "own-state-unavailable"; }
            if (failure != null) refuse(failure);
            if (!files.same_node(node, fs.lstat(path))) refuse("own-state-path-unverified");
        }
    }
    return { bytes, archive_bytes, entries: count, devices: sort(keys(devices)) };
}

function backup(value, directory, snapshot) {
    let roots = [];
    for (let path in paths.configurations)
        if (!lock.unmarked(path)) push(roots, path);
    if (snapshot.cache_path != null) {
        require("core.cache_path").validate({ cache_path: snapshot.cache_path });
        for (let suffix in [ "", ".subscriptions", ".rule-sets" ])
            if (!lock.unmarked(snapshot.cache_path + suffix)) push(roots, snapshot.cache_path + suffix);
    }
    state_tree(roots);
    let anchors = [];
    for (let path in roots) {
        let parent = common.parent_dir(path), node = fs.lstat(parent);
        if (node?.type != "directory" || node.uid != fs.stat("/proc/self").uid || (node.mode & 0022) != 0)
            refuse("own-state-parent-unverified");
        push(anchors, { path: parent, inode: node.inode, major: node.dev.major, minor: node.dev.minor, mode: node.mode });
    }
    let archive = directory + "/state.tar";
    let digest = null;
    if (length(roots) > 0) {
        if (!common.write_private_file(archive, "") ||
            invoke(value, [ "/bin/busybox", "tar", "-cf", archive, "-C", "/", "--", ...map(roots, (path) => substr(path, 1)) ]) != 0)
            refuse("own-state-backup-failed");
        digest = require("singbox.runtime").file_digest(archive);
        if (digest == null) refuse("own-state-backup-unverified");
        durable(archive);
    }
    return { roots, sha256: digest, anchors };
}

function admission(value, phase) {
    let capacity = filter(require("service.preflight_resources").collect("/", value.components), (item) => item.object == "candidate-capacity");
    if (length(capacity) != 1 || capacity[0].state != "checked") refuse(capacity[0]?.reason ?? "resource-candidate-budget-unverified");
    let scratch = "/tmp/loki-admission." + require("service.gateway_secret").generate();
    if (!fs.mkdir(scratch, 0700)) refuse("preflight-scratch-unavailable");
    let accepted = false, reason = "preflight-incomplete-or-conflicting";
    try {
        for (let name in [ "loki", "loki/files", "loki/files/etc", "loki/files/etc/config", "check" ])
            if (!fs.mkdir(scratch + "/" + name, 0700)) refuse("preflight-scratch-unavailable");
        let source = lock.unmarked(paths.configurations[0]) ? value.directory + "/loki/files/etc/config/loki" : paths.configurations[0];
        let text = private_read(source, 1048576);
        let target = scratch + "/loki/files/etc/config/loki";
        if (text != null && common.write_private_file(target, text)) {
            let report = require("service.preflight").collect("/", value.manifest, target, scratch + "/check", scratch, value.digest, phase);
            accepted = report.complete === true && report.install_allowed === true && report.result == "checked";
            let failures = filter(report.observations ?? [], (item) => item.state == "conflict");
            if (length(failures) == 0) failures = filter(report.observations ?? [], (item) => item.state != "checked");
            let failure = failures[0]?.reason;
            if (type(failure) == "string" && length(failure) <= 84 && index(failure, "\u0000") < 0 && match(failure, /^[a-z][a-z0-9-]+$/))
                reason = "preflight-" + failure;
        }
    }
    catch (e) { accepted = false; }
    common.remove_tree(scratch);
    if (!lock.unmarked(scratch)) refuse("preflight-scratch-cleanup-failed");
    if (!accepted) refuse(reason);
}

function transaction_log(id) {
    require("core.cache_path").ensure({ cache_path: paths.log });
    if (!lock.unmarked(paths.log)) {
        let node = fs.lstat(paths.log);
        if (node?.type != "file" || node.uid != fs.stat("/proc/self").uid || node.nlink != 1 || (node.mode & 0777) != 0600)
            refuse("transaction-log-unavailable");
    }
    let temporary = paths.log + "." + id;
    if (!common.write_private_file(temporary, "") || !fs.rename(temporary, paths.log))
        refuse("transaction-log-unavailable");
    let file = fs.open(paths.log, "ae");
    if (file == null) refuse("transaction-log-unavailable");
    return file;
}

function check_files(value) {
    for (let component in value.components)
        for (let file in component.files) {
            if (file.type != "file" || index([ "/etc/config/loki", "/etc/config/loki-core", "/etc/loki-core/config.json" ], file.path) >= 0) continue;
            let path = (paths.payload_root == "/" ? "" : paths.payload_root) + file.path;
            if (require("singbox.runtime").file_digest(path, file) != file.sha256) return false;
        }
    return true;
}

function check_versions(value) {
    let installed = database(value.format).versions;
    for (let component in value.components)
        if (installed[component.package] != component.version) return false;
    return true;
}

function installed() {
    let store = common.parent_dir(paths.state);
    require("core.cache_path").validate({ cache_path: paths.state });
    let record = read();
    if (record?.error) refuse("installed-component-backup-unavailable");
    let checking_health = record?.phase == "health" && allowed();
    let digest = checking_health ? record.plan : private_read(store + "/active.sha256", 65);
    let directory = checking_health ? store + "/" + record.id + "/candidate" : store + "/active";
    if (digest == null) {
        if (!lock.unmarked(store + "/active.sha256") || !lock.unmarked(directory))
            refuse("installed-component-backup-unavailable");
        return null;
    }
    let value = candidate(directory, trim(digest));
    if (!check_versions(value) || !check_files(value)) refuse("installed-component-set-unverified");
    return value;
}

function start_admission() {
    try {
        let record = read();
        if (pending()) {
            if (!allowed()) return "component-transaction-recovery-required";
            if (index([ "health", "rollback" ], record?.phase) < 0) return "component-transaction-start-not-ready";
        }
        let value = installed();
        if (value == null) return "installed-component-backup-unavailable";
        admission(value, "start");
        return null;
    }
    catch (e) {
        return type(e.message) == "string" && length(e.message) <= 96 && index(e.message, "\u0000") < 0 &&
            match(e.message, /^[a-z][a-z0-9-]+$/) ? e.message : "start-preflight-failed";
    }
}

function restore(value, directory, saved) {
    if (saved.sha256 == null) return length(saved.roots) == 0;
    let archive = directory + "/state.tar";
    if (require("singbox.runtime").file_digest(archive) != saved.sha256) return false;
    for (let anchor in saved.anchors) {
        let node = fs.lstat(anchor.path);
        if (node?.type != "directory" || node.uid != fs.stat("/proc/self").uid || node.mode != anchor.mode ||
            node.inode != anchor.inode || node.dev.major != anchor.major || node.dev.minor != anchor.minor) return false;
    }
    state_tree(filter(saved.roots, (path) => !lock.unmarked(path)));
    return invoke(value, [ "/bin/busybox", "tar", "-xpf", archive, "-C", "/" ]) == 0;
}

function default_digest(value, ordinal) {
    let path = [ "/etc/config/loki", "/etc/config/loki-core" ][ordinal];
    for (let component in value.components)
        for (let file in component.files) if (file.path == path) return file.sha256;
    return null;
}

function preserve_configuration(directory, configuration, value) {
    for (let i = 0; i < length(configuration); i++) {
        let item = configuration[i];
        if (lock.unmarked(item.path)) continue;
        let digest = require("singbox.runtime").file_digest(item.path);
        if (digest == null) refuse("configuration-restore-path-unverified");
        if (digest == item.sha256 || digest == default_digest(value, i)) continue;
        copy_private(item.path, directory + "/changed-config." + i + "." + require("service.gateway_secret").generate(), digest);
    }
    durable(directory);
}

function restore_defaults(value, record, directory, saved, configuration) {
    let changed = false;
    for (let i = 0; i < length(configuration); i++) {
        let item = configuration[i];
        if (item.sha256 == null) continue;
        let current = require("singbox.runtime").file_digest(item.path);
        if (current == item.sha256) continue;
        if (!lock.unmarked(item.path) && (current == null || current != default_digest(value, i)))
            refuse("configuration-changed-during-update");
        changed = true;
    }
    if (changed && !restore(record, directory, saved)) refuse("own-state-restore-failed");
}

function discard_transaction(directory, created) {
    if (!created || directory == null) return;
    let node = fs.lstat(directory), names = fs.lsdir(directory);
    if (node?.type != "directory" || node.uid != fs.stat("/proc/self").uid || (node.mode & 0777) != 0700 || type(names) != "array") return;
    // Keep user changes captured during a concurrent commit; completed staging is reproducible.
    for (let name in names) if (substr(name, 0, 15) == "changed-config.") return;
    common.remove_tree(directory);
}

function restore_active(store, transaction, previous, plan) {
    let active = store + "/active";
    if (previous != null) {
        if (!lock.unmarked(transaction + "/previous")) {
            candidate(transaction + "/previous", previous.digest);
            if (!lock.unmarked(active)) {
                candidate(active, plan);
                if (!fs.rename(active, transaction + "/failed")) return false;
            }
            if (!fs.rename(transaction + "/previous", active)) return false;
        }
        candidate(active, previous.digest);
        if (!common.write_file_atomic(store + "/active.sha256", previous.digest + "\n")) return false;
        durable(store + "/active.sha256");
    }
    else {
        if (!lock.unmarked(active)) {
            candidate(active, plan);
            if (!fs.rename(active, transaction + "/failed")) return false;
        }
        if (!lock.unmarked(store + "/active.sha256") && !fs.unlink(store + "/active.sha256")) return false;
    }
    durable(store);
    return true;
}

function transition(value, phase) {
    let next = advance(value, phase);
    if (next == null) refuse("transaction-journal-failed");
    return next;
}

function recovery_metadata(record, directory) {
    let body = private_read(directory + "/backup.json", 65536);
    let metadata = common.parse_json(body);
    if (type(metadata) != "object" || body != sprintf("%J\n", metadata) ||
        join(",", sort(keys(metadata))) != "configuration,format,id,operation,plan,previous,saved,status" ||
        metadata.format != FORMAT || metadata.id != record.id || metadata.plan != record.plan || metadata.operation != record.operation ||
        metadata.previous != null && !hash(metadata.previous) || type(metadata.configuration) != "array" ||
        length(metadata.configuration) != length(paths.configurations) ||
        type(metadata.status?.running) != "bool" || type(metadata.status.enabled) != "bool" ||
        metadata.status.cache_path != null && type(metadata.status.cache_path) != "string")
        refuse("recovery-metadata-invalid");
    for (let i = 0; i < length(paths.configurations); i++) {
        let item = metadata.configuration[i];
        if (item?.path != paths.configurations[i] || item.sha256 != null && !hash(item.sha256) ||
            item.sha256 != null && require("singbox.runtime").file_digest(directory + "/config." + i) != item.sha256)
            refuse("recovery-configuration-unverified");
    }
    let saved = metadata.saved;
    if (saved != null) {
        let permitted = [ ...paths.configurations ];
        if (metadata.status.cache_path != null) {
            require("core.cache_path").validate({ cache_path: metadata.status.cache_path });
            for (let suffix in [ "", ".subscriptions", ".rule-sets" ]) push(permitted, metadata.status.cache_path + suffix);
        }
        if (type(saved.roots) != "array" || type(saved.anchors) != "array" || length(saved.anchors) != length(saved.roots) ||
            length(saved.roots) > length(permitted) || saved.sha256 != null && !hash(saved.sha256) ||
            (length(saved.roots) == 0) != (saved.sha256 == null)) refuse("recovery-backup-invalid");
        let seen = {};
        for (let i = 0; i < length(saved.roots); i++) {
            let path = saved.roots[i];
            if (type(path) != "string" || index(permitted, path) < 0 || seen[path] ||
                saved.anchors[i]?.path != common.parent_dir(path)) refuse("recovery-backup-path-unverified");
            seen[path] = true;
        }
        if (saved.sha256 != null && require("singbox.runtime").file_digest(directory + "/state.tar") != saved.sha256)
            refuse("recovery-backup-checksum-failed");
    }
    return metadata;
}

// Explicit recovery rolls back an interrupted package transaction; it never completes Apply.
function run_recovery() {
    let record = null;
    try {
        record = recover();
        if (record == null) refuse("transaction-not-recoverable");
        let store = common.parent_dir(paths.state), directory = store + "/" + record.id;
        let preapply = index([ "preparing", "prepared" ], record.phase) >= 0;
        if (lock.unmarked(directory + "/backup.json")) {
            if (record.phase != "preparing") refuse("recovery-backup-unavailable");
            record = transition(record, "aborted");
            discard_transaction(directory, true);
            return { success: true };
        }
        require("core.cache_path").validate({ cache_path: directory + "/backup.json" });
        let metadata = recovery_metadata(record, directory);
        let previous = metadata.previous == null ? null : candidate(
            lock.unmarked(directory + "/previous") ? store + "/active" : directory + "/previous", metadata.previous);
        if (preapply) {
            if (!unchanged(metadata.configuration)) refuse("configuration-changed-before-recovery");
        }
        else {
            if (metadata.saved == null) refuse("recovery-backup-unavailable");
            if (record.phase != "rollback") record = transition(record, "rollback");
            let prepared = candidate(lock.unmarked(directory + "/candidate") ? store + "/active" : directory + "/candidate", record.plan);
            if (previous != null && invoke(record, [ paths.cli, "stop" ]) != 0) refuse("recovery-stop-failed");
            preserve_configuration(directory, metadata.configuration, prepared);
            if (invoke(record, package_command(previous ?? prepared, previous == null ? "uninstall" : "rollback", false)) != 0 ||
                !restore(record, directory, metadata.saved) || previous != null && (!check_versions(previous) || !check_files(previous)) ||
                !restore_active(store, directory, previous, record.plan)) refuse("recovery-rollback-failed");
        }
        if (previous != null && (invoke(record, [ paths.cli, metadata.status.enabled ? "enable" : "disable" ]) != 0 ||
            metadata.status.running && (invoke(record, [ paths.cli, "start" ]) != 0 || invoke(record, [ paths.cli, "initd_status" ]) != 0)))
            refuse("recovery-service-health-failed");
        record = transition(record, preapply ? "aborted" : "rolled-back");
        discard_transaction(directory, true);
        return { success: true };
    }
    catch (e) {
        if (record != null && record.phase == "rollback") advance(record, "recovery-required");
        return { success: false, reason: "transaction-recovery-required", recovery_required: true };
    }
}

function run(directory, operation, expected) {
    let record = null, log = null, status = null, previous = null, saved = null, transaction = null;
    let stopped = false, applying = false, started = false, created = false, value = null, configuration = null;
    try {
        if (index([ "install", "update", "uninstall" ], operation) < 0 || !own_lease())
            refuse("transaction-not-authorized");
        value = candidate(directory, expected);
        let store = common.parent_dir(paths.state);
        let active_digest = private_read(store + "/active.sha256", 65);
        let before = database(value.format);
        let present = filter(value.names, (name) => before.versions[name] != null);
        if (length(present) > 0) {
            if (active_digest == null || !hash(trim(active_digest))) refuse("installed-component-backup-unavailable");
            previous = installed();
            if (previous == null || previous.format != value.format || join(",", previous.names) != join(",", value.names))
                refuse("installed-component-set-unverified");
        }
        else {
            if (operation != "install") refuse("own-components-not-installed");
            if (active_digest != null || !lock.unmarked(store + "/active")) refuse("active-component-state-unexpected");
        }
        admission(value);
        configuration = configuration_files();
        record = begin(operation, expected);
        if (record == null) refuse("transaction-busy-or-recovery-required");
        log = transaction_log(record.id);
        transaction = store + "/" + record.id;
        if (!fs.mkdir(transaction, 0700)) refuse("transaction-directory-unavailable");
        created = true;
        status = { running: false, enabled: false, cache_path: null };
        if (previous != null) {
            let result = invoke(record, [ paths.cli, "installer_snapshot" ], true);
            status = result.status == 0 ? common.parse_json(result.output) : null;
            if (type(status?.running) != "bool" || type(status.enabled) != "bool" || type(status.cache_path) != "string" || status.error != null)
                refuse("installed-service-snapshot-unavailable");
        }
        let prepared = stage(value, transaction + "/candidate");
        prepared.reinstall = previous != null && length(filter(prepared.components, (component) =>
            length(filter(previous.components, (prior) => prior.package == component.package && prior.version == component.version &&
                prior.artifact.sha256 != component.artifact.sha256)) > 0)) > 0;
        let simulation = invoke(record, package_command(prepared, operation, true), true);
        if (simulation.status != 0 || !package_plan(prepared, operation, simulation.output, before.versions))
            refuse("package-manager-plan-unverified");
        if (!unchanged(configuration) || database(value.format).body != before.body)
            refuse("environment-changed-before-transaction");
        let metadata = { format: FORMAT, id: record.id, plan: expected, operation,
            previous: previous?.digest, status, saved: null, configuration };
        for (let i = 0; i < length(configuration); i++)
            if (configuration[i].sha256 != null) copy_private(configuration[i].path, transaction + "/config." + i, configuration[i].sha256);
        if (!common.write_private_file(transaction + "/backup.json", sprintf("%J\n", metadata)))
            refuse("own-state-backup-failed");
        durable(transaction + "/backup.json"); durable(transaction); durable(store);
        if (previous != null) {
            if (invoke(record, [ paths.cli, "stop" ]) != 0) refuse("planned-stop-failed");
            stopped = true;
        }
        if (!unchanged(configuration)) refuse("configuration-changed-before-backup");
        admission(value, "preparing");
        saved = backup(record, transaction, status);
        metadata.saved = saved;
        if (!common.write_file_atomic(transaction + "/backup.json", sprintf("%J\n", metadata)))
            refuse("own-state-backup-failed");
        durable(transaction + "/backup.json"); durable(transaction); durable(store);
        record = transition(record, "prepared");
        admission(value, "prepared");
        if (!unchanged(configuration) || database(value.format).body != before.body)
            refuse("environment-changed-before-apply");
        record = transition(record, "applying");
        applying = true;
        let applied = invoke(record, package_command(prepared, operation, false), true);
        if (log.write(applied.output) != length(applied.output)) refuse("transaction-log-write-failed");
        if (applied.status != 0) refuse("package-manager-apply-failed");
        record = transition(record, "health");
        if (operation == "uninstall") {
            let remaining = database(value.format).versions;
            for (let name in value.names) if (remaining[name] != null) refuse("package-removal-incomplete");
            restore_defaults(prepared, record, transaction, saved, configuration);
            if (!fs.rename(store + "/active", transaction + "/previous") || !fs.unlink(store + "/active.sha256"))
                refuse("active-component-commit-failed");
            durable(store);
        }
        else {
            if (!check_versions(prepared) || !check_files(prepared)) refuse("installed-component-payload-mismatch");
            restore_defaults(prepared, record, transaction, saved, configuration);
            if (invoke(record, [ paths.cli, status.enabled ? "enable" : "disable" ]) != 0)
                refuse("updated-autostart-state-failed");
            if (status.running) {
                started = true;
                if (invoke(record, [ paths.cli, "start" ]) != 0 || invoke(record, [ paths.cli, "initd_status" ]) != 0)
                    refuse("updated-service-health-failed");
            }
            let active = store + "/active";
            if (!lock.unmarked(active) && !fs.rename(active, transaction + "/previous")) refuse("active-component-backup-failed");
            if (!fs.rename(transaction + "/candidate", active)) refuse("active-component-commit-failed");
            if (!common.write_file_atomic(store + "/active.sha256", expected + "\n")) refuse("active-component-commit-failed");
            durable(store + "/active.sha256"); durable(store);
        }
        record = transition(record, "committed");
        log.close();
        discard_transaction(transaction, created);
        return { success: true };
    }
    catch (e) {
        let observed = read();
        if (record != null && observed?.id == record.id && observed.phase == "committed" && !pending()) {
            if (log != null) { try { log.close(); } catch (ignored) {} }
            discard_transaction(transaction, created);
            return { success: true };
        }
        let reason = type(e.message) == "string" && length(e.message) <= 96 && index(e.message, "\u0000") < 0 && match(e.message, /^[a-z][a-z0-9-]+$/)
            ? e.message : "transaction-failed";
        let recovered = !applying;
        if (record == null && pending()) recovered = false;
        if (record != null && applying) {
            let next = advance(record, "rollback");
            if (next != null) {
                record = next;
                try {
                    if (started && invoke(record, [ paths.cli, "stop" ]) != 0) refuse("rollback-stop-failed");
                    preserve_configuration(transaction, configuration, value);
                    if (previous != null) {
                        let prior = lock.unmarked(transaction + "/previous") ? previous : candidate(transaction + "/previous", previous.digest);
                        recovered = invoke(record, package_command(prior, "rollback", false)) == 0 && restore(record, transaction, saved) && check_versions(prior) && check_files(prior);
                    }
                    else {
                        let removal = candidate(lock.unmarked(transaction + "/candidate") ? common.parent_dir(paths.state) + "/active" :
                            transaction + "/candidate", record.plan);
                        recovered = invoke(record, package_command(removal, "uninstall", false)) == 0 && restore(record, transaction, saved);
                    }
                    if (recovered) recovered = restore_active(common.parent_dir(paths.state), transaction, previous, record.plan);
                }
                catch (failure) { recovered = false; }
            }
            else recovered = false;
        }
        if (recovered && stopped && !applying && !unchanged(configuration)) recovered = false;
        if (recovered && previous != null)
            recovered = invoke(record, [ paths.cli, status.enabled ? "enable" : "disable" ]) == 0;
        if (recovered && stopped && status?.running)
            recovered = invoke(record, [ paths.cli, "start" ]) == 0 && invoke(record, [ paths.cli, "initd_status" ]) == 0;
        if (record != null) {
            let phase = recovered ? applying ? "rolled-back" : "aborted" : "recovery-required";
            if (advance(record, phase) == null) recovered = false;
        }
        if (log != null) log.close();
        if (recovered) discard_transaction(transaction, created);
        return { success: false, reason, recovery_required: !recovered };
    }
}

return { paths, read, context, pending, allowed, begin, advance, recover, run, run_recovery, candidate, package_plan, installed, start_admission, state_tree };
