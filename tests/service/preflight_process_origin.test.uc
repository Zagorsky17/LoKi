let t = require("t"), fs = require("fs"), stub = require("stub");
let processes = require("service.preflight_processes");
function stat() {
    let fields = [ "S" ];
    for (let i = 1; i < 50; i++) push(fields, i == 19 ? "12345" : "0");
    return "42 (synthetic-private) " + join(" ", fields) + "\n";
}
function fixture(target) {
    let root = stub.tmpdir(); fs.chmod(root, 0755);
    stub.real.system("umask 022; mkdir -p '" + root + "/proc/42' '" + root + "/bin' '" + root + "/sbin' '" + root + "/usr/bin' '" + root + "/usr/sbin'");
    fs.writefile(root + "/proc/42/stat", stat()); fs.chmod(root + "/proc/42/stat", 0644);
    fs.writefile(root + target, "synthetic-private-binary"); fs.chmod(root + target, 0755);
    fs.symlink(root + target, root + "/proc/42/exe");
    return root;
}
function proof(target, name) { return { system: true, complete: true, claims: { [target]: [name] }, own_files: {} }; }
function origin(root, provenance) {
    let rows = processes.collect(root, { identities: {} }, provenance);
    t.excludes(sprintf("%J", rows), "synthetic-private"); t.excludes(sprintf("%J", rows), root);
    return filter(rows, (row) => row.object == "origin")[0];
}

t.test("supported protected executables require an exclusive matching package owner", () => {
    for (let pair in [ [ "/sbin/procd", "procd" ], [ "/sbin/ubusd", "ubusd" ], [ "/bin/busybox", "busybox" ], [ "/usr/bin/ucode", "ucode" ], [ "/usr/sbin/odhcp6c", "odhcp6c" ], [ "/usr/sbin/pppd", "ppp" ] ]) {
        let root = fixture(pair[0]), provenance = proof(pair[0], pair[1]);
        t.eq(origin(root, provenance).state, "checked", pair[0]);
        for (let change in [ { system: false }, { complete: false }, { claims: {} },
            { claims: { [pair[0]]: [ pair[1], "other" ] } }, { claims: { [pair[0]]: [ "other" ] } } ])
            t.eq(origin(root, { ...provenance, ...change }).state, "incomplete");
        if (pair[0] == "/bin/busybox") { fs.chmod(root + pair[0], 04755); t.eq(origin(root, provenance).state, "checked"); }
        fs.chmod(root + pair[0], 0777); t.eq(origin(root, provenance).state, "incomplete");
    }
});

t.test("a name alone, unsafe alias or different executable inode cannot borrow package origin", () => {
    let target = "/usr/bin/procd", root = fixture(target);
    t.eq(origin(root, proof(target, "procd")).state, "incomplete", "only the supported target is accepted");
    root = fixture("/sbin/procd");
    fs.rename(root + "/sbin/procd", root + "/sbin/saved");
    fs.writefile(root + "/sbin/procd", "replacement"); fs.chmod(root + "/sbin/procd", 0755);
    fs.unlink(root + "/proc/42/exe"); fs.symlink(root + "/sbin/saved", root + "/proc/42/exe");
    t.eq(origin(root, proof("/sbin/procd", "procd")).state, "incomplete");
    let stat = fs.stat;
    fs.unlink(root + "/proc/42/exe"); fs.symlink(root + "/sbin/procd", root + "/proc/42/exe");
    fs.stat = (path) => path == root + "/proc/42/exe" ? stat(root + "/sbin/saved") : stat(path);
    let result, failure;
    try { result = origin(root, proof("/sbin/procd", "procd")); } catch (e) { failure = e; }
    fs.stat = stat; if (failure != null) die(failure);
    t.eq(result.state, "incomplete", "a matching path string cannot substitute for the executable inode");
    fs.unlink(root + "/sbin/procd"); fs.symlink(root + "/sbin/saved", root + "/sbin/procd");
    t.eq(origin(root, proof("/sbin/procd", "procd")).state, "incomplete");
});

t.test("the own core executable needs the already verified installed file and matching package claim", () => {
    let target = "/usr/bin/loki-core", root = fixture(target), provenance = proof(target, "loki-core");
    t.eq(origin(root, provenance).state, "incomplete");
    provenance.own_files[target] = { path: target, type: "file", mode: 0755, size: fs.lstat(root + target).size,
        package: "loki-core", version: "1", sha256: sprintf("%064d", 1) };
    t.eq(origin(root, provenance).state, "checked");
    provenance.claims[target] = [ "other" ]; t.eq(origin(root, provenance).state, "incomplete");
});

t.done();
