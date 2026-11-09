// Kernel leases serialize lifecycle actions; request markers queue work between processes.

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let process = require("core.process");

const DEFAULT_OWNER_GRACE = 30;
const KERNEL_MAGIC = "loki-lock-v1\n";
let leases = {};

function owner_of(lock_dir) {
    let dir = fs.lstat(lock_dir);
    if (dir == null || dir.type != "directory" || dir.uid != fs.stat("/proc/self").uid ||
        (dir.mode & 0022) != 0)
        return null;

    fs.lstat("");
    let missing = fs.error();
    let node = fs.lstat(lock_dir + "/pid");
    let failure = fs.error();
    if (node == null)
        return missing != null && failure == missing ? { pid: "", node: null } : null;
    if (node.type != "file" || node.nlink != 1 || node.uid != dir.uid || (node.mode & 0022) != 0)
        return null;

    let file = fs.open(lock_dir + "/pid", "re");
    if (file == null)
        return null;
    let body = file.read(129);
    let read_error = file.error();
    let closed = file.close();
    if (read_error != null || closed !== true || length(body) > 128 || index(body ?? "", "\x00") >= 0)
        return null;
    if (body == null || body == "")
        return { pid: "", node };

    let fields = split(body, "\n");
    if (fields[-1] == "") pop(fields);
    if (length(fields) < 1 || length(fields) > 2 || match(fields[0], /^[1-9][0-9]{0,9}$/) == null ||
        (length(fields) == 2 && (match(fields[1], /^[0-9]{1,19}$/) == null ||
            int(fields[1]) < 0 || "" + int(fields[1]) != fields[1])))
        return null;
    return { pid: fields[0], ticks: length(fields) == 2 ? fields[1] : null, node };
}

function same_node(a, b) {
    return a != null && b != null && a.inode == b.inode &&
        a.dev.major == b.dev.major && a.dev.minor == b.dev.minor;
}

function close_file(file) {
    try { return file.close() === true; }
    catch (e) { return false; }
}

// fs reports translated error text; establish ENOENT without trusting a failed marker stat.
function unmarked(path) {
    try {
        fs.lstat("");
        let missing = fs.error();
        let node = fs.lstat(path);
        let failure = fs.error();
        return missing != null && node == null && failure == missing;
    }
    catch (e) { return false; }
}

function safe_anchor(node, uid) {
    return node != null && node.type == "file" && node.nlink == 1 && node.uid == uid &&
        (node.mode & 0777) == 0600 && node.size <= length(KERNEL_MAGIC);
}

function anchor(lock_dir, create) {
    let dir = fs.lstat(lock_dir);
    if (dir == null || dir.type != "directory" || dir.uid != fs.stat("/proc/self").uid ||
        (dir.mode & 0022) != 0)
        return null;
    let path = lock_dir + "/.kernel";
    let node = fs.lstat(path);
    if (node != null && !safe_anchor(node, dir.uid))
        return null;
    let file = node == null && create && unmarked(path) ? fs.open(path, "wx+e", 0600)
        : node != null ? fs.open(path, create ? "r+e" : "re") : null;
    if (file == null)
        return null;
    let opened = fs.stat("/proc/self/fd/" + file.fileno());
    let current = fs.lstat(path);
    if (!safe_anchor(current, dir.uid) || !same_node(current, opened) || !same_node(dir, fs.lstat(lock_dir))) {
        close_file(file);
        return null;
    }
    return file;
}

function protocol(file) {
    if (file.seek(0) == null)
        return null;
    let body = file.read(length(KERNEL_MAGIC) + 1) ?? "";
    if (file.error() != null || length(body) > length(KERNEL_MAGIC) ||
        substr(KERNEL_MAGIC, 0, length(body)) != body)
        return null;
    return { initialized: body != "", complete: body == KERNEL_MAGIC };
}

function publish_protocol(file) {
    if (file.seek(0) == null || file.write(KERNEL_MAGIC) != length(KERNEL_MAGIC))
        return false;
    // Seeking flushes buffered output; older ucode flush() misreports successful writes.
    return file.error() == null && file.seek(0) != null &&
        file.read(length(KERNEL_MAGIC) + 1) == KERNEL_MAGIC && file.error() == null;
}

function legacy_held(owner, stat, owner_grace) {
    if (owner == null || (owner.pid == "" && owner.node != null))
        return true;
    if (common.pid_alive(owner.pid)) {
        let ticks = owner.ticks == null ? null : process.start_ticks(owner.pid);
        return ticks == null || "" + ticks == owner.ticks;
    }
    if (owner.pid != "")
        return !unmarked("/proc/" + owner.pid);
    let age = common.now_seconds() - stat.mtime;
    return age >= 0 && age < (owner_grace ?? DEFAULT_OWNER_GRACE);
}

// Queries never create anchors; closing their independent FD cannot release the holder.
function held(lock_dir, owner_grace) {
    if (lock_dir == "")
        return false;
    if (leases[lock_dir] != null)
        return true;
    let file = null;
    let result = true;
    try {
        let stat = fs.lstat(lock_dir);
        if (stat == null)
            return !unmarked(lock_dir);
        if (unmarked(lock_dir + "/.kernel"))
            return legacy_held(owner_of(lock_dir), stat, owner_grace);
        file = anchor(lock_dir, false);
        if (file != null && file.lock("xn")) {
            let state = protocol(file);
            let owner = owner_of(lock_dir);
            result = state == null || owner == null || (!state.initialized && legacy_held(owner, stat, owner_grace));
        }
    }
    catch (e) { result = true; }
    if (file != null && !close_file(file))
        result = true;
    return result;
}

function release(lock_dir, owner) {
    let lease = leases[lock_dir];
    if (lease == null || owner != common.own_pid() || "" + process.start_ticks(owner) != lease.ticks)
        return;
    let recorded = owner_of(lock_dir);
    if (recorded == null || recorded.pid != owner || recorded.ticks != lease.ticks)
        return;
    if (same_node(recorded.node, fs.lstat(lock_dir + "/pid")))
        fs.unlink(lock_dir + "/pid");
    if (close_file(lease.file))
        delete leases[lock_dir];
}

function write_owner(lock_dir, owner, ticks, file, initialized) {
    let path = lock_dir + "/pid";
    let record = fs.open(path, "wxe", 0600);
    if (record == null)
        return false;
    let node = fs.stat("/proc/self/fd/" + record.fileno());
    let body = owner + "\n" + ticks + "\n";
    let written = false;
    try {
        written = record.write(body) == length(body);
        if (written && !initialized)
            written = publish_protocol(file);
    }
    catch (e) { written = false; }
    let closed = close_file(record);
    if (written && closed)
        return true;
    if (same_node(node, fs.lstat(path)))
        fs.unlink(path);
    return false;
}

function prepare_owner(lock_dir, owner, ticks, file, created, owner_grace) {
    let state = protocol(file);
    let recorded = owner_of(lock_dir);
    if (state == null || recorded == null)
        return false;
    if (!state.initialized && !created && legacy_held(recorded, fs.lstat(lock_dir), owner_grace))
        return false;
    // Only a fresh directory can publish before its exclusive owner write.
    if ((created || state.initialized) && !state.complete) {
        if (!publish_protocol(file))
            return false;
        state.initialized = true;
    }
    if (recorded.node != null && (!same_node(recorded.node, fs.lstat(lock_dir + "/pid")) ||
        !fs.unlink(lock_dir + "/pid")))
        return false;
    return write_owner(lock_dir, owner, ticks, file, state.initialized);
}

function acquire(lock_dir, owner, owner_grace) {
    let ticks = process.start_ticks(owner);
    if (lock_dir == "" || leases[lock_dir] != null || owner != common.own_pid() || ticks == null ||
        !common.ensure_dir(common.parent_dir(lock_dir)))
        return false;
    let file = null;
    let acquired = false;
    try {
        let created = fs.mkdir(lock_dir, 0755);
        fs.error(); // anchor() validates an existing directory; discard the handled mkdir error.
        file = anchor(lock_dir, true);
        acquired = file != null && file.lock("xn") &&
            prepare_owner(lock_dir, owner, ticks, file, created, owner_grace);
    }
    catch (e) { acquired = false; }
    if (acquired)
        leases[lock_dir] = { file, ticks: "" + ticks };
    else if (file != null)
        close_file(file);
    return acquired;
}

function acquire_wait(lock_dir, owner, timeout, owner_grace) {
    let start = common.now_seconds();
    while (!acquire(lock_dir, owner, owner_grace)) {
        if (common.now_seconds() - start >= (timeout ?? 300))
            return false;
        sleep(2000);
    }
    return true;
}

// The update launcher reserves fd 9 so package children retain the lease after a worker crash.
function adopt(lock_dir, owner) {
    let ticks = process.start_ticks(owner);
    let directory = fs.lstat(lock_dir);
    let node = fs.lstat(lock_dir + "/.kernel");
    let inherited = fs.stat("/proc/self/fd/9");
    if (leases[lock_dir] != null || owner != common.own_pid() || ticks == null ||
        directory?.type != "directory" || directory.uid != fs.stat("/proc/self").uid ||
        (directory.mode & 0022) != 0 || !safe_anchor(node, directory.uid) ||
        !same_node(node, inherited))
        return false;
    let file = fs.fdopen(9, "r");
    if (file == null)
        return false;
    let acquired = false;
    try {
        acquired = file.lock("xn") && protocol(file)?.complete === true &&
            same_node(node, fs.lstat(lock_dir + "/.kernel")) &&
            same_node(directory, fs.lstat(lock_dir)) &&
            prepare_owner(lock_dir, owner, ticks, file, false, 0);
    }
    catch (e) { acquired = false; }
    if (acquired)
        leases[lock_dir] = { file, ticks: "" + ticks };
    else
        close_file(file);
    return acquired;
}

function mark_request(path, reason) {
    return path != "" && common.write_file_atomic(path, "reason=" + reason + "\nupdated_at=" + common.now_seconds() + "\n");
}

function consume_request(path) {
    if (path == "" || fs.stat(path) == null)
        return false;
    fs.unlink(path);
    return true;
}

// Detached, so the reload that finished does not wait for the one it queued.
function run_pending_reload_if_requested(path, init_script) {
    if (!consume_request(path))
        return;
    exec.background([ init_script, "reload", "pending" ]);
}

return { held, acquire, acquire_wait, adopt, release, mark_request, consume_request, unmarked, run_pending_reload_if_requested };
