let t = require("t");
let stub = require("stub");
let fs = require("fs");
let common = require("core.common");

t.test("atomic own-state writes create private files and preserve exact bytes", () => {
    let dir = stub.tmpdir();
    let path = dir + "/state";
    t.ok(common.write_file_atomic(path, "synthetic-secret\n"));
    t.eq(fs.stat(path).mode & 0777, 0600, "secrets cannot depend on the caller's umask");
    t.eq(fs.readfile(path), "synthetic-secret\n");
    t.ok(common.write_file_atomic(path, "replacement\n"));
    t.eq(fs.stat(path).mode & 0777, 0600);
    t.eq(fs.readfile(path), "replacement\n");
    t.eq(fs.lsdir(dir), [ "state" ]);
});

function collision_test(kind) {
    t.test("atomic temporary-name collisions preserve a foreign " + kind, () => {
        let dir = stub.tmpdir();
        let path = dir + "/state";
        let temporary = path + ".3456789.987654.tmp";
        fs.writefile(path, "previous-state\n");
        fs.writefile(dir + "/victim", "foreign-data\n");
        if (kind == "link")
            fs.symlink(dir + "/victim", temporary);
        else if (kind == "file")
            fs.writefile(temporary, "foreign-data\n");
        else
            fs.mkdir(temporary);
        let real_clock = global.clock;
        global.clock = () => [ 3456789, 987654 ];
        let result = common.write_file_atomic(path, "synthetic-secret\n");
        global.clock = real_clock;
        t.eq(fs.readfile(dir + "/victim"), "foreign-data\n");
        t.eq(result, false, kind + " must refuse exclusive creation");
        t.eq(fs.readfile(path), "previous-state\n");
        t.eq(fs.lstat(temporary)?.type, kind, "a refused collision is not ours to unlink");
        if (kind != "directory")
            t.eq(fs.readfile(temporary), "foreign-data\n");
    });
}

for (let kind in [ "file", "link", "directory" ])
    collision_test(kind);

t.test("private writes remove partial or unverifiable output", () => {
    for (let failure in [ "short-write", "readback", "readback-throw" ]) {
        let path = stub.tmpdir() + "/secret";
        let open = fs.open;
        let read = fs.readfile;
        if (failure == "short-write")
            fs.open = (name, flags, permissions) => {
                let file = open(name, flags, permissions);
                return { write: (value) => file.write(substr(value, 0, 1)), close: () => file.close() };
            };
        else
            fs.readfile = (name) => {
                if (name != path) return read(name);
                if (failure == "readback-throw") die("synthetic-private-readback");
                return null;
            };
        let result = common.write_private_file(path, "synthetic-secret\n");
        fs.open = open;
        fs.readfile = read;
        t.eq(result, false, failure);
        t.eq(fs.lstat(path), null, failure + " must remove the file it created");
    }
});

function failed_private_write(failure) {
    let dir = stub.tmpdir();
    let path = dir + "/secret";
    let open = fs.open;
    let active;
    let closed = 0;
    let result;
    let exception = null;
    fs.open = (name, flags, permissions) => {
        active = open(name, flags, permissions);
        return { write: (value) => { if (failure == "write") die("synthetic-private-write"); return active.write(value); },
            close: () => { closed++; active.close(); active = null;
                if (failure == "close") die("synthetic-private-close"); return false; } };
    };
    try { result = common.write_private_file(path, "synthetic-secret\n"); }
    catch (e) { exception = e.message; }
    fs.open = open;
    if (active != null) active.close();
    t.eq(exception, null);
    t.eq(result, false);
    t.eq(closed, 1);
    t.eq(fs.lstat(path), null);
    t.ok(common.write_private_file(path, "repeated\n"));
    t.eq(fs.stat(path).mode & 0777, 0600);
    t.eq(fs.readfile(path), "repeated\n");
}

t.test("a false close refuses a private write even when readback matches", () => failed_private_write("false"));
t.test("a close exception refuses and removes a private write", () => failed_private_write("close"));
t.test("a write exception still closes and removes its private file", () => failed_private_write("write"));

t.test("an uncertain close cannot replace a previous atomic state", () => {
    let dir = stub.tmpdir();
    let path = dir + "/state";
    fs.writefile(path, "previous\n");
    let open = fs.open;
    fs.open = (name, flags, permissions) => {
        let file = open(name, flags, permissions);
        return { write: (value) => file.write(value), close: () => { file.close(); return false; } };
    };
    let result = common.write_file_atomic(path, "synthetic-secret\n");
    fs.open = open;
    t.eq(result, false);
    t.eq(fs.readfile(path), "previous\n");
    t.eq(fs.lsdir(dir), [ "state" ]);
    t.ok(common.write_file_atomic(path, "repeated\n"));
    t.eq(fs.readfile(path), "repeated\n");
});

t.test("a failed atomic rename preserves the previous state and removes only its own temporary", () => {
    let dir = stub.tmpdir();
    let path = dir + "/state";
    fs.writefile(path, "previous-state\n");
    let rename = fs.rename;
    fs.rename = () => false;
    let result = common.write_file_atomic(path, "synthetic-secret\n");
    fs.rename = rename;
    t.eq(result, false);
    t.eq(fs.readfile(path), "previous-state\n");
    t.eq(fs.lsdir(dir), [ "state" ]);
});

t.test("the shared-file writer keeps existing permissions and ordinary overwrites", () => {
    let path = stub.tmpdir() + "/shared";
    fs.writefile(path, "previous\n");
    fs.chmod(path, 0644);
    t.ok(common.write_file(path, "replacement\n"));
    t.eq(fs.stat(path).mode & 0777, 0644, "shared rt_tables must not inherit the private writer");
    t.eq(fs.readfile(path), "replacement\n");
});

t.done();
