let fs = require("fs");
let files = require("service.preflight_files");

const ENTRY_LIMIT = 4096;
const STAT_LIMIT = 4096;
const TOTAL_LIMIT = 16777216;
const TIME_LIMIT_MS = 8000;
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
    return { start: fields[19] };
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
    let exe = executable(path + "/exe", budget);
    if (exe.error != null) return exe;
    let second = read_stat(path + "/stat", pid, budget);
    if (second.error != null) return second;
    let final = executable(path + "/exe", budget);
    if (final.error != null) return final;
    if (first.start != second.start || exe.name != final.name ||
        !files.same_node(exe.target, final.target) || !files.same_node(node, fs.lstat(path)))
        return { error: "process-changed-during-read" };
    return { hint: NAMES[substr(exe.name, rindex(exe.name, "/") + 1)] };
}

function collect(root) {
    root = root == "/" ? "" : root;
    let result = [];
    let add = (object, state, reason) => push(result, { kind: "processes", object, state, reason });
    let directory = root + "/proc";
    let checked = files.collect(root || "/", { "/proc": "directory" })[0];
    let errors = {};
    let hints = {};
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
                    else if (value.hint != null) hints[value.hint] = true;
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
    for (let hint in sort(keys(hints))) add(hint, "incomplete", "process-executable-name-hint-unverified");
    // Repeated reads cannot reserve a PID, reveal hidden namespaces or identify interpreter scripts.
    add("visibility", "incomplete", "process-namespace-and-visibility-unverified");
    add("origin", "incomplete", "process-script-and-package-origin-unverified");
    return result;
}

return { collect, parse };
