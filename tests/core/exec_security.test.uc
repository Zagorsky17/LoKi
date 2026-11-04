// Exercise the real shell and filesystem with synthetic data only.
let t = require("t");
let fs = require("fs");
let stub = require("stub");
let common = require("core.common");
let exec = require("core.exec");
let pid = common.own_pid();

function temporary(nonce) {
    global.clock = () => [ 123456, nonce ];
    return sprintf("/tmp/loki-exec.%d.123456.%d", pid, nonce);
}

function remove_paths(base) {
    for (let suffix in [ ".0", ".0.status", "/0", "/0.status", "/stderr" ])
        fs.unlink(base + suffix);
    fs.rmdir(base);
}

t.test("parallel capture protects existing symlink targets without reading or deleting them", () => {
    let base = temporary(1);
    let dir = stub.tmpdir();
    let victim = dir + "/victim";
    fs.writefile(victim, "preserved synthetic data");
    t.eq(exec.status([ "ln", "-s", victim, base + ".0" ]), 0);
    let result = exec.capture_parallel([ [ "printf", "changed" ] ]);
    let content = fs.readfile(victim);
    let preserved_link = fs.lstat(base + ".0")?.type == "link";
    remove_paths(base);
    t.eq(content, "preserved synthetic data");
    t.ok(preserved_link, "the unrelated legacy-path symlink was removed");
    t.eq(result, [ { status: 0, stdout: "changed" } ]);
});

t.test("feed protects an existing stderr symlink target", () => {
    let base = temporary(2);
    let dir = stub.tmpdir();
    let victim = dir + "/victim";
    let old_path = "/tmp/loki-exec.123456.2.err";
    fs.writefile(victim, "preserved synthetic data");
    t.eq(exec.status([ "ln", "-s", victim, old_path ]), 0);
    let result = exec.feed([ "sh", "-c", "cat >/dev/null; printf changed >&2; exit 7" ], "synthetic input");
    let content = fs.readfile(victim);
    let preserved_link = fs.lstat(old_path)?.type == "link";
    fs.unlink(old_path);
    remove_paths(base);
    t.eq(content, "preserved synthetic data");
    t.ok(preserved_link, "the unrelated legacy-path symlink was removed");
    t.eq(result, { status: 7, stderr: "changed" });
});

t.test("temporary command output stays behind a private directory and is cleaned after failure", () => {
    let base = temporary(3);
    let result = exec.capture_parallel([
        [ "sh", "-c", "stat -c %a \"$1\"; printf partial; exit 7", "sh", base ],
        [ "printf", "%s", "quote' $(printf injected); *" ]
    ]);
    let left = fs.lstat(base);
    remove_paths(base);
    t.eq(result, [ { status: 7, stdout: "700\npartial" }, { status: 0, stdout: "quote' $(printf injected); *" } ]);
    t.eq(left, null);
    base = temporary(4);
    result = exec.feed([ "sh", "-c", "cat >/dev/null; stat -c %a \"$1\" >&2; exit 9", "sh", base ], "");
    left = fs.lstat(base);
    remove_paths(base);
    t.eq(result, { status: 9, stderr: "700\n" });
    t.eq(left, null);
});

t.test("a pre-existing directory, file or symlink is refused without commands or cleanup of foreign data", () => {
    let dir = stub.tmpdir();
    let victim = dir + "/victim";
    let marker = dir + "/command-ran";
    fs.writefile(victim, "preserved");
    let nonce = 10;
    for (let kind in [ "directory", "file", "symlink", "dangling", "symlink_directory" ]) {
        let base = temporary(nonce++);
        if (kind == "directory")
            fs.mkdir(base, 0700);
        else if (kind == "file")
            fs.writefile(base, "preserved");
        else
            exec.status([ "ln", "-s", kind == "dangling" ? dir + "/absent" : kind == "symlink_directory" ? dir : victim, base ]);
        let command = [ "sh", "-c", "printf ran >\"$1\"", "sh", marker ];
        let parallel = exec.capture_parallel([ command, command ]);
        let feed = exec.feed(command, "fixture");
        let present = fs.lstat(base) != null;
        let content = fs.readfile(victim);
        let ran = fs.stat(marker);
        if (kind == "directory") fs.rmdir(base); else fs.unlink(base);
        remove_paths(base);
        fs.unlink(marker);
        t.eq(parallel, [ { status: 1, stdout: "" }, { status: 1, stdout: "" } ], kind);
        t.eq(feed, { status: 1, stderr: "" }, kind);
        t.ok(present, kind + " was removed");
        t.eq(content, "preserved");
        t.eq(ran, null, kind + " allowed command execution");
    }
});

t.test("directory allocation and pipe-open failures leave no temporary directory", () => {
    let base = temporary(20);
    let mkdir = fs.mkdir;
    fs.mkdir = () => false;
    let parallel = exec.capture_parallel([ [ "printf", "must not run" ] ]);
    let feed = exec.feed([ "printf", "must not run" ], "fixture");
    fs.mkdir = mkdir;
    t.eq(parallel, [ { status: 1, stdout: "" } ]);
    t.eq(feed, { status: 1, stderr: "" });
    t.eq(fs.lstat(base), null);
    let popen = fs.popen;
    fs.popen = () => null;
    feed = exec.feed([ "printf", "must not run" ], "fixture");
    fs.popen = popen;
    let left = fs.lstat(base);
    remove_paths(base);
    t.eq(feed, { status: 1, stderr: "" });
    t.eq(left, null);
    t.eq(exec.capture_parallel([]), []);
    t.eq(fs.lstat(base), null);
});

t.done();
