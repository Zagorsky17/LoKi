let t = require("t");
let fs = require("fs");
let stub = require("stub");
let files = require("service.preflight_files");

function fixture() {
    let root = stub.tmpdir();
    fs.chmod(root, 0755);
    fs.mkdir(root + "/parent", 0755);
    fs.chmod(root + "/parent", 0755);
    return root;
}

function inspect(root, target, expected) {
    let targets = {};
    targets[target || "/parent/file"] = expected || "file";
    return files.collect(root, targets)[0];
}

function failed_scan(thrown, read_failure) {
    let root = fixture();
    let opendir = fs.opendir;
    let active;
    let closed = 0;
    let result;
    let exception = null;
    fs.opendir = (path) => {
        active = opendir(path);
        return { read: () => { if (read_failure) die("synthetic-private-read"); return active.read(); },
            close: () => { closed++; active.close(); active = null;
                if (thrown) die("synthetic-private-close"); return read_failure ? true : false; } };
    };
    try { result = inspect(root); }
    catch (e) { exception = e.message; }
    fs.opendir = opendir;
    if (active != null) active.close();
    t.eq(exception, null);
    t.eq(closed, 1);
    t.eq(result.state, "incomplete");
    t.eq(result.reason, "candidate-directory-read-failed");
    t.excludes(sprintf("%J", result), "synthetic-private");
    t.eq(inspect(root).reason, "candidate-path-absent");
}

t.test("a directory close returning false cannot prove absence", () => failed_scan(false, false));
t.test("a directory close exception is private and cannot prove absence", () => failed_scan(true, false));
t.test("a directory read exception still closes the handle and refuses absence", () => failed_scan(false, true));

t.test("existing shared directories and root are checked without opening file contents", () => {
    let root = fixture();
    let open = fs.open;
    fs.open = () => die("file contents must not be opened");
    let directory = inspect(root, "/parent", "directory");
    let base = inspect(root, "/", "directory");
    fs.open = open;
    t.eq(directory.state, "checked");
    t.eq(base.state, "checked");
    t.eq(directory.reason, "candidate-directory-safe");
});

t.test("parent files and special leaf nodes are conflicts without opening or blocking", () => {
    let root = fixture();
    fs.writefile(root + "/parent/file", "keep");
    fs.chmod(root + "/parent/file", 0644);
    t.eq(inspect(root, "/parent/file/child").reason, "candidate-parent-type-conflict");
    t.eq(inspect(root, "/parent/file", "directory").state, "conflict");
    t.eq(stub.real.system("mkfifo '" + root + "/parent/fifo'"), 0);
    let open = fs.open;
    fs.open = () => die("special nodes must not be opened");
    let result = inspect(root, "/parent/fifo");
    fs.open = open;
    t.eq(result.reason, "candidate-target-type-conflict");
    t.eq(result.state, "conflict");
});

t.test("hardlinks and writable file metadata remain incomplete and are preserved", () => {
    let root = fixture();
    let path = root + "/parent/file";
    fs.writefile(path, "keep");
    fs.chmod(path, 0666);
    t.eq(inspect(root).reason, "candidate-target-unsafe");
    fs.chmod(path, 0644);
    t.eq(stub.real.system("ln '" + path + "' '" + root + "/other'"), 0);
    t.eq(inspect(root).reason, "candidate-target-unsafe");
    t.eq(fs.readfile(path), "keep");
});

t.test("unsafe root and foreign owner metadata refuse before scanning children", () => {
    let root = fixture();
    fs.chmod(root, 0777);
    t.eq(inspect(root).reason, "candidate-root-unsafe");
    fs.chmod(root, 0755);
    let lstat = fs.lstat;
    fs.lstat = (path) => {
        let info = lstat(path);
        if (path == root + "/parent") info.uid++;
        return info;
    };
    let result = inspect(root);
    fs.lstat = lstat;
    t.eq(result.reason, "candidate-parent-unsafe");
});

t.test("failed or incomplete directory reads cannot prove absence", () => {
    let root = fixture();
    let opendir = fs.opendir;
    let error = fs.error;
    let closed = 0;
    fs.opendir = () => null;
    let unavailable = inspect(root);
    fs.opendir = () => ({ read: () => null, close: () => { closed++; return true; } });
    fs.error = () => "synthetic-private-io-error";
    let failed = inspect(root);
    fs.opendir = opendir;
    fs.error = error;
    t.eq(unavailable.reason, "candidate-directory-read-failed");
    t.eq(failed.reason, "candidate-directory-read-failed");
    t.eq(closed, 1);
    t.excludes(sprintf("%J", failed), "synthetic-private-io-error");
});

t.test("a listed but unstatable entry cannot become missing", () => {
    let root = fixture();
    let opendir = fs.opendir;
    let closed = 0;
    fs.opendir = () => ({ read: () => "file", close: () => { closed++; return true; } });
    let result = inspect(root);
    fs.opendir = opendir;
    t.eq(result.reason, "candidate-path-stat-unavailable");
    t.eq(closed, 1);
});

t.test("the directory entry budget is aggregate and closes its handles", () => {
    let root = fixture();
    let opendir = fs.opendir;
    let entries = 0;
    let closed = 0;
    fs.opendir = () => ({ read: () => { entries++; return "unrelated-private-name"; }, close: () => { closed++; return true; } });
    let result = files.collect(root, { "/parent/first": "file", "/parent/second": "file" });
    fs.opendir = opendir;
    t.eq(entries, 16384);
    t.eq(closed, 2);
    t.eq(result[0].reason, "candidate-directory-entry-limit");
    t.eq(result[1].reason, "candidate-directory-entry-limit");
    t.excludes(sprintf("%J", result), "unrelated-private-name");
});

t.test("parent identity changes invalidate even a completed EOF scan", () => {
    let root = fixture();
    let opendir = fs.opendir;
    let changed = false;
    let lstat = fs.lstat;
    fs.opendir = () => ({ read: () => null, close: () => { changed = true; return true; } });
    fs.lstat = (path) => {
        let info = lstat(path);
        if (changed && path == root + "/parent") info.inode++;
        return info;
    };
    let result = inspect(root);
    fs.opendir = opendir;
    fs.lstat = lstat;
    t.eq(result.reason, "candidate-parent-changed");
});

t.test("leaf substitution cannot be reported as a stable existing file", () => {
    let root = fixture();
    let path = root + "/parent/file";
    fs.writefile(path, "keep");
    fs.chmod(path, 0644);
    let lstat = fs.lstat;
    let reads = 0;
    fs.lstat = (name) => {
        let info = lstat(name);
        if (name == path && ++reads > 1) info.inode++;
        return info;
    };
    let result = inspect(root);
    fs.lstat = lstat;
    t.eq(result.reason, "candidate-target-changed");
    t.eq(fs.readfile(path), "keep");
});

t.done();
