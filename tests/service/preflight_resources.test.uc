let t = require("t");
let fs = require("fs");
let stub = require("stub");
let resources = require("service.preflight_resources");

const QUERY = "exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -s KILL 2 /bin/df -Pk / /tmp";
const MEMORY = "MemTotal: 1024 kB\nMemAvailable: 512 kB\nSwapTotal: 2048 kB\nSwapFree: 1024 kB\nHugePages_Total: 0\n";
const DISK = "Filesystem 1024-blocks Used Available Capacity Mounted on\nprivate-device 1000 400 500 45% /\ntmpfs 2000 100 1900 5% /tmp\n";

function fixture() {
    let root = stub.tmpdir();
    fs.chmod(root, 0700);
    fs.mkdir(root + "/proc", 0755);
    fs.writefile(root + "/proc/meminfo", MEMORY);
    fs.chmod(root + "/proc/meminfo", 0644);
    return root;
}

function has(result, state, reason) {
    return length(filter(result, (item) => item.state == state && item.reason == reason)) > 0;
}

function reply(value) {
    stub.commands([[ QUERY, value ?? { stdout: DISK } ]]);
}

t.test("memory counters keep bytes precise and accept zero availability without inventing capacity", () => {
    t.eq(resources.parse_meminfo(MEMORY), { total_bytes: 1048576, available_bytes: 524288,
        swap_total_bytes: 2097152, swap_free_bytes: 1048576 });
    let zero = replace(replace(MEMORY, "MemAvailable: 512", "MemAvailable: 0"), "SwapFree: 1024", "SwapFree: 0");
    t.eq(resources.parse_meminfo(zero).available_bytes, 0);
    let boundary = replace(MEMORY, "MemTotal: 1024", "MemTotal: 8796093022207");
    t.eq(resources.parse_meminfo(boundary).total_bytes, 9007199254739968);
    t.ok(resources.parse_meminfo(MEMORY + "VmallocTotal: 999999999999999999999999999999 kB\n").error == null,
        "unused virtual address capacity is not a physical memory limit");
});

t.test("memory parsing refuses missing, repeated, inconsistent, overflowed and unfinished counters", () => {
    for (let data in [ null, "", substr(MEMORY, 0, length(MEMORY) - 1), MEMORY + "\u0000",
        MEMORY + "MemTotal: 1024 kB\n", replace(MEMORY, "MemTotal: 1024 kB\n", ""),
        replace(MEMORY, "MemTotal: 1024", "MemTotal: 0"), replace(MEMORY, "MemAvailable: 512", "MemAvailable: 1025"),
        replace(MEMORY, "SwapFree: 1024", "SwapFree: 2049"), replace(MEMORY, "1024 kB", "1024"),
        replace(MEMORY, "MemTotal: 1024", "MemTotal: 01024"), replace(MEMORY, "MemTotal: 1024", "MemTotal: -1"),
        replace(MEMORY, "MemTotal: 1024", "MemTotal: 1.5"), replace(MEMORY, "MemTotal: 1024", "MemTotal: 8796093022208"),
        replace(MEMORY, "MemTotal: 1024", "MemTotal: 999999999999999999999"), replace(MEMORY, " kB", " MB"),
        sprintf("%65537s", "x") ])
        t.eq(resources.parse_meminfo(data).error, "resource-memory-data-invalid");
});

t.test("byte ceilings accept complete snapshots at the boundary and reject otherwise valid larger data", () => {
    let prefix = MEMORY + "Unused: 1";
    let memory = prefix + sprintf("%" + (65536 - length(prefix) - 1) + "s", "") + "\n";
    t.eq(length(memory), 65536);
    t.ok(resources.parse_meminfo(memory).error == null);
    let larger = substr(memory, 0, length(memory) - 1) + " \n";
    t.eq(resources.parse_meminfo(larger).error, "resource-memory-data-invalid");
    let disk = replace(DISK, "Filesystem", "Filesystem" + sprintf("%" + (16384 - length(DISK)) + "s", ""));
    t.eq(length(disk), 16384);
    t.ok(resources.parse_df(disk).error == null);
    t.eq(resources.parse_df(replace(disk, "Filesystem", "Filesystem ")).error, "resource-filesystem-data-invalid");
});

t.test("POSIX df parsing preserves operand order and omits untrusted labels", () => {
    t.eq(resources.parse_df(DISK), {
        root: { total_bytes: 1024000, used_bytes: 409600, available_bytes: 512000 },
        temporary: { total_bytes: 2048000, used_bytes: 102400, available_bytes: 1945600 }
    });
    t.eq(resources.parse_df(replace(DISK, "private-device", "$(touch${IFS}/private-canary)")), resources.parse_df(DISK));
    t.eq(resources.parse_df(replace(DISK, " /tmp\n", " /\n")), resources.parse_df(DISK),
        "both operands may reside on the same mount");
    t.eq(resources.parse_df(replace(DISK, " ", "\t")), resources.parse_df(DISK));
});

t.test("filesystem parsing refuses wrong headers, row counts, numbers, units and size", () => {
    for (let data in [ null, "", substr(DISK, 0, length(DISK) - 1), DISK + "\n", DISK + "\u0000",
        replace(DISK, "1024-blocks", "1M-blocks"), replace(DISK, " 1000 ", " 0 "),
        replace(DISK, " 400 ", " 1001 "), replace(DISK, " 500 ", " 1001 "),
        replace(DISK, " 500 ", " -1 "), replace(DISK, " 500 ", " 1.5 "), replace(DISK, " 500 ", " 0500 "),
        replace(DISK, " 1000 ", " 8796093022208 "), replace(DISK, " 1000 ", " 999999999999999999999 "),
        replace(DISK, "45%", "101%"), replace(DISK, "45%", "045%"), replace(DISK, " /tmp", " relative"),
        replace(DISK, "500", "500\r"), sprintf("%16385s", "x") ])
        t.eq(resources.parse_df(data).error, "resource-filesystem-data-invalid");
});

t.test("readable snapshots retain mandatory transaction, tmpfs and namespace uncertainty", () => {
    let root = fixture();
    reply();
    let before = fs.readfile(root + "/proc/meminfo");
    for (let i = 0; i < 2; i++) {
        let result = resources.collect(root);
        t.ok(has(result, "checked", "resource-memory-snapshot-read-complete"));
        t.ok(has(result, "checked", "resource-filesystem-snapshot-read-complete"));
        t.ok(has(result, "incomplete", "resource-transaction-budget-namespace-unverified"));
        t.excludes(sprintf("%J", result), "private-device");
        t.excludes(sprintf("%J", result), "MemAvailable");
    }
    t.eq(stub.command_lines(), [ QUERY, QUERY ]);
    t.eq(fs.readfile(root + "/proc/meminfo"), before);
});

t.test("unsafe roots and memory paths refuse without opening links, FIFOs or shared files", () => {
    let root = fixture();
    reply();
    fs.chmod(root, 0775);
    t.ok(has(resources.collect(root), "incomplete", "resource-root-unsafe"));
    t.eq(stub.command_lines(), []);
    fs.chmod(root, 0700);
    let path = root + "/proc/meminfo";
    fs.chmod(path, 0666);
    t.ok(has(resources.collect(root), "incomplete", "resource-memory-path-unsafe"));
    fs.chmod(path, 0644);
    fs.rename(path, path + ".keep");
    fs.symlink(path + ".keep", path);
    t.ok(has(resources.collect(root), "incomplete", "resource-memory-path-unsafe"));
    t.eq(fs.readfile(path + ".keep"), MEMORY);
    fs.unlink(path);
    stub.real.system("ln '" + path + ".keep' '" + path + "'");
    t.ok(has(resources.collect(root), "incomplete", "resource-memory-path-unsafe"));
    fs.unlink(path);
    stub.real.system("mkfifo '" + path + "'");
    t.ok(has(resources.collect(root), "incomplete", "resource-memory-path-unsafe"));
    fs.unlink(path);
    t.ok(has(resources.collect(root), "incomplete", "resource-memory-unavailable"));
    fs.writefile(path, sprintf("%65537s", "x"));
    fs.chmod(path, 0644);
    let original = fs.open;
    let opens = 0;
    fs.open = (name, mode) => { if (name == path) opens++; return original(name, mode); };
    let result;
    let error;
    try { result = resources.collect(root); }
    catch (e) { error = e; }
    fs.open = original;
    if (error != null) die(error.message);
    t.ok(has(result, "incomplete", "resource-memory-size-limit"));
    t.eq(opens, 0);
});

t.test("query failure and oversized output never become an empty successful filesystem snapshot", () => {
    let root = fixture();
    for (let value in [ { stdout: DISK, status: 1 }, { stdout: "private-canary" },
        { stdout: sprintf("%16385s", "x") } ]) {
        reply(value);
        let result = resources.collect(root);
        t.ok(!has(result, "checked", "resource-filesystem-snapshot-read-complete"));
        t.ok(has(result, "incomplete", "resource-transaction-budget-namespace-unverified"));
        t.excludes(sprintf("%J", result), "private-canary");
    }
});

t.test("descriptor identity, post-read metadata and I/O errors are checked before accepting memory", () => {
    let root = fixture();
    let path = root + "/proc/meminfo";
    reply();
    for (let kind in [ "descriptor", "named", "parent", "read", "error", "oversized-read", "close", "proc-size-zero" ]) {
        let original = { open: fs.open, stat: fs.stat, lstat: fs.lstat };
        let opened = false;
        let closed = 0;
        fs.lstat = (name) => {
            let node = original.lstat(name);
            if (name == root + "/proc" && kind == "parent" && opened)
                return { ...node, type: "link" };
            if (name == path && node != null) {
                if (kind == "named" && opened) return { ...node, inode: node.inode + 1 };
                if (kind == "proc-size-zero") return { ...node, size: 0 };
            }
            return node;
        };
        fs.stat = (name) => {
            let node = original.stat(name);
            if (index(name, "/proc/self/fd/") == 0 && opened && node?.type == "file") {
                if (kind == "descriptor") return { ...node, inode: node.inode + 1 };
                if (kind == "proc-size-zero") return { ...node, size: 0 };
            }
            return node;
        };
        fs.open = (name, mode) => {
            let file = original.open(name, mode);
            if (name != path || file == null) return file;
            opened = true;
            return { fileno: () => file.fileno(),
                read: (limit) => { t.eq(limit, 65537); if (kind == "read") die("private-canary");
                    return kind == "oversized-read" ? sprintf("%65537s", "x") : file.read(limit); },
                error: () => kind == "error" ? "private-canary" : file.error(),
                close: () => { closed++; let result = file.close(); return kind == "close" ? false : result; } };
        };
        let result;
        let error;
        try { result = resources.collect(root); }
        catch (e) { error = e; }
        fs.open = original.open;
        fs.stat = original.stat;
        fs.lstat = original.lstat;
        if (error != null) die(error.message);
        t.eq(closed, 1);
        t.eq(has(result, "checked", "resource-memory-snapshot-read-complete"), kind == "proc-size-zero", kind);
        t.excludes(sprintf("%J", result), "private-canary");
    }
});

t.done();
