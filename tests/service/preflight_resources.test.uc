let t = require("t");
let fs = require("fs");
let stub = require("stub");
let resources = require("service.preflight_resources");

// Real watchdog timing is covered by test_preflight_deadline.py; keep parser fixtures deterministic.
let query_exec = require("core.exec");
query_exec.deadline = (argv, seconds, limit) => {
    try { return query_exec.combined(argv, limit); }
    catch (e) { return { status: 1, output: "" }; }
};

const QUERY = "/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C /bin/df -Pk / /tmp";
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




t.test("BusyBox df uses Use% while reporting the same portable -Pk columns", () => {
    t.eq(resources.parse_df(replace(DISK, "Capacity", "Use%")), resources.parse_df(DISK));
});

function component(archive, unpacked) {
    return { artifact: { size: archive }, files: [ { type: "file", size: unpacked }, { type: "directory", size: 0 } ] };
}

t.test("candidate capacity includes archives, full unpacked payload and the minimum physical RAM reserve", () => {
    const MIB = 1048576;
    t.eq(resources.candidate_need([ component(1, 1) ]), { temporary_bytes: 4 * MIB, memory_bytes: 48 * MIB });
    t.eq(resources.candidate_need([ component(10 * MIB, 35 * MIB) ]), { temporary_bytes: 45 * MIB, memory_bytes: 48 * MIB });
    t.eq(resources.candidate_need([ component(30 * MIB, 20 * MIB) ]), { temporary_bytes: 60 * MIB, memory_bytes: 60 * MIB });
    t.eq(resources.candidate_need([ component(15 * MIB, 25 * MIB), component(20 * MIB, 15 * MIB) ]),
        { temporary_bytes: 75 * MIB, memory_bytes: 75 * MIB });
    for (let value in [ null, [], [ {} ], [ component(-1, 1) ], [ component("10", 1) ], [ component(1, -1) ],
        [ component(536870913, 1) ], [ component(1, 536870913) ] ])
        t.eq(resources.candidate_need(value), null);
});

t.test("20 MiB and capacity just below either boundary refuse without crediting swap", () => {
    let components = [ component(10 * 1048576, 35 * 1048576) ];
    for (let value in [ [ 20480, 46080, "resource-candidate-memory-insufficient" ], [ 49151, 46080, "resource-candidate-memory-insufficient" ],
        [ 49152, 46079, "resource-candidate-tmpfs-insufficient" ], [ 49152, 46080, "resource-candidate-capacity-checked" ] ]) {
        let root = fixture();
        fs.writefile(root + "/proc/meminfo", "MemTotal: 262144 kB\nMemAvailable: " + value[0] + " kB\nSwapTotal: 524288 kB\nSwapFree: 524288 kB\n");
        reply({ stdout: "Filesystem 1024-blocks Used Available Use% Mounted on\nprivate-device 262144 0 262144 0% /\ntmpfs 131072 0 " + value[1] + " 0% /tmp\n" });
        let rows = resources.collect(root, components); stub.restore();
        t.ok(has(rows, value[2] == "resource-candidate-capacity-checked" ? "checked" : "conflict", value[2]), value[2]);
        t.ok(has(rows, "incomplete", "resource-transaction-budget-namespace-unverified"), "memory capacity alone cannot admit an unfinished disk transaction");
    }
});

t.test("optional earlier filesystem failures cannot poison a successful memory read", () => {
    let root = fixture(); fs.lstat(root + "/absent-optional-path"); reply();
    let result = resources.collect(root); stub.restore();
    t.ok(has(result, "checked", "resource-memory-snapshot-read-complete"));
});

t.test("storage budgets distinguish staging, backup, package replacement, rollback and Start", () => {
    let candidate = [ component(1048576, 2097152) ];
    let snapshot = { bytes: 1536, archive_bytes: 45056, entries: 4, configuration_bytes: 1024, database_bytes: 2048, phase: null };
    t.eq(resources.transaction_need(candidate, null, snapshot),
        { root_bytes: 9496576, temporary_bytes: 4195840, memory_bytes: 50331648 });
    t.eq(resources.transaction_need(candidate, null, { ...snapshot, phase: "preparing" }).root_bytes, 6349824);
    t.eq(resources.transaction_need(candidate, null, { ...snapshot, phase: "prepared" }).root_bytes, 6304768);
    t.eq(resources.transaction_need(candidate, null, { ...snapshot, phase: "start" }),
        { root_bytes: 4194304, temporary_bytes: 4194304, memory_bytes: 50331648 });
    let previous = [ component(10485760, 5242880) ];
    t.eq(resources.transaction_need(candidate, previous, snapshot).temporary_bytes, 20973056);
    t.ok(resources.transaction_need(candidate, previous, snapshot).root_bytes > 9496576);
    for (let change in [ { bytes: -1 }, { archive_bytes: 100 }, { entries: 0 }, { phase: "unknown" },
        { configuration_bytes: 2097153 }, { database_bytes: 4194305 } ])
        t.eq(resources.transaction_need(candidate, null, { ...snapshot, ...change }), null);
});

t.test("measured private state and root capacity refuse before any writes or space credit", () => {
    let root = fixture();
    stub.real.system("umask 022; mkdir -p '" + root + "/tmp' '" + root + "/etc/config' '" + root + "/usr/lib/opkg'");
    fs.writefile(root + "/etc/config/loki", "private-config\n"); fs.chmod(root + "/etc/config/loki", 0600);
    fs.writefile(root + "/usr/lib/opkg/status", "metadata\n"); fs.chmod(root + "/usr/lib/opkg/status", 0644);
    fs.writefile(root + "/proc/meminfo", "MemTotal: 262144 kB\nMemAvailable: 196608 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n");
    let candidate = [ { ...component(1048576, 2097152), format: "ipk" } ];
    candidate[0].files[0].path = "/usr/bin/loki-core"; candidate[0].files[1].path = "/usr/bin";
    let context = { components: candidate, previous: null, settings: {}, phase: null, scope: { identities: {} } };
    let snapshot = require("service.update").state_tree([ root + "/etc/config/loki" ]);
    snapshot.configuration_bytes = length("private-config\n"); snapshot.database_bytes = length("metadata\n"); snapshot.phase = null;
    let need = resources.transaction_need(candidate, null, snapshot);
    let own_device = fs.stat(root).dev, temporary_device = fs.stat(root + "/tmp").dev;
    t.eq(own_device, temporary_device);
    let shared_need = need.root_bytes + need.temporary_bytes;
    for (let short in [ true, false ]) {
        let available = short ? int((shared_need - 1) / 1024) : int((shared_need + 1023) / 1024);
        reply({ stdout: "Filesystem 1024-blocks Used Available Use% Mounted on\nroot 1048576 0 " + available + " 0% /\ntmpfs 1048576 0 1048576 0% /tmp\n" });
        let result = resources.transaction(root, context); stub.restore();
        t.eq(result.state, short ? "conflict" : "checked");
        t.eq(result.reason, short ? "resource-transaction-storage-insufficient" : "resource-transaction-capacity-checked");
        t.excludes(sprintf("%J", result), "private-config");
    }
    let stat = fs.stat;
    fs.stat = (path) => {
        let node = stat(path);
        return path == root + "/tmp" ? { ...node, dev: { major: node.dev.major, minor: node.dev.minor + 1 } } : node;
    };
    reply({ stdout: "Filesystem 1024-blocks Used Available Use% Mounted on\nroot 1048576 0 " + int((need.root_bytes + 1023) / 1024) +
        " 0% /\ntmpfs 1048576 0 " + int((need.temporary_bytes + 1023) / 1024) + " 0% /tmp\n" });
    let separate, failure;
    try { separate = resources.transaction(root, context); } catch (e) { failure = e; }
    fs.stat = stat; stub.restore(); if (failure != null) die(failure);
    t.eq(separate.state, "checked", "separate filesystems retain independent reserves");
    t.eq(fs.readfile(root + "/etc/config/loki"), "private-config\n");
    t.eq(resources.transaction(root, { ...context, scope: {} }).state, "incomplete");
});

t.done();
