let t = require("t");
let stub = require("stub");
let fs = require("fs");
let common = require("core.common");
let lock = require("service.lock");
let request = require("service.start_request");

function fresh() {
    let root = stub.tmpdir();
    request.paths.pending = root + "/runtime/start.retry";
    request.paths.lock = root + "/runtime/request.lock";
    request.paths.autostart = root + "/S99forkop";
    return root;
}

t.test("an empty runtime creates a unique intent and leaves no held lock", () => {
    fresh();
    let first = request.begin();
    t.matches(first, /^[1-9][0-9]*-[0-9]+-[1-9][0-9]*$/);
    t.eq(request.token(), first);
    t.eq(lock.held(request.paths.lock), false);
    let second = request.begin();
    t.ok(second != first);
    t.eq(request.current(first), false);
    t.eq(request.current(second), true);
    t.ok(request.cancel());
    t.eq(request.token(), "");
    t.ok(request.cancel(), "repeated stop is successful");
});

t.test("old completion cannot consume a newer request or a reused cancelled generation", () => {
    fresh();
    let first = request.begin();
    t.ok(request.cancel(first));
    let second = request.begin();
    t.ok(request.cancel(first));
    t.eq(request.token(), second);
    t.ok(!request.current(first));
    t.ok(request.cancel(second));
});

t.test("request changes hold only the short request lock", () => {
    fresh();
    let write = common.write_file_atomic;
    let locked = false;
    common.write_file_atomic = (path, value) => {
        locked = lock.held(request.paths.lock);
        return write(path, value);
    };
    let token = request.begin();
    common.write_file_atomic = write;
    t.ok(locked);
    t.ok(token != "");
    let unlink = fs.unlink;
    locked = false;
    fs.unlink = (path) => {
        if (path == request.paths.pending)
            locked = lock.held(request.paths.lock);
        return unlink(path);
    };
    let cancelled = request.cancel(token);
    fs.unlink = unlink;
    t.ok(cancelled && locked);
    t.eq(lock.held(request.paths.lock), false);
});

t.test("failed persistence and cancellation do not claim success or leave a held lock", () => {
    fresh();
    let write = common.write_file_atomic;
    common.write_file_atomic = () => false;
    let refused = request.begin();
    common.write_file_atomic = write;
    t.eq(refused, "");
    t.eq(lock.held(request.paths.lock), false);
    common.write_file_atomic = () => die("synthetic storage failure");
    refused = request.begin();
    common.write_file_atomic = write;
    t.eq(refused, "");
    t.eq(lock.held(request.paths.lock), false);
    let token = request.begin();
    let unlink = fs.unlink;
    fs.unlink = (path) => path == request.paths.pending ? false : unlink(path);
    let cancelled = request.cancel();
    fs.unlink = unlink;
    t.eq(cancelled, false);
    t.eq(request.token(), token);
    t.eq(lock.held(request.paths.lock), false);
});

t.test("request lock failure prevents writes and cancellation", () => {
    fresh();
    let token = request.begin();
    let acquire = lock.acquire_wait;
    lock.acquire_wait = () => false;
    let refused = request.begin();
    let cancelled = request.cancel();
    lock.acquire_wait = acquire;
    t.eq(refused, "");
    t.eq(cancelled, false);
    t.eq(request.token(), token);
});

t.test("invalid and linked markers are not executable retry generations", () => {
    let root = fresh();
    common.ensure_dir(root + "/runtime");
    for (let value in [ "", "reason=start_failed\n", "1-2-3", "1-2-3\nextra", "$(touch /tmp/no)\n", "0-2-3\n" ]) {
        fs.writefile(request.paths.pending, value);
        t.eq(request.token(), "");
    }
    fs.unlink(request.paths.pending);
    fs.writefile(root + "/other", "1-2-3\n");
    fs.symlink(root + "/other", request.paths.pending);
    t.eq(request.token(), "");
    t.eq(request.cancel(), false);
    t.eq(fs.readfile(root + "/other"), "1-2-3\n");
});

t.test("autostart accepts only the exact own symlink", () => {
    fresh();
    t.eq(request.enabled(), false);
    fs.writefile(request.paths.autostart, "../init.d/forkop");
    t.eq(request.enabled(), false);
    fs.unlink(request.paths.autostart);
    fs.symlink("../init.d/other", request.paths.autostart);
    t.eq(request.enabled(), false);
    fs.unlink(request.paths.autostart);
    fs.symlink("../init.d/forkop", request.paths.autostart);
    t.eq(request.enabled(), true);
});

t.done();
