let fs = require("fs");
let files = require("service.preflight_files");

const ENTRY_LIMIT = 4096;
const STAT_LIMIT = 4096;
const TOTAL_LIMIT = 16777216;
const TIME_LIMIT_MS = 8000;
const WIFI_PACKAGES = [ "wpad-basic-mbedtls", "wpad-basic-openssl", "wpad-basic-wolfssl", "wpad-mbedtls", "wpad-openssl", "wpad-wolfssl" ];
const SYSTEM_EXECUTABLES = {
    "/bin/busybox": [ "busybox" ], "/bin/ubus": [ "ubus" ], "/usr/bin/ucode": [ "ucode" ],
    "/sbin/procd": [ "procd" ], "/sbin/askfirst": [ "procd" ], "/sbin/ubusd": [ "ubusd" ],
    "/sbin/logd": [ "logd" ], "/sbin/netifd": [ "netifd" ], "/sbin/rpcd": [ "rpcd" ],
    "/sbin/urngd": [ "urngd" ], "/sbin/ujail": [ "procd-ujail" ],
    "/usr/sbin/dnsmasq": [ "dnsmasq", "dnsmasq-full", "dnsmasq-dhcpv6" ],
    "/usr/sbin/odhcpd": [ "odhcpd", "odhcpd-ipv6only" ], "/usr/sbin/dropbear": [ "dropbear" ],
    "/usr/sbin/uhttpd": [ "uhttpd" ], "/usr/sbin/wpad": WIFI_PACKAGES,
    "/usr/sbin/odhcp6c": [ "odhcp6c" ], "/usr/sbin/pppd": [ "ppp", "ppp-multilink" ]
};
const NAMES = { "loki-core": "own-core", "sing-box": "foreign-core", forkop: "foreign-app",
    podkop: "foreign-app", loki: "own-app", dnsmasq: "dns-service",
    ucode: "interpreter", busybox: "interpreter", sh: "interpreter", ash: "interpreter",
    bash: "interpreter", dash: "interpreter" };

function parse(data, pid) {
    if (type(pid) != "string" || !match(pid, /^[1-9][0-9]{0,9}$/) || int(pid) > 2147483647 ||
        type(data) != "string" || length(data) > STAT_LIMIT || index(data, "\u0000") >= 0 ||
        substr(data, 0, length(pid) + 2) != pid + " (" || substr(data, -1) != "\n")
        return { error: "process-stat-invalid" };
    // comm is raw kernel text and can itself contain closing parentheses and newlines.
    let end = rindex(data, ")");
    let size = end - length(pid) - 2;
    if (size < 0 || size > 64 || substr(data, end, 2) != ") ")
        return { error: "process-stat-invalid" };
    let fields = split(substr(data, end + 2, length(data) - end - 3), " ");
    if (length(fields) != 50 || !match(fields[0], /^[RSDTtXZPI]$/))
        return { error: "process-stat-invalid" };
    for (let i = 1; i < length(fields); i++)
        if (!match(fields[i], /^-?[0-9]{1,20}$/))
            return { error: "process-stat-invalid" };
    if (!match(fields[19], /^(0|[1-9][0-9]{0,19})$/))
        return { error: "process-stat-invalid" };
    if (!match(fields[6], /^(0|[1-9][0-9]{0,9})$/) || int(fields[6]) > 4294967295)
        return { error: "process-stat-invalid" };
    return { start: fields[19], kernel_thread: (int(fields[6]) & 0x00200000) != 0 };
}

function now_ms() {
    let now = clock(true);
    if (type(now) != "array" || length(now) != 2 || type(now[0]) != "int" || type(now[1]) != "int")
        return null;
    return now[0] * 1000 + int(now[1] / 1000000);
}

function expired(budget) {
    let now = now_ms();
    return now == null || budget.started == null || now < budget.started || now - budget.started >= TIME_LIMIT_MS;
}

function read_stat(path, pid, budget) {
    if (expired(budget)) return { error: "process-time-limit" };
    if (budget.bytes + STAT_LIMIT + 1 > TOTAL_LIMIT) return { error: "process-aggregate-byte-limit" };
    let node = fs.lstat(path);
    if (node?.type != "file" || node.nlink != 1 || (node.mode & 0022) != 0)
        return { error: "process-stat-unavailable" };
    let file = fs.open(path, "re");
    if (file == null) return { error: "process-stat-unavailable" };
    let result;
    try {
        let descriptor = "/proc/self/fd/" + file.fileno();
        if (!files.same_node(node, fs.stat(descriptor)))
            result = { error: "process-changed-during-read" };
        else {
            fs.error();
            let data = file.read(STAT_LIMIT + 1);
            let error = file.error();
            budget.bytes += type(data) == "string" ? length(data) : 0;
            if (error != null || type(data) != "string") result = { error: "process-stat-read-failed" };
            else if (length(data) > STAT_LIMIT) result = { error: "process-stat-size-limit" };
            else if (!files.same_node(node, fs.stat(descriptor)) || !files.same_node(node, fs.lstat(path)))
                result = { error: "process-changed-during-read" };
            else result = parse(data, pid);
        }
    }
    catch (e) { result = { error: "process-stat-read-failed" }; }
    try { if (!file.close()) result = { error: "process-stat-read-failed" }; }
    catch (e) { result = { error: "process-stat-read-failed" }; }
    return result;
}

function executable(path, budget) {
    if (expired(budget)) return { error: "process-time-limit" };
    if (budget.bytes + 4096 > TOTAL_LIMIT) return { error: "process-aggregate-byte-limit" };
    let node = fs.lstat(path);
    if (node?.type != "link") return { error: "process-executable-unavailable" };
    // Linux proc_pid_readlink uses PATH_MAX; the link text is never executed or reported.
    let name = fs.readlink(path);
    budget.bytes += type(name) == "string" ? length(name) : 0;
    if (type(name) != "string" || length(name) == 0 || length(name) >= 4096 ||
        !match(name, /^\/[ -~]+$/) || substr(name, -10) == " (deleted)")
        return { error: "process-executable-unavailable" };
    let target = fs.stat(path);
    if (target?.type != "file" || !files.same_node(node, fs.lstat(path)))
        return { error: "process-executable-unavailable" };
    return { name, target };
}

function inspect(directory, pid, budget) {
    let path = directory + "/" + pid;
    let node = fs.lstat(path);
    if (node?.type != "directory" || (node.mode & 0022) != 0)
        return { error: "process-directory-entry-unavailable" };
    let first = read_stat(path + "/stat", pid, budget);
    if (first.error != null) return first;
    // PF_KTHREAD is supplied by the trusted kernel; these tasks have no userspace executable.
    if (first.kernel_thread) {
        let second = read_stat(path + "/stat", pid, budget);
        if (second.error != null) return second;
        if (!second.kernel_thread || first.start != second.start || !files.same_node(node, fs.lstat(path)))
            return { error: "process-changed-during-read" };
        return {};
    }
    let exe = executable(path + "/exe", budget);
    if (exe.error != null) return exe;
    let second = read_stat(path + "/stat", pid, budget);
    if (second.error != null) return second;
    let final = executable(path + "/exe", budget);
    if (final.error != null) return final;
    if (first.start != second.start || exe.name != final.name ||
        !files.same_node(exe.target, final.target) || !files.same_node(node, fs.lstat(path)))
        return { error: "process-changed-during-read" };
    return { hint: NAMES[substr(exe.name, rindex(exe.name, "/") + 1)], executable: exe };
}

function executable_origin(root, value, provenance) {
    if (!provenance?.complete || !provenance.system) return false;
    if (value.executable == null) return true;
    let exe = value.executable, path = substr(exe.name, length(root));
    if (substr(exe.name, 0, length(root) + 1) != root + "/") return false;
    let claims = provenance.claims[path] ?? [], own = provenance.own_files?.[path];
    if (length(claims) != 1) return false;
    let system = index(SYSTEM_EXECUTABLES[path] ?? [], claims[0]) >= 0;
    let own_core = path == "/usr/bin/loki-core" && claims[0] == "loki-core" && own?.package == "loki-core" &&
        own.type == "file" && own.mode == 0755 && own.size == exe.target.size;
    if (!system && !own_core) return false;
    let safe = files.collect(root || "/", { [path]: "file" })[0];
    let node = fs.lstat(root + path);
    return safe.reason == "candidate-existing-file-origin-unverified" && files.same_node(node, exe.target) &&
        ((node.mode & 07777) == 0755 || path == "/bin/busybox" && (node.mode & 07777) == 04755);
}

function collect(root, scope, provenance) {
    root = root == "/" ? "" : root;
    let result = [];
    let add = (object, state, reason) => push(result, { kind: "processes", object, state, reason });
    let directory = root + "/proc";
    let checked = files.collect(root || "/", { "/proc": "directory" })[0];
    let errors = {};
    let hints = {}, origins = true;
    let budget = { bytes: 0, started: now_ms() };
    let node = fs.lstat(directory);
    let handle = checked.reason == "candidate-directory-safe" ? fs.opendir(directory) : null;
    if (handle == null) errors["process-directory-unavailable"] = true;
    else {
        try {
            if (!files.same_node(node, fs.stat("/proc/self/fd/" + handle.fileno())))
                errors["process-directory-changed"] = true;
            else {
                let count = 0;
                while (true) {
                    if (expired(budget)) { errors["process-time-limit"] = true; break; }
                    fs.error();
                    let entry = handle.read();
                    let error = fs.error();
                    if (entry == null) {
                        if (error != null) errors["process-directory-read-failed"] = true;
                        break;
                    }
                    if (++count > ENTRY_LIMIT) { errors["process-directory-entry-limit"] = true; break; }
                    if (!match(entry, /^[0-9]+$/)) continue;
                    if (!match(entry, /^[1-9][0-9]{0,9}$/) || int(entry) > 2147483647) {
                        errors["process-directory-entry-invalid"] = true;
                        continue;
                    }
                    let value = inspect(directory, entry, budget);
                    if (value.error != null) errors[value.error] = true;
                    else {
                        if (value.hint != null) hints[value.hint] = true;
                        if (provenance != null && !executable_origin(root, value, provenance)) origins = false;
                    }
                    if (value.error == "process-time-limit" || value.error == "process-aggregate-byte-limit") break;
                }
            }
        }
        catch (e) { errors["process-directory-read-failed"] = true; }
        try { if (!handle.close()) errors["process-directory-read-failed"] = true; }
        catch (e) { errors["process-directory-read-failed"] = true; }
        if (!files.same_node(node, fs.lstat(directory))) errors["process-directory-changed"] = true;
        if (expired(budget)) errors["process-time-limit"] = true;
        if (length(keys(errors)) == 0) add("proc-directory", "checked", "process-directory-read-complete");
    }
    for (let reason in sort(keys(errors))) add("proc-directory", "incomplete", reason);
    // The caller rechecks the trusted procfs and PID1-relative scope after this inventory.
    let visible = length(keys(errors)) == 0 && scope?.error == null && type(scope?.identities) == "object";
    add("visibility", visible ? "checked" : "incomplete",
        visible ? "process-pid1-scope-inventory-checked" : "process-namespace-and-visibility-unverified");
    // OS binaries and authorized root commands are trusted; hooks and network state are checked separately.
    let verified = visible && origins && provenance?.complete && provenance.system;
    for (let hint in sort(keys(hints))) add(hint, verified ? "checked" : "incomplete",
        verified ? "process-executable-provenance-checked" : "process-executable-name-hint-unverified");
    add("origin", verified ? "checked" : "incomplete",
        verified ? "process-executable-provenance-checked" : "process-script-and-package-origin-unverified");
    return result;
}

return { collect, parse, read_stat, executable, targets: keys(SYSTEM_EXECUTABLES) };
