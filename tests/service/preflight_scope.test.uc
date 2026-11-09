let t = require("t");
let fs = require("fs");
let scope = require("service.preflight_scope");

const MOUNTS = "1 1 0:1 / / rw - overlay overlay rw\n2 1 0:2 / /proc rw,nosuid,nodev,noexec - proc proc rw\n";

function fixture(change, run) {
    let saved = {};
    for (let key in [ "opendir", "readlink", "stat", "lstat", "open", "error" ]) saved[key] = fs[key];
    let seen = { closes: 0, directory_closes: 0, reads: 0 };
    let node = { type: "file", inode: 100, dev: { major: 0, minor: 2 }, uid: 0, mode: 0444,
        nlink: 1, size: 0, mtime: 0, ctime: 0 };
    let directory = { type: "directory", inode: 1, dev: { major: 0, minor: 1 }, uid: 0, mode: 0755 };
    let names = [ ".", "..", "mnt", "net", "pid", "user" ];
    fs.opendir = (path) => {
        let i = 0;
        return { read: () => names[i++], close: () => { seen.directory_closes++; return true; } };
    };
    fs.readlink = (path) => { let kind = split(path, "/"); return pop(kind) + ":[123]"; };
    fs.lstat = (path) => path == "/proc/self/mountinfo" ? node : directory;
    fs.stat = (path) => index(path, "/proc/self/fd/") == 0 ? node : directory;
    fs.error = () => null;
    fs.open = () => ({ fileno: () => 23, read: () => { seen.reads++; return MOUNTS; }, error: () => null,
        close: () => { seen.closes++; return true; } });
    let error;
    try { change(seen, names, node, directory); run(seen); }
    catch (e) { error = e; }
    for (let key in keys(saved)) fs[key] = saved[key];
    if (error != null) die(error);
}

t.test("visible PID1 namespaces and roots must agree across the whole observation", () => {
    fixture(() => {}, (seen) => {
        let result = scope.check(scope.snapshot());
        t.eq(result, { kind: "environment", object: "namespace-layout", state: "checked",
            reason: "environment-pid1-relative-scope-checked" });
        t.eq(seen.closes, 2);
        t.eq(seen.directory_closes, 4);
        t.excludes(sprintf("%J", result), "123");
        t.excludes(sprintf("%J", result), "overlay");
    });
});

t.test("kernel-disabled optional namespaces are accepted only after complete directory reads", () => {
    fixture((seen, names) => { splice(names, 3); }, () => {
        t.eq(scope.check(scope.snapshot()).state, "checked");
    });
    for (let count in [ 32, 33 ]) {
        fixture((seen, names) => {
            splice(names, 3);
            for (let i = 3; i < count; i++) push(names, "entry" + sprintf("%c%c", 97 + int(i / 26), 97 + i % 26));
        }, () => t.eq(scope.check(scope.snapshot()).state, count == 32 ? "checked" : "incomplete"));
    }
    for (let failure in [ "missing", "read", "close", "close-throw", "duplicate", "limit", "mnt-absent" ]) {
        fixture((seen, names) => {
            if (failure == "duplicate") push(names, "mnt");
            if (failure == "limit") for (let i = 0; i < 40; i++) push(names, "entry" + sprintf("%c%c", 97 + int(i / 26), 97 + i % 26));
            if (failure == "mnt-absent") splice(names, 2, 1);
            if (failure == "missing") fs.opendir = () => null;
            if (failure == "read" || failure == "close" || failure == "close-throw") fs.opendir = () => {
                let i = 0;
                return { read: () => { if (failure == "read") die("synthetic-secret"); return names[i++]; },
                    close: () => { seen.directory_closes++; if (failure == "close-throw") die("synthetic-secret"); return false; } };
            };
        }, (seen) => {
            let result = scope.check(scope.snapshot());
            t.eq(result.state, "incomplete");
            t.excludes(sprintf("%J", result), "synthetic-secret");
            if (failure == "read") t.ok(seen.directory_closes > 0);
        });
    }
});

t.test("missing, malformed, changed or foreign namespace identities refuse scope coverage", () => {
    for (let mode in [ "missing", "throw", "nul", "zero", "kind", "foreign", "changed", "different-entries" ]) {
        fixture(() => {
            let original = fs.readlink;
            let calls = 0;
            fs.readlink = (path) => {
                calls++;
                if (mode == "missing") return null;
                if (mode == "throw") die("synthetic-secret");
                if (mode == "nul") return "mnt:[123]\u0000synthetic-secret";
                if (mode == "zero") return "mnt:[0]";
                if (mode == "kind") return "pid:[123]";
                let value = original(path);
                if ((mode == "foreign" && index(path, "/proc/1/") == 0) || (mode == "changed" && calls > 8))
                    return replace(value, "123", "124");
                return value;
            };
            if (mode == "different-entries") {
                let open = fs.opendir;
                fs.opendir = (path) => path == "/proc/1/ns" ? { read: () => null, close: () => true } : open(path);
            }
        }, () => {
            let result = scope.check(scope.snapshot());
            t.eq(result.state, "incomplete");
            t.excludes(sprintf("%J", result), "synthetic-secret");
            t.excludes(sprintf("%J", result), "124");
        });
    }
});

t.test("chroot, different root device, unsafe root and root changes refuse coverage", () => {
    for (let mode in [ "inode", "device", "owner", "mode", "type", "missing", "changed", "throw" ]) {
        fixture((seen, names, node, directory) => {
            let stat = fs.stat;
            let roots = 0;
            fs.stat = (path) => {
                if (path == "/proc/1/root") {
                    roots++;
                    if (mode == "throw") die("synthetic-secret");
                    if (mode == "missing") return null;
                    let result = { ...directory };
                    if (mode == "inode" || (mode == "changed" && roots > 1)) result.inode = 2;
                    if (mode == "device") result.dev = { major: 0, minor: 3 };
                    if (mode == "owner") result.uid = 1000;
                    if (mode == "mode") result.mode = 0777;
                    if (mode == "type") result.type = "file";
                    return result;
                }
                return stat(path);
            };
        }, () => {
            let result = scope.check(scope.snapshot());
            t.eq(result.state, "incomplete");
            t.excludes(sprintf("%J", result), "synthetic-secret");
        });
    }
});

t.test("proc mount coverage rejects hiding, submounts and malformed or truncated data", () => {
    t.eq(scope.parse_mountinfo(MOUNTS).error, null);
    t.eq(scope.parse_mountinfo(replace(MOUNTS, "proc proc rw", "proc proc rw,hidepid=0")).error, null);
    t.eq(scope.parse_mountinfo(MOUNTS + "3 2 0:3 / /proc/sys/fs/binfmt_misc rw - autofs systemd rw\n" +
        "4 3 0:4 / /proc/sys/fs/binfmt_misc rw - binfmt_misc binfmt_misc rw\n").error, null);
    for (let data in [ null, "", substr(MOUNTS, 0, length(MOUNTS) - 1), MOUNTS + "\u0000",
        replace(MOUNTS, "proc proc rw", "proc proc rw,hidepid=2"),
        replace(MOUNTS, "proc proc rw", "proc proc rw,subset=pid"),
        replace(MOUNTS, "/ /proc", "/private /proc"), replace(MOUNTS, "proc proc rw", "tmpfs proc rw"),
        MOUNTS + "3 2 0:3 / /proc/1 rw - tmpfs tmpfs rw\n",
        MOUNTS + "3 2 0:3 / /proc/self/private\\040leaf rw - tmpfs tmpfs rw\n",
        replace(MOUNTS, "/ /proc", "/ /pr\\157c"),
        MOUNTS + "3 1 0:3 / /private\\999 rw - tmpfs tmpfs rw\n",
        MOUNTS + "3 1 0:3 / /proc rw - proc proc rw\n",
        replace(MOUNTS, "2 1 0:2 / /proc rw,nosuid,nodev,noexec - proc proc rw\n", ""),
        sprintf("%262145s", "x") ]) t.ok(scope.parse_mountinfo(data).error != null);
    let data = MOUNTS;
    for (let i = 3; i <= 2048; i++) data += i + " 1 0:3 / /private" + i + " rw - tmpfs tmpfs rw\n";
    t.eq(scope.parse_mountinfo(data).error, null);
    t.ok(scope.parse_mountinfo(data + "2049 1 0:3 / /extra rw - tmpfs tmpfs rw\n").error != null);
    for (let path in [ "/proc/self", "/proc/thread-self", "/proc/net", "/proc/meminfo", "/proc/sys", "/proc/sys/net", "/proc/999/stat" ])
        t.ok(scope.parse_mountinfo(MOUNTS + "3 2 0:3 / " + path + " rw - tmpfs tmpfs rw\n").error != null);
});

t.test("mountinfo handles close on failures and bounds real reads including the lookahead byte", () => {
    for (let failure in [ "open", "read", "error", "data", "close", "close-throw", "overflow", "identity", "changed" ]) {
        fixture((seen) => {
            let original = fs.open;
            fs.open = () => {
                if (failure == "open") return null;
                let file = original();
                let read = file.read;
                file.read = (limit) => {
                    t.eq(limit, 262145);
                    if (failure == "read") die("synthetic-secret");
                    if (failure == "data") return null;
                    if (failure == "overflow") return sprintf("%262145s", "x");
                    if (failure == "changed" && seen.reads > 0) return MOUNTS + "3 1 0:3 / /new rw - tmpfs tmpfs rw\n";
                    return read();
                };
                if (failure == "error") file.error = () => "synthetic-secret";
                if (failure == "close" || failure == "close-throw") file.close = () => {
                    seen.closes++; if (failure == "close-throw") die("synthetic-secret"); return false;
                };
                return file;
            };
            if (failure == "identity") {
                let stat = fs.stat;
                fs.stat = (path) => index(path, "/proc/self/fd/") == 0 ? null : stat(path);
            }
        }, (seen) => {
            let result = scope.check(scope.snapshot());
            t.eq(result.state, "incomplete");
            t.excludes(sprintf("%J", result), "synthetic-secret");
            t.excludes(sprintf("%J", result), "/new");
            if (failure != "open") t.ok(seen.closes > 0);
        });
    }
});

t.test("system origin requires the supported OpenWrt package and PID1 profile", () => {
    let stub=require("stub"),root=stub.tmpdir();
    for(let path in ["sbin","proc","proc/1"])fs.mkdir(root+"/"+path,0700);
    fs.writefile(root+"/sbin/procd","trusted fixture, never executed");fs.chmod(root+"/sbin/procd",0755);
    fs.symlink(root+"/sbin/procd",root+"/proc/1/exe");
    let packages=map(["base-files","procd","kernel"],(name)=>({name,version:"1"}));
    let platform={state:"checked",architecture:"x86_64"};
    t.eq(scope.origin(root,platform,packages).state,"checked");
    for(let records in [[],slice(packages,1),[...packages,packages[0]],[null]])
        t.eq(scope.origin(root,platform,records).state,"incomplete");
    t.eq(scope.origin(root,{state:"conflict"},packages).state,"incomplete");
    fs.chmod(root+"/sbin/procd",0777);
    t.eq(scope.origin(root,platform,packages).state,"incomplete");
    fs.chmod(root+"/sbin/procd",0755);fs.unlink(root+"/proc/1/exe");
    fs.symlink(root+"/sbin/foreign-init",root+"/proc/1/exe");
    t.eq(scope.origin(root,platform,packages).state,"incomplete");
});

t.done();
