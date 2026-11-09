let fs = require("fs");
let files = require("service.preflight_files");
let exec = require("core.exec");

const MEMORY_LIMIT = 65536;
const FILESYSTEM_LIMIT = 16384;
const MAX_KB = 8796093022207;
const QUERY = [ "/usr/bin/env", "-i", "PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C", "/bin/df", "-Pk", "/", "/tmp" ];
const MEMORY_FIELDS = [ "MemTotal", "MemAvailable", "SwapTotal", "SwapFree" ];

function parse_meminfo(data) {
    if (type(data) != "string" || data == "" || length(data) > MEMORY_LIMIT ||
        substr(data, -1) != "\n" || index(data, "\u0000") >= 0)
        return { error: "resource-memory-data-invalid" };
    let values = {};
    for (let line in split(substr(data, 0, length(data) - 1), "\n")) {
        let entry = match(line, /^([A-Za-z0-9_()]+):[ \t]+(0|[1-9][0-9]*)([ \t]+kB)?[ \t]*$/);
        if (entry == null)
            return { error: "resource-memory-data-invalid" };
        let name = entry[1];
        if (index(MEMORY_FIELDS, name) < 0)
            continue;
        if (values[name] != null || entry[3] == null || length(entry[2]) > 13 || int(entry[2]) > MAX_KB)
            return { error: "resource-memory-data-invalid" };
        values[name] = int(entry[2]);
    }
    for (let name in MEMORY_FIELDS)
        if (values[name] == null)
            return { error: "resource-memory-data-invalid" };
    if (values.MemTotal == 0 || values.MemAvailable > values.MemTotal || values.SwapFree > values.SwapTotal)
        return { error: "resource-memory-data-invalid" };
    return { total_bytes: values.MemTotal * 1024, available_bytes: values.MemAvailable * 1024,
        swap_total_bytes: values.SwapTotal * 1024, swap_free_bytes: values.SwapFree * 1024 };
}

function parse_df(data) {
    if (type(data) != "string" || length(data) > FILESYSTEM_LIMIT || substr(data, -1) != "\n" ||
        index(data, "\u0000") >= 0 || index(data, "\r") >= 0)
        return { error: "resource-filesystem-data-invalid" };
    let lines = split(substr(data, 0, length(data) - 1), "\n");
    if (length(lines) != 3 || index([ "Filesystem 1024-blocks Used Available Capacity Mounted on",
        "Filesystem 1024-blocks Used Available Use% Mounted on" ], join(" ", split(trim(lines[0]), /[ \t]+/))) < 0)
        return { error: "resource-filesystem-data-invalid" };
    let values = [];
    for (let line in slice(lines, 1)) {
        let columns = split(trim(line), /[ \t]+/);
        if (length(columns) != 6 || columns[0] == "" || substr(columns[5], 0, 1) != "/" ||
            !match(columns[4], /^(0|[1-9][0-9]?|100)%$/))
            return { error: "resource-filesystem-data-invalid" };
        let numbers = [];
        for (let value in slice(columns, 1, 4)) {
            if (!match(value, /^(0|[1-9][0-9]{0,12})$/) || int(value) > MAX_KB)
                return { error: "resource-filesystem-data-invalid" };
            push(numbers, int(value));
        }
        if (numbers[0] == 0 || numbers[1] > numbers[0] || numbers[2] > numbers[0])
            return { error: "resource-filesystem-data-invalid" };
        push(values, { total_bytes: numbers[0] * 1024, used_bytes: numbers[1] * 1024, available_bytes: numbers[2] * 1024 });
    }
    // Device and mount names are untrusted labels, never commands or report contents.
    return { root: values[0], temporary: values[1] };
}

function memory(root, owner) {
    let directory = fs.lstat(root + "/proc");
    if (directory == null)
        return { error: "resource-memory-unavailable" };
    if (directory.type != "directory" || directory.uid != owner || (directory.mode & 0022) != 0)
        return { error: "resource-memory-path-unsafe" };
    let path = root + "/proc/meminfo";
    let before = fs.lstat(path);
    if (before == null)
        return { error: "resource-memory-unavailable" };
    if (before.type != "file" || before.uid != owner || before.nlink != 1 || (before.mode & 0022) != 0)
        return { error: "resource-memory-path-unsafe" };
    if (before.size > MEMORY_LIMIT)
        return { error: "resource-memory-size-limit" };
    let file = fs.open(path, "re");
    if (file == null)
        return { error: "resource-memory-unavailable" };
    let result;
    try {
        let descriptor = "/proc/self/fd/" + file.fileno();
        if (!files.same_node(before, fs.stat(descriptor)))
            result = { error: "resource-memory-changed-during-read" };
        else {
            // Procfs reports size zero; enforce the read budget on the actual returned bytes.
            fs.error();
            let data = file.read(MEMORY_LIMIT + 1);
            let error = file.error();
            let parent = fs.lstat(root + "/proc");
            if (error != null || type(data) != "string") result = { error: "resource-memory-read-failed" };
            else if (length(data) > MEMORY_LIMIT) result = { error: "resource-memory-size-limit" };
            else if (!files.same_node(before, fs.stat(descriptor)) || !files.same_node(before, fs.lstat(path)))
                result = { error: "resource-memory-changed-during-read" };
            // Procfs directory link counts change as processes start; compare its stable identity and permissions.
            else if (parent?.type != "directory" || parent.inode != directory.inode ||
                parent.dev.major != directory.dev.major || parent.dev.minor != directory.dev.minor ||
                parent.uid != directory.uid || parent.mode != directory.mode)
                result = { error: "resource-memory-changed-during-read" };
            else result = parse_meminfo(data);
        }
    }
    catch (e) { result = { error: "resource-memory-read-failed" }; }
    try { if (!file.close()) result = { error: "resource-memory-read-failed" }; }
    catch (e) { result = { error: "resource-memory-read-failed" }; }
    return result;
}

function filesystem() {
    let result = exec.deadline(QUERY, 2, FILESYSTEM_LIMIT);
    if (result.output_limit) return { error: "resource-filesystem-size-limit" };
    if (type(result.status) != "int" || result.status != 0 || result.output == "") return { error: "resource-filesystem-query-failed" };
    return parse_df(result.output);
}

function candidate_need(components) {
    if (type(components) != "array" || length(components) == 0 || length(components) > 4) return null;
    let archives = 0, unpacked = 0, entries = 0;
    for (let component in components) {
        let size = component?.artifact?.size;
        if (type(size) != "int" || size < 1 || size > 536870912 || type(component.files) != "array") return null;
        archives += size;
        for (let file in component.files) {
            if (++entries > 4096 || type(file?.size) != "int" || file.size < 0 || file.size > 536870912 ||
                index([ "file", "directory" ], file.type) < 0 || file.type == "directory" && file.size != 0) return null;
            unpacked += file.size;
            if (unpacked > 536870912) return null;
        }
    }
    // Account for both compressed archives and a full payload, even for an already staged offline kit.
    let temporary_bytes = max(max(2 * archives, archives + unpacked), 4 * 1048576);
    return { temporary_bytes, memory_bytes: max(temporary_bytes, 48 * 1048576) };
}

function collect(root, components) {
    root ??= "/";
    let result = [];
    let add = (object, state, reason) => push(result, { kind: "resources", object, state, reason });
    let base = type(root) == "string" ? fs.lstat(root) : null;
    if (base?.type != "directory" || (base.mode & 0022) != 0 || fs.realpath(root) != root ||
        (root == "/" && base.uid != 0)) {
        add("resource-root", "incomplete", "resource-root-unsafe");
        return result;
    }
    let ram = memory(root == "/" ? "" : root, base.uid);
    let disk = filesystem();
    add("memory-snapshot", ram.error == null ? "checked" : "incomplete", ram.error ?? "resource-memory-snapshot-read-complete");
    add("filesystem-snapshot", disk.error == null ? "checked" : "incomplete", disk.error ?? "resource-filesystem-snapshot-read-complete");
    if (components != null) {
        let need = candidate_need(components);
        let reason = ram.error ?? disk.error ?? (need == null ? "resource-candidate-budget-unverified" :
            ram.available_bytes < need.memory_bytes ? "resource-candidate-memory-insufficient" :
            disk.temporary.available_bytes < need.temporary_bytes ? "resource-candidate-tmpfs-insufficient" : "resource-candidate-capacity-checked");
        add("candidate-capacity", reason == "resource-candidate-capacity-checked" ? "checked" :
            index([ "resource-candidate-memory-insufficient", "resource-candidate-tmpfs-insufficient" ], reason) >= 0 ? "conflict" : "incomplete", reason);
    }
    // Readable counters do not prove transaction peak RAM/disk needs, tmpfs accounting or namespace identity.
    add("resource-budget", "incomplete", "resource-transaction-budget-namespace-unverified");
    return result;
}

function transaction_need(components, previous, snapshot) {
    let base = candidate_need(components);
    if (base == null || type(snapshot) != "object" || index([ null, "preparing", "prepared", "start" ], snapshot.phase) < 0)
        return null;
    for (let name in [ "bytes", "archive_bytes", "entries", "configuration_bytes", "database_bytes" ])
        if (type(snapshot[name]) != "int" || snapshot[name] < 0) return null;
    if (snapshot.bytes > 2147483647 || snapshot.archive_bytes < snapshot.bytes || snapshot.archive_bytes > 2147483647 ||
        snapshot.entries > 16384 || snapshot.configuration_bytes > 2097152 || snapshot.database_bytes > 4194304 ||
        snapshot.bytes > 0 && snapshot.entries == 0) return null;
    let prior = previous == null ? null : candidate_need(previous);
    if (previous != null && prior == null) return null;
    if (snapshot.phase == "start") return { root_bytes: 4 * 1048576, ...base };
    let payload = 0, archives = 0, controls = 0;
    for (let group in [ components, previous ?? [] ]) {
        let size = 0;
        controls = max(controls, length(group) * 4 * 1048576);
        for (let component in group) {
            for (let file in component.files) size += int((file.size + 4095) / 4096) * 4096 + 4096;
        }
        payload = max(payload, size);
    }
    for (let component in components) archives += int((component.artifact.size + 4095) / 4096) * 4096;
    // Package control dumps are bounded to 4 MiB each; allow both copies of the package database.
    let root_bytes = payload + controls + 2 * snapshot.database_bytes + snapshot.configuration_bytes;
    if (snapshot.phase == null) root_bytes += archives + 2097152 + snapshot.configuration_bytes;
    if (snapshot.phase != "prepared" && snapshot.entries > 0) root_bytes += snapshot.archive_bytes;
    let temporary_bytes = max(base.temporary_bytes, prior?.temporary_bytes ?? 0) + snapshot.bytes;
    return { root_bytes, temporary_bytes, memory_bytes: max(temporary_bytes, 48 * 1048576) };
}

function transaction(root, context) {
    let result = { kind: "resources", object: "resource-budget", state: "incomplete", reason: "resource-transaction-budget-namespace-unverified" };
    try {
        if (context?.scope?.error != null || type(context?.scope?.identities) != "object") return result;
        let prefix = root == "/" ? "" : root, own = fs.stat(root), temporary = fs.stat(prefix + "/tmp");
        if (own?.type != "directory" || own.uid != fs.stat("/proc/self").uid || (own.mode & 0022) != 0 ||
            fs.realpath(root) != root || temporary?.type != "directory") return result;
        let roots = [], configuration_bytes = 0, lock = require("service.lock");
        for (let name in [ "/etc/config/loki", "/etc/config/loki-core" ]) {
            let path = prefix + name;
            if (lock.unmarked(path)) continue;
            let node = fs.lstat(path);
            if (node?.type != "file") return result;
            configuration_bytes += node.size; push(roots, path);
        }
        if (context.previous != null && context.phase != "start") {
            let cache = prefix + require("core.cache_path").effective_path(context.settings);
            require("core.cache_path").validate({ cache_path: cache });
            for (let suffix in [ "", ".subscriptions", ".rule-sets" ])
                if (!lock.unmarked(cache + suffix)) push(roots, cache + suffix);
        }
        let database = prefix + (context.components?.[0]?.format == "apk" ? "/lib/apk/db/installed" : "/usr/lib/opkg/status");
        let node = fs.lstat(database);
        if (node?.type != "file" || node.uid != own.uid || node.nlink != 1 || (node.mode & 0022) != 0 ||
            node.dev.major != own.dev.major || node.dev.minor != own.dev.minor) return result;
        let snapshot = require("service.update").state_tree(roots);
        let permitted = [ own.dev.major + ":" + own.dev.minor, temporary.dev.major + ":" + temporary.dev.minor ];
        for (let device in snapshot.devices) if (index(permitted, device) < 0) return result;
        snapshot.configuration_bytes = configuration_bytes; snapshot.database_bytes = node.size; snapshot.phase = context.phase;
        let need = transaction_need(context.components, context.previous, snapshot);
        if (need == null) return result;
        let seen = {}, targets = [ "/etc/loki/update" ];
        for (let component in context.components)
            for (let file in component.files) push(targets, file.path);
        for (let target in targets) {
            let path = prefix;
            for (let part in split(target, "/")) {
                if (part == "") continue;
                path += "/" + part;
                if (seen[path]) continue;
                seen[path] = true;
                let entry = fs.lstat(path);
                if (entry == null) { if (lock.unmarked(path)) continue; return result; }
                if (entry.type == "link" || entry.dev.major != own.dev.major || entry.dev.minor != own.dev.minor)
                    return result;
            }
        }
        let ram = memory(prefix, own.uid), disk = filesystem();
        if (ram.error != null || disk.error != null) { result.reason = ram.error ?? disk.error; return result; }
        let again = require("service.update").state_tree(roots);
        if (again.bytes != snapshot.bytes || again.entries != snapshot.entries || again.archive_bytes != snapshot.archive_bytes ||
            sprintf("%J", again.devices) != sprintf("%J", snapshot.devices)) {
            result.reason = "resource-backup-footprint-changed"; return result;
        }
        let shared = own.dev.major == temporary.dev.major && own.dev.minor == temporary.dev.minor;
        let root_need = need.root_bytes + (shared ? need.temporary_bytes : 0);
        let temporary_need = shared ? root_need : need.temporary_bytes;
        result.reason = ram.available_bytes < need.memory_bytes ? "resource-transaction-memory-insufficient" :
            disk.root.available_bytes < root_need ? "resource-transaction-storage-insufficient" :
            disk.temporary.available_bytes < temporary_need ? "resource-transaction-tmpfs-insufficient" : "resource-transaction-capacity-checked";
        result.state = result.reason == "resource-transaction-capacity-checked" ? "checked" : "conflict";
    }
    catch (e) { result.reason = "resource-own-state-budget-unverified"; }
    return result;
}

return { collect, parse_meminfo, parse_df, candidate_need, transaction_need, transaction };
