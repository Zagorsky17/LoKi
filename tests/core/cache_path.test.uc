let t = require("t");
let stub = require("stub");
let fs = require("fs");
let cache = require("core.cache_path");

function path_settings(path) {
    return { cache_path: path };
}

t.test("validation is read-only and private creation remains idempotent", () => {
    let dir = stub.tmpdir();
    let path = dir + "/new/private/cache.db";
    t.eq(cache.validate(path_settings(path)), path);
    t.eq(fs.lstat(dir + "/new"), null);
    t.eq(cache.ensure(path_settings(path)), path);
    t.eq(fs.stat(dir + "/new").mode & 0777, 0700);
    t.eq(fs.stat(dir + "/new/private").mode & 0777, 0700);
    t.eq(fs.lstat(path), null, "the application does not create or initialize a DB");
    t.eq(cache.ensure(path_settings(path)), path);
    fs.writefile(path, "synthetic owned DB candidate");
    fs.chmod(path, 0644);
    t.eq(cache.validate(path_settings(path)), path, "an owned regular file passes the read-only path gate");
    t.eq(cache.ensure(path_settings(path)), path);
    t.eq(fs.stat(path).mode & 0777, 0644, "only the core can tighten a verified marked DB");
    t.eq(fs.readfile(path), "synthetic owned DB candidate");
    t.eq(cache.effective_path({}), "/tmp/loki/cache.db");
});

t.test("noncanonical and linked paths fail without modifying an unrelated target", () => {
    let dir = stub.tmpdir();
    fs.mkdir(dir + "/private", 0700);
    fs.mkdir(dir + "/public", 0755);
    fs.writefile(dir + "/private/keep", "synthetic-secret");
    fs.symlink(dir + "/private", dir + "/linked");
    fs.symlink(dir + "/private/keep", dir + "/private/cache.db");
    for (let path in [ "relative/cache.db", dir + "/../escape/cache.db", dir + "//empty/cache.db", dir + "/private/", dir + "/public/cache.db", dir + "/linked/other.db", dir + "/private/cache.db", dir + "/private/line\ncache.db", dir + "/private/zero\u0000cache.db", dir + "/private/tab\tcache.db", dir + "/private/carriage\rcache.db", dir + "/private/delete\x7fcache.db" ]) {
        let failure = t.throws(() => cache.validate(path_settings(path)));
        t.ok(index(failure.message, dir) < 0, "a refusal masks its path");
    }
    t.eq(fs.readfile(dir + "/private/keep"), "synthetic-secret");
    t.eq(fs.stat(dir + "/public").mode & 0777, 0755);
});

t.test("foreign, multiply linked and writable-parent metadata is refused without chmod", () => {
    let dir = stub.tmpdir();
    fs.mkdir(dir + "/private", 0700);
    let path = dir + "/private/cache.db";
    fs.writefile(path, "untouched");
    let real = fs.lstat;
    let uid = real(path).uid;
    for (let replacement in [ { uid: uid + 1 }, { nlink: 2 }, { type: "link" } ]) {
        fs.lstat = (name) => name == path ? { ...real(name), ...replacement } : real(name);
        t.throws(() => cache.validate(path_settings(path)));
        fs.lstat = real;
    }
    fs.chmod(dir + "/private", 0777);
    t.throws(() => cache.validate(path_settings(path)));
    t.eq(fs.stat(dir + "/private").mode & 0777, 0777);
    t.eq(fs.readfile(path), "untouched");
});

t.test("metadata and creation errors fail closed without changing existing parents", () => {
    let dir = stub.tmpdir();
    fs.mkdir(dir + "/private", 0700);
    fs.writefile(dir + "/private/keep", "keep");
    let original_stat = fs.lstat;
    let original_mkdir = fs.mkdir;
    fs.lstat = (name) => name == dir + "/private" ? null : original_stat(name);
    // Simulate EACCES/EIO rather than infer ENOENT from lstat's null result.
    fs.mkdir = () => false;
    t.throws(() => cache.validate(path_settings(dir + "/private/cache.db")));
    t.throws(() => cache.ensure(path_settings(dir + "/private/cache.db")));
    fs.lstat = original_stat;
    fs.mkdir = original_mkdir;
    t.eq(fs.readfile(dir + "/private/keep"), "keep");
    t.eq(fs.stat(dir + "/private").mode & 0777, 0700);
    t.eq(fs.stat(dir + "/private/cache.db"), null);
    fs.mkdir = () => false;
    t.throws(() => cache.ensure(path_settings(dir + "/new/cache.db")));
    fs.mkdir = original_mkdir;
    t.eq(fs.lstat(dir + "/new"), null);
});

t.test("process owner inspection closes on read failure and refuses uncertain close", () => {
    let dir = stub.tmpdir();
    let original = fs.open;
    for (let mode in [ "read-throw", "close-false", "close-throw" ]) {
        let closes = 0;
        fs.open = (name, flags) => {
            let file = original(name, flags);
            if (name != "/proc/self/status" || file == null) return file;
            return {
                read: (size) => { if (mode == "read-throw") die("synthetic-private-value"); return file.read(size); },
                close: () => {
                    closes++;
                    let result = file.close();
                    if (mode == "close-false") return false;
                    if (mode == "close-throw") die("synthetic-private-value");
                    return result;
                }
            };
        };
        let failure;
        try {
            let refusal = t.throws(() => cache.ensure(path_settings(dir + "/new/cache.db")));
            t.eq(closes, 1, mode);
            t.eq(index(refusal.message, "synthetic-private-value"), -1);
            t.eq(fs.lstat(dir + "/new"), null);
        }
        catch (e) { failure = e; }
        fs.open = original;
        if (failure != null) die(failure.message);
    }
});

t.done();
