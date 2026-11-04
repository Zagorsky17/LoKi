// Directory locks that serialize lifecycle actions, and marker files carrying a request (a
// queued reload, a failed start to retry) from one process to the next.

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");

const DEFAULT_OWNER_GRACE = 30;

function owner_of(lock_dir) {
    return common.read_first_line(lock_dir + "/pid");
}

// Creating the directory and writing the owner are two steps, so an ownerless lock counts as
// held for a grace period.
function held(lock_dir, owner_grace) {
    let stat = lock_dir == "" ? null : fs.stat(lock_dir);
    if (stat == null)
        return false;

    let owner = owner_of(lock_dir);
    if (common.pid_alive(owner))
        return true;
    if (owner != "")
        return false;

    let age = common.now_seconds() - stat.mtime;
    return age >= 0 && age < (owner_grace ?? DEFAULT_OWNER_GRACE);
}

function remove(lock_dir) {
    fs.unlink(lock_dir + "/pid");
    return fs.rmdir(lock_dir);
}

function release(lock_dir, owner) {
    if (lock_dir != "" && owner != "" && owner_of(lock_dir) == owner)
        remove(lock_dir);
}

function acquire(lock_dir, owner, owner_grace) {
    if (lock_dir == "" || owner == "" || !common.ensure_dir(common.parent_dir(lock_dir)))
        return false;

    if (!fs.mkdir(lock_dir, 0755)) {
        if (held(lock_dir, owner_grace) || !remove(lock_dir) || !fs.mkdir(lock_dir, 0755))
            return false;
    }

    if (common.write_file(lock_dir + "/pid", owner + "\n"))
        return true;
    remove(lock_dir);
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

// Detached, so the reload that finished does not wait for the one it queued.
function run_pending_reload_if_requested(path, init_script) {
    if (!consume_request(path))
        return;
    exec.background([ init_script, "reload", "pending" ]);
}

return { held, acquire, acquire_wait, release, mark_request, consume_request, run_pending_reload_if_requested };
