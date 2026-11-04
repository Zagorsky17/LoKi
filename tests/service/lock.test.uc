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

t.done();
