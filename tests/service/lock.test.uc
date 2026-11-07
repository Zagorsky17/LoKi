let t = require("t");
let stub = require("stub");
let fs = require("fs");
let common = require("core.common");
let lock = require("service.lock");

let me = common.own_pid();
const DEAD = "999999";

t.test("a lock is taken once, held while its owner lives, and released only by its owner", () => {
    let dir = stub.tmpdir() + "/runtime.lock";
    t.ok(lock.acquire(dir, me));
    t.eq(common.read_first_line(dir + "/pid"), me);
    t.ok(lock.held(dir), "a lock owned by a live pid is held");
    t.ok(!lock.acquire(dir, me), "a held lock is refused");
    t.ok(!lock.acquire_wait(dir, me, 0), "a wait for a live holder times out");

    lock.release(dir, DEAD);
    t.ok(fs.stat(dir) != null, "another pid cannot release it");
    lock.release(dir, me);
    t.ok(fs.stat(dir) == null);
    t.ok(!lock.held(dir));
});

t.test("a lock left by a dead owner is stale and taken over", () => {
    let dir = stub.tmpdir() + "/runtime.lock";
    fs.mkdir(dir);
    fs.writefile(dir + "/pid", DEAD + "\n");
    t.ok(!lock.held(dir));
    t.ok(lock.acquire(dir, me));
    t.eq(common.read_first_line(dir + "/pid"), me);
});

t.test("a lock without an owner yet is held for its grace period", () => {
    let dir = stub.tmpdir() + "/runtime.lock";
    fs.mkdir(dir);
    t.ok(lock.held(dir), "a lock just created");
    t.ok(!lock.held(dir, 0), "a lock older than its grace");
    fs.writefile(dir + "/pid", "");
    t.ok(lock.held(dir), "an owner file opened before its first write");
    t.ok(!lock.held(dir, 0));
    t.ok(lock.acquire(dir, me, 0));
    lock.release(dir, me);
});

t.test("a cold start creates the directory its lock lives in", () => {
    let dir = stub.tmpdir() + "/missing/start.lock";
    t.ok(lock.acquire(dir, me));
    lock.release(dir, me);
    t.ok(fs.stat(dir) == null);
});

t.test("a request marker is written with its reason and consumed once", () => {
    let path = stub.tmpdir() + "/reload.pending";
    t.ok(lock.mark_request(path, "reload_busy"));
    let text = fs.readfile(path);
    t.matches(text, /^reason=reload_busy\nupdated_at=[0-9]+\n$/);
    t.ok(lock.consume_request(path));
    t.ok(fs.stat(path) == null);
    t.ok(!lock.consume_request(path));
});

t.test("a pending reload runs the init script's reload in the background, once", () => {
    let path = stub.tmpdir() + "/reload.pending";
    lock.mark_request(path, "reload_busy");
    stub.commands([ [ "logger", {} ], [ /'\/etc\/init.d\/loki' 'reload' 'pending'.*&$/, {} ] ]);
    lock.run_pending_reload_if_requested(path, "/etc/init.d/loki");
    lock.run_pending_reload_if_requested(path, "/etc/init.d/loki");
    t.eq(stub.command_lines(), [ "/etc/init.d/loki reload pending" ], "the reload it starts says what it applies");
    stub.restore();
});

t.test("a reused live PID does not retain the previous process generation's lock", () => {
    let ticks = require("service.health").start_ticks(me);
    t.ok(ticks != null && ticks > 0, "the real owner has readable start ticks");
    let dir = stub.tmpdir() + "/reused.lock";
    fs.mkdir(dir);
    fs.writefile(dir + "/pid", me + "\n" + (ticks - 1) + "\n");
    t.ok(!lock.held(dir), "the live PID belongs to another process generation");
    t.ok(lock.acquire(dir, me), "the current generation can reclaim the stale lock");
    lock.release(dir, me);
    t.eq(fs.stat(dir), null);
});

t.test("release verifies the recorded process birth as well as its PID", () => {
    let ticks = require("service.health").start_ticks(me);
    t.ok(ticks != null && ticks > 0);
    let dir = stub.tmpdir() + "/foreign-generation.lock";
    fs.mkdir(dir);
    let body = me + "\n" + (ticks - 1) + "\n";
    fs.writefile(dir + "/pid", body);
    lock.release(dir, me);
    t.eq(fs.readfile(dir + "/pid"), body, "a PID alone cannot release another generation");
});

t.test("new locks retain the real process birth in the owner record", () => {
    let ticks = require("service.health").start_ticks(me);
    t.ok(ticks != null && ticks > 0);
    let dir = stub.tmpdir() + "/identity.lock";
    t.ok(lock.acquire(dir, me));
    t.eq(fs.readfile(dir + "/pid"), me + "\n" + ticks + "\n");
    t.ok(lock.held(dir));
    t.ok(!lock.acquire(dir, me), "identity does not make a lock reentrant");
    lock.release(dir, me);
    t.eq(fs.stat(dir), null);
});

t.test("acquisition cannot forge another process's ownership", () => {
    let dir = stub.tmpdir() + "/forged.lock";
    for (let owner in [ "", DEAD, "1", me + "\x00ignored", "../self" ])
        t.ok(!lock.acquire(dir, owner));
    t.eq(fs.stat(dir), null);
});

t.test("live legacy PID-only ownership stays held until its owner exits", () => {
    let dir = stub.tmpdir() + "/legacy.lock";
    fs.mkdir(dir);
    fs.writefile(dir + "/pid", me + "\n");
    t.ok(lock.held(dir));
    t.ok(!lock.acquire(dir, me));
    t.eq(fs.readfile(dir + "/pid"), me + "\n");
});

t.test("corrupt or oversized owner records are refused without removing them", () => {
    for (let body in [ "bad\n", me + "\n\n", me + "\n-1\n", me + "\n01\n",
        me + "\n9223372036854775808\n", me + "\n1\nextra\n", me + "\x00ignored\n",
        me + "\n" + sprintf("%0130d", 1) + "\n" ]) {
        let dir = stub.tmpdir() + "/corrupt.lock";
        fs.mkdir(dir);
        fs.writefile(dir + "/pid", body);
        t.ok(lock.held(dir, 0));
        t.ok(!lock.acquire(dir, me, 0));
        lock.release(dir, me);
        t.eq(fs.readfile(dir + "/pid"), body);
    }
});

t.test("unsafe owner nodes and lock directory links are left untouched", () => {
    let root = stub.tmpdir();
    let victim = root + "/victim";
    fs.writefile(victim, DEAD + "\n");
    for (let kind in [ "symlink", "hardlink", "writable-file", "writable-directory" ]) {
        let dir = root + "/" + kind;
        fs.mkdir(dir);
        if (kind == "symlink") fs.symlink(victim, dir + "/pid");
        else if (kind == "hardlink") t.eq(require("core.exec").run([ "ln", victim, dir + "/pid" ]), 0);
        else fs.writefile(dir + "/pid", DEAD + "\n");
        if (kind == "writable-file") fs.chmod(dir + "/pid", 0666);
        if (kind == "writable-directory") fs.chmod(dir, 0777);
        t.ok(lock.held(dir, 0));
        t.ok(!lock.acquire(dir, me, 0));
        lock.release(dir, me);
        t.ok(fs.lstat(dir + "/pid") != null);
    }
    fs.symlink(root + "/symlink", root + "/alias");
    t.ok(lock.held(root + "/alias", 0));
    t.ok(!lock.acquire(root + "/alias", me, 0));
    t.eq(fs.readfile(victim), DEAD + "\n");
});

t.test("an unreadable process birth preserves a live holder and refuses a new lock", () => {
    let process = require("core.process");
    let dir = stub.tmpdir() + "/unreadable.lock";
    t.ok(lock.acquire(dir, me));
    let original = process.start_ticks;
    process.start_ticks = () => null;
    let held = lock.held(dir);
    lock.release(dir, me);
    let exists = fs.stat(dir) != null;
    let acquired = lock.acquire(stub.tmpdir() + "/new.lock", me);
    process.start_ticks = original;
    t.ok(held);
    t.ok(exists);
    t.ok(!acquired);
    lock.release(dir, me);
});

t.test("a directory or owner record belonging to another user is preserved", () => {
    for (let foreign in [ "directory", "record" ]) {
        let dir = stub.tmpdir() + "/foreign.lock";
        fs.mkdir(dir);
        fs.writefile(dir + "/pid", DEAD + "\n");
        let original = fs.lstat;
        fs.lstat = (path) => {
            let node = original(path);
            if (path == (foreign == "directory" ? dir : dir + "/pid")) node.uid++;
            return node;
        };
        let held = lock.held(dir, 0);
        let acquired = lock.acquire(dir, me, 0);
        lock.release(dir, me);
        fs.lstat = original;
        t.ok(held);
        t.ok(!acquired);
        t.eq(fs.readfile(dir + "/pid"), DEAD + "\n");
    }
});

t.test("read and close errors keep ownership uncertain and leave the record intact", () => {
    for (let failure in [ "open", "read", "close" ]) {
        let dir = stub.tmpdir() + "/io.lock";
        fs.mkdir(dir);
        let body = DEAD + "\n1\n";
        fs.writefile(dir + "/pid", body);
        let original = fs.open;
        let closes = 0;
        fs.open = (path, flags, mode) => {
            if (path != dir + "/pid") return original(path, flags, mode);
            if (failure == "open") return null;
            let file = original(path, flags, mode);
            return { read: (limit) => failure == "read" ? null : file.read(limit),
                error: () => failure == "read" ? "synthetic read error" : file.error(),
                close: () => { closes++; file.close(); return failure == "close" ? false : true; } };
        };
        let held = lock.held(dir, 0);
        let acquired = lock.acquire(dir, me, 0);
        lock.release(dir, me);
        fs.open = original;
        t.ok(held);
        t.ok(!acquired);
        t.eq(closes, failure == "open" ? 0 : 3);
        t.eq(fs.readfile(dir + "/pid"), body);
    }
});

t.test("failed owner writes and closes refuse acquisition and permit a clean retry", () => {
    for (let failure in [ "open", "write", "close" ]) {
        let dir = stub.tmpdir() + "/write.lock";
        let original = fs.open;
        let closes = 0;
        fs.open = (path, flags, mode) => {
            if (path != dir + "/pid" || flags != "wxe") return original(path, flags, mode);
            if (failure == "open") return null;
            let file = original(path, flags, mode);
            return { fileno: () => file.fileno(),
                write: (body) => file.write(failure == "write" ? substr(body, 0, 1) : body),
                close: () => { closes++; file.close(); return failure == "close" ? false : true; } };
        };
        let acquired = lock.acquire(dir, me);
        fs.open = original;
        t.ok(!acquired);
        t.eq(closes, failure == "open" ? 0 : 1);
        t.eq(fs.stat(dir), null);
        t.ok(lock.acquire(dir, me));
        t.eq(fs.stat(dir + "/pid").mode & 0777, 0600);
        lock.release(dir, me);
    }
});

t.test("failed creation and close cleanup preserve a replacement owner file", () => {
    for (let failure in [ "open", "close" ]) {
        let root = stub.tmpdir();
        let dir = root + "/collision.lock";
        let victim = root + "/victim";
        fs.writefile(victim, "keep\n");
        let original = fs.open;
        fs.open = (path, flags, mode) => {
            if (path != dir + "/pid" || flags != "wxe") return original(path, flags, mode);
            if (failure == "open") {
                fs.symlink(victim, path);
                return original(path, flags, mode);
            }
            let file = original(path, flags, mode);
            return { fileno: () => file.fileno(), write: (body) => file.write(body),
                close: () => { file.close(); fs.rename(victim, path); return false; } };
        };
        let acquired = lock.acquire(dir, me);
        fs.open = original;
        t.ok(!acquired);
        t.eq(fs.readfile(dir + "/pid"), "keep\n");
        if (failure == "open") t.eq(fs.readfile(victim), "keep\n");
    }
});

t.done();
