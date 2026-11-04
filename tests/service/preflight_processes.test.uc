let t = require("t");
let stub = require("stub");
let fs = require("fs");
let processes = require("service.preflight_processes");

function stat(pid, name, start) {
    let fields = [ "S" ];
    for (let i = 1; i < 50; i++) push(fields, i == 19 ? (start || "18446744073709551615") : "0");
    return pid + " (" + (name || "private )\n(name") + ") " + join(" ", fields) + "\n";
}

function fixture() {
    let root = stub.tmpdir();
    fs.chmod(root, 0700);
    fs.mkdir(root + "/proc", 0755);
    fs.mkdir(root + "/proc/42", 0755);
    fs.writefile(root + "/proc/42/stat", stat("42"));
    fs.chmod(root + "/proc/42/stat", 0644);
    fs.writefile(root + "/loki-core", "private executable contents");
    fs.chmod(root + "/loki-core", 0755);
    fs.symlink(root + "/loki-core", root + "/proc/42/exe");
    return root;
}

function has(result, reason, object) {
    return length(filter(result, (item) => item.reason == reason && (object == null || item.object == object))) > 0;
}

t.test("stat parser handles raw parentheses, newlines and precise unsigned start times", () => {
    for (let name in [ "", "x)y) z", "x\ny\t\r\u0001", sprintf("%64s", "x") ])
        t.eq(processes.parse(stat("42", name), "42"), { start: "18446744073709551615" });
    t.eq(processes.parse(stat("42", null, "9007199254740993"), "42").start, "9007199254740993");
});

t.test("stat parser refuses truncation, invalid PID, state, numeric tail and oversized input", () => {
    let good = stat("42");
    for (let data in [ null, "", substr(good, 0, length(good) - 1), good + "0\n", good + good,
        replace(good, ") S ", ") Q "), replace(good, " 0 ", " NaN "), replace(good, " 0 ", "  0 "),
        replace(good, "18446744073709551615", "-1"), replace(good, "18446744073709551615", "01"),
        stat("42", sprintf("%65s", "x")), good + "\u0000", sprintf("%4097s", "x") ])
        t.ok(processes.parse(data, "42").error != null);
    for (let pid in [ "0", "042", "2147483648", "../42", "42\n", 42 ])
        t.ok(processes.parse(good, pid).error != null);
    t.ok(processes.parse(good, "43").error != null);
});

t.test("discovery has fixed hints and gaps, no PID, path, comm, secret or command execution", () => {
    let root = fixture();
    let commands = stub.commands([]);
    let result = processes.collect(root);
    stub.restore();
    t.eq(commands.calls, []);
    t.ok(has(result, "process-directory-read-complete"));
    t.ok(has(result, "process-executable-name-hint-unverified", "own-core"));
    t.ok(has(result, "process-namespace-and-visibility-unverified"));
    t.ok(has(result, "process-script-and-package-origin-unverified"));
    for (let secret in [ root, "18446744073709551615", "private", "42", "loki-core" ])
        t.excludes(sprintf("%J", result), secret);
    t.eq(processes.collect(root), result);
});

t.test("native names are hints without ownership or conflict, interpreters retain script gaps", () => {
    let root = fixture();
    for (let pair in [ [ "sing-box", "foreign-core" ], [ "podkop", "foreign-app" ],
        [ "forkop", "foreign-app" ], [ "ucode", "interpreter" ], [ "busybox", "interpreter" ],
        [ "dnsmasq", "dns-service" ], [ "loki", "own-app" ] ]) {
        fs.rename(root + "/loki-core", root + "/" + pair[0]);
        fs.unlink(root + "/proc/42/exe");
        fs.symlink(root + "/" + pair[0], root + "/proc/42/exe");
        let result = processes.collect(root);
        t.ok(has(result, "process-executable-name-hint-unverified", pair[1]));
        t.eq(length(filter(result, (item) => item.state == "conflict")), 0);
        fs.rename(root + "/" + pair[0], root + "/loki-core");
    }
});

t.test("unsafe roots and linked PID/stat nodes never become empty inventories", () => {
    let root = fixture();
    fs.chmod(root, 0777);
    t.ok(has(processes.collect(root), "process-directory-unavailable"));
    fs.chmod(root, 0700);
    fs.symlink(root + "/proc/42", root + "/proc/43");
    t.ok(has(processes.collect(root), "process-directory-entry-unavailable"));
    fs.unlink(root + "/proc/42/stat");
    fs.symlink(root + "/loki-core", root + "/proc/42/stat");
    t.ok(has(processes.collect(root), "process-stat-unavailable"));
});

t.test("an opened inode substitution is refused before reading, and its handle closes", () => {
    let root = fixture();
    let open = fs.open;
    let read = false;
    let closed = false;
    fs.open = (path, mode) => {
        let file = open(path == root + "/proc/42/stat" ? root + "/loki-core" : path, mode);
        return { fileno: () => file.fileno(), read: () => { read = true; return ""; },
            close: () => { closed = true; return file.close(); } };
    };
    let result = processes.collect(root);
    fs.open = open;
    t.ok(has(result, "process-changed-during-read"));
    t.eq(read, false);
    t.eq(closed, true);
});

t.test("short stat, read errors, exceptions and failed close preserve no raw error detail", () => {
    for (let failure in [ "read", "error", "close", "short" ]) {
        let root = fixture();
        let open = fs.open;
        let closed = false;
        fs.open = (path, mode) => {
            let file = open(path, mode);
            return { fileno: () => file.fileno(), read: (limit) => {
                if (failure == "read") die("private-read-error");
                return failure == "short" ? "42 (private) S 0\n" : file.read(limit);
            }, error: () => failure == "error" ? "private-error" : file.error(), close: () => {
                closed = true;
                let value = file.close();
                return failure == "close" ? false : value;
            } };
        };
        let result = processes.collect(root);
        fs.open = open;
        t.ok(has(result, failure == "short" ? "process-stat-invalid" : "process-stat-read-failed"));
        t.eq(closed, true);
        t.excludes(sprintf("%J", result), "private");
        t.eq(has(result, "process-directory-read-complete"), false);
    }
});

t.test("PID reuse and executable switches are not accepted as stable observations", () => {
    for (let change in [ "start", "path", "inode", "directory" ]) {
        let root = fixture();
        let open = fs.open;
        let readlink = fs.readlink;
        let lstat = fs.lstat;
        let stat_reads = 0;
        let exe_reads = 0;
        fs.open = (path, mode) => {
            let file = open(path, mode);
            return { fileno: () => file.fileno(), read: (limit) => {
                let data = file.read(limit);
                if (++stat_reads == 2 && change == "start") data = replace(data, "18446744073709551615", "18446744073709551614");
                return data;
            }, error: () => file.error(), close: () => file.close() };
        };
        fs.readlink = (path) => {
            let value = readlink(path);
            if (++exe_reads == 2) {
                if (change == "path") return root + "/different-private-name";
                if (change == "inode") {
                    fs.rename(root + "/loki-core", root + "/old");
                    fs.writefile(root + "/loki-core", "new");
                }
            }
            return value;
        };
        fs.lstat = (path) => {
            let value = lstat(path);
            if (change == "directory" && path == root + "/proc/42" && exe_reads >= 2) value.inode++;
            return value;
        };
        let result = processes.collect(root);
        fs.open = open;
        fs.readlink = readlink;
        fs.lstat = lstat;
        t.ok(has(result, "process-changed-during-read"));
        t.eq(has(result, "process-executable-name-hint-unverified"), false);
    }
});

t.test("missing, deleted, control-bearing, directory and oversized executables stay incomplete", () => {
    for (let bad in [ "missing", "deleted", "control", "directory", "size" ]) {
        let root = fixture();
        if (bad == "missing") fs.unlink(root + "/proc/42/exe");
        if (bad == "directory") { fs.unlink(root + "/proc/42/exe"); fs.symlink(root, root + "/proc/42/exe"); }
        let readlink = fs.readlink;
        fs.readlink = (path) => bad == "deleted" ? root + "/loki-core (deleted)" :
            bad == "control" ? "/private\nname" : bad == "size" ? "/" + sprintf("%4095s", "x") : readlink(path);
        let result = processes.collect(root);
        fs.readlink = readlink;
        t.ok(has(result, "process-executable-unavailable"));
        t.eq(has(result, "process-directory-read-complete"), false);
    }
});

t.test("actual bounded stat reads include lookahead and do not trust advertised size", () => {
    let root = fixture();
    fs.writefile(root + "/proc/42/stat", sprintf("%4097s", "x"));
    t.ok(has(processes.collect(root), "process-stat-size-limit"));
});

t.test("directory entry and aggregate read budgets stop streaming enumeration", () => {
    for (let large in [ false, true ]) {
        let root = fixture();
        let opendir = fs.opendir;
        let reads = 0;
        fs.opendir = (path) => {
            let handle = opendir(path);
            if (path != root + "/proc") return handle;
            return { fileno: () => handle.fileno(), read: () => {
                reads++;
                return large ? "42" : "unrelated-private-entry";
            }, close: () => handle.close() };
        };
        let readlink = fs.readlink;
        if (large) fs.readlink = () => "/" + sprintf("%4000s", "x") + "/loki-core";
        // Isolate byte/entry bounds from machine speed; the deadline has its own regression.
        global.clock = () => [ 1, 0 ];
        let result = processes.collect(root);
        global.clock = stub.real.clock;
        fs.opendir = opendir;
        fs.readlink = readlink;
        t.ok(has(result, large ? "process-aggregate-byte-limit" : "process-directory-entry-limit"));
        if (large) t.ok(reads < 4097);
        else t.eq(reads, 4097);
        t.eq(has(result, "process-directory-read-complete"), false);
    }
});

t.test("exactly 4096 directory entries followed by EOF fit the entry budget", () => {
    let root = fixture();
    let opendir = fs.opendir;
    fs.opendir = (path) => {
        let handle = opendir(path);
        if (path != root + "/proc") return handle;
        let count = 0;
        return { fileno: () => handle.fileno(), read: () => ++count <= 4096 ? "unrelated" : null,
            close: () => handle.close() };
    };
    let result = processes.collect(root);
    fs.opendir = opendir;
    t.ok(has(result, "process-directory-read-complete"));
    t.eq(has(result, "process-directory-entry-limit"), false);
});

t.test("monotonic deadline, clock failure and reversed time cannot claim a complete scan", () => {
    for (let value in [ [ 9, 0 ], [ 0, 0 ], null ]) {
        let root = fixture();
        let reads = 0;
        global.clock = () => ++reads == 1 ? [ 1, 0 ] : value;
        let result = processes.collect(root);
        global.clock = stub.real.clock;
        t.ok(has(result, "process-time-limit"));
        t.eq(has(result, "process-directory-read-complete"), false);
    }
});

t.test("directory read and close failures close the descriptor and redact exception text", () => {
    for (let failure in [ "read", "close" ]) {
        let root = fixture();
        let opendir = fs.opendir;
        let closed = false;
        fs.opendir = (path) => {
            let handle = opendir(path);
            if (path != root + "/proc") return handle;
            return { fileno: () => handle.fileno(), read: () => {
                if (failure == "read") die("private-directory-read");
                return handle.read();
            }, close: () => {
                closed = true;
                handle.close();
                if (failure == "close") die("private-directory-close");
                return true;
            } };
        };
        let result = processes.collect(root);
        fs.opendir = opendir;
        t.ok(has(result, "process-directory-read-failed"));
        t.eq(closed, true);
        t.excludes(sprintf("%J", result), "private");
        t.eq(has(result, "process-directory-read-complete"), false);
    }
});

t.test("directory descriptor substitution and vanished PID metadata cannot claim coverage", () => {
    let root = fixture();
    let opendir = fs.opendir;
    let closed = false;
    fs.opendir = (path) => {
        let handle = opendir(path == root + "/proc" ? root : path);
        return { fileno: () => handle.fileno(), read: () => die("must not read"),
            close: () => { closed = true; return handle.close(); } };
    };
    let result = processes.collect(root);
    fs.opendir = opendir;
    t.ok(has(result, "process-directory-changed"));
    t.eq(closed, true);
    let lstat = fs.lstat;
    fs.lstat = (path) => path == root + "/proc/42" ? null : lstat(path);
    result = processes.collect(root);
    fs.lstat = lstat;
    t.ok(has(result, "process-directory-entry-unavailable"));
    t.eq(has(result, "process-directory-read-complete"), false);
});

t.done();
