let t = require("t"), fs = require("fs"), stub = require("stub"), update = require("service.update");
function fixture() {
    let root = stub.tmpdir(); fs.chmod(root, 0700);
    for (let size in [ 511, 512, 513 ]) {
        fs.writefile(root + "/file" + size, sprintf("%" + size + "s", "x"));
        fs.chmod(root + "/file" + size, 0600);
    }
    return root;
}
t.test("the existing own-state walk supplies a bounded tar footprint without reading bodies", () => {
    let root = fixture(), open = fs.open, result, error;
    fs.open = (path, mode) => {
        if (index(path, root + "/") == 0) die("unexpected state body read");
        return open(path, mode);
    };
    try { result = update.state_tree([ root ]); } catch (e) { error = e; }
    fs.open = open; if (error != null) die(error);
    let device = fs.lstat(root).dev;
    t.eq(result, { bytes: 1536, archive_bytes: 45056, entries: 4, devices: [ device.major + ":" + device.minor ] });
    t.eq(update.state_tree([]), { bytes: 0, archive_bytes: 10240, entries: 0, devices: [] });
    let archive = root + ".tar";
    t.eq(stub.real.system("/bin/busybox tar -cf '" + archive + "' -C '" + root + "' ."), 0);
    t.ok(fs.lstat(archive).size <= result.archive_bytes);
});
t.test("unsafe state paths and oversized metadata refuse rather than publishing a smaller budget", () => {
    for (let fault in [ "mode", "link", "hardlink", "size" ]) {
        let root = fixture(), path = root + "/file511", lstat = fs.lstat;
        if (fault == "mode") fs.chmod(root, 0755);
        if (fault == "link") { fs.rename(path, path + ".keep"); fs.symlink(path + ".keep", path); }
        if (fault == "hardlink") stub.real.system("ln '" + path + "' '" + path + ".keep'");
        if (fault == "size") fs.lstat = (name) => {
            let node = lstat(name); return name == path && node != null ? { ...node, size: 2147483648 } : node;
        };
        let error;
        try { update.state_tree([ root ]); } catch (e) { error = e; }
        fs.lstat = lstat;
        t.ok(error != null, fault);
        t.eq(error.message, fault == "size" ? "own-state-byte-limit" : "own-state-path-unverified");
    }
});
t.test("state enumeration is streamed and bounded, with read and close failures refused", () => {
    for (let fault in [ "none", "read", "close", "entries" ]) {
        let root = fixture(), lsdir = fs.lsdir, opendir = fs.opendir, closed = 0, reads = 0;
        fs.lsdir = () => die("unbounded-directory-snapshot");
        fs.opendir = (path) => {
            let directory = opendir(path); if (directory == null || path != root) return directory;
            return { fileno: () => directory.fileno(), read: () => {
                reads++; if (fault == "read") die("private-read-failure");
                return fault == "entries" ? "." : directory.read();
            }, close: () => { closed++; let okay = directory.close(); return fault == "close" ? false : okay; } };
        };
        let result, error;
        try { result = update.state_tree([ root ]); } catch (e) { error = e; }
        fs.lsdir = lsdir; fs.opendir = opendir;
        if (fault == "none") { t.eq(error, null); t.eq(result.entries, 4); }
        else { t.ok(error != null); t.eq(error.message, fault == "entries" ? "own-state-entry-limit" : "own-state-unavailable"); }
        t.eq(closed, 1); t.ok(reads <= 49153);
    }
});
t.done();
