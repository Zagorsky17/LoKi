let fs = require("fs");
let files = require("service.preflight_files");

const MEMORY_LIMIT = 65536;
const FILESYSTEM_LIMIT = 16384;
const MAX_KB = 8796093022207;
const QUERY = "exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -s KILL 2 /bin/df -Pk / /tmp 2>/dev/null";
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
    if (length(lines) != 3 || join(" ", split(trim(lines[0]), /[ \t]+/)) !=
        "Filesystem 1024-blocks Used Available Capacity Mounted on")
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
    let pipe;
    try { pipe = fs.popen(QUERY, "r"); }
    catch (e) { return { error: "resource-filesystem-query-failed" }; }
    if (pipe == null) return { error: "resource-filesystem-query-failed" };
    let data;
    let status;
    let failed = false;
    try { data = pipe.read(FILESYSTEM_LIMIT + 1); }
    catch (e) { failed = true; }
    try { status = pipe.close(); }
    catch (e) { failed = true; }
    if (type(data) == "string" && length(data) > FILESYSTEM_LIMIT)
        return { error: "resource-filesystem-size-limit" };
    if (failed || type(status) != "int" || status != 0 || type(data) != "string")
        return { error: "resource-filesystem-query-failed" };
    return parse_df(data);
}

function collect(root) {
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
    // Readable counters do not prove transaction peak RAM/disk needs, tmpfs accounting or namespace identity.
    add("resource-budget", "incomplete", "resource-transaction-budget-namespace-unverified");
    return result;
}

return { collect, parse_meminfo, parse_df };
