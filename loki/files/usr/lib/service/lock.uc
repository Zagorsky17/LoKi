// Directory locks that serialize lifecycle actions, and marker files carrying a request (a
// queued reload, a failed start to retry) from one process to the next.

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let process = require("core.process");

const DEFAULT_OWNER_GRACE = 30;

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
        return missing != null && failure == missing ? { pid: "" } : null;
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
        return { pid: "" };

    let fields = split(body, "\n");
    if (fields[-1] == "") pop(fields);
    if (length(fields) < 1 || length(fields) > 2 || match(fields[0], /^[1-9][0-9]{0,9}$/) == null ||
        (length(fields) == 2 && (match(fields[1], /^[0-9]{1,19}$/) == null ||
            int(fields[1]) < 0 || "" + int(fields[1]) != fields[1])))
        return null;
    return { pid: fields[0], ticks: length(fields) == 2 ? fields[1] : null };
}

// Creating the directory and writing the owner are two steps, so an ownerless lock counts as
// held for a grace period.
function held(lock_dir, owner_grace) {
    let stat = lock_dir == "" ? null : fs.lstat(lock_dir);
    if (stat == null)
        return false;

    let owner = owner_of(lock_dir);
    if (owner == null)
        return true;
    if (common.pid_alive(owner.pid)) {
        let ticks = owner.ticks == null ? null : process.start_ticks(owner.pid);
        return ticks == null || "" + ticks == owner.ticks;
    }
    if (owner.pid != "")
        return false;

    let age = common.now_seconds() - stat.mtime;
    return age >= 0 && age < (owner_grace ?? DEFAULT_OWNER_GRACE);
}

function remove(lock_dir) {
    fs.unlink(lock_dir + "/pid");
    return fs.rmdir(lock_dir);
}

function release(lock_dir, owner) {
    let recorded = lock_dir == "" ? null : owner_of(lock_dir);
    if (owner != "" && recorded != null && recorded.pid == owner && owner == common.own_pid() &&
        (recorded.ticks == null || recorded.ticks == "" + process.start_ticks(owner)))
        remove(lock_dir);
}

function acquire(lock_dir, owner, owner_grace) {
    let ticks = process.start_ticks(owner);
    if (lock_dir == "" || owner != common.own_pid() || ticks == null ||
        !common.ensure_dir(common.parent_dir(lock_dir)))
        return false;

    if (!fs.mkdir(lock_dir, 0755)) {
        if (held(lock_dir, owner_grace) || !remove(lock_dir) || !fs.mkdir(lock_dir, 0755))
            return false;
    }

    let path = lock_dir + "/pid";
    let file = fs.open(path, "wxe", 0600);
    if (file == null) {
        fs.rmdir(lock_dir);
        return false;
    }
    let node = fs.stat("/proc/self/fd/" + file.fileno());
    let body = owner + "\n" + ticks + "\n";
    let written = file.write(body) == length(body);
    let closed = file.close();
    if (written && closed === true)
        return true;
    let current = fs.lstat(path);
    if (node != null && current != null && node.inode == current.inode &&
        node.dev.major == current.dev.major && node.dev.minor == current.dev.minor)
        fs.unlink(path);
    fs.rmdir(lock_dir);
    return false;
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

function mark_request(path, reason) {
    return path != "" && common.write_file_atomic(path, "reason=" + reason + "\nupdated_at=" + common.now_seconds() + "\n");
}

function consume_request(path) {
    if (path == "" || fs.stat(path) == null)
        return false;
    fs.unlink(path);
    return true;
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

// Detached, so the reload that finished does not wait for the one it queued.
function run_pending_reload_if_requested(path, init_script) {
    if (!consume_request(path))
        return;
    exec.background([ init_script, "reload", "pending" ]);
}

return { held, acquire, acquire_wait, release, mark_request, consume_request, unmarked, run_pending_reload_if_requested };
