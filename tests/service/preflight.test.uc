let t = require("t");
let stub = require("stub");
let fs = require("fs");
let preflight = require("service.preflight");

function write(path, data) {
    fs.writefile(path, data);
    fs.chmod(path, 0644);
}

function stanza(name, state) {
    return "Package: " + name + "\nVersion: 1\nStatus: install ok " + (state || "installed") + "\n\n";
}

function fixture() {
    let root = stub.tmpdir();
    fs.chmod(root, 0755);
    stub.real.system("umask 022; mkdir -p '" + root + "/usr/lib/opkg/info' '" + root + "/lib/apk/db'");
    write(root + "/usr/lib/opkg/status", stanza("base-files"));
    write(root + "/usr/lib/opkg/info/base-files.list", "/etc/banner\n");
    return root;
}

function has(result, state, reason) {
    return length(filter(result.observations, (item) => item.state == state && item.reason == reason)) > 0;
}

t.test("status parser preserves installed packages and rejects ambiguous state", () => {
    t.eq(preflight.packages_from_status(stanza("base-files") + stanza("old", "config-files")), [ "base-files" ]);
    t.eq(preflight.packages_from_status(stanza("old", "not-installed")), []);
    for (let state in [ "half-installed", "unpacked", "installed extra", "" ])
        t.eq(preflight.packages_from_status("Package: test\nStatus: install ok " + state + "\n"), null);
    t.eq(preflight.packages_from_status("Package: base-files\nStatus: install hold installed\n"), [ "base-files" ]);
});

t.test("status parser rejects duplicate, traversing and secret-bearing identifiers", () => {
    for (let data in [ stanza("base-files") + stanza("base-files"),
        "Package: test\nPackage: other\nStatus: install ok installed\n",
        "Package: test\nStatus: install ok installed\nStatus: install ok installed\n",
        stanza("../../secret"), stanza("x;touch /tmp/secret"), stanza("s\u0000ecret"),
        "Package: test\n malformed\nStatus: install ok installed\n", " " + stanza("base-files"), "Broken", "" ])
        t.eq(preflight.packages_from_status(data), null);
});

t.test("ownership parser uses exact paths and refuses incomplete grammar", () => {
    t.eq(preflight.target_paths("/etc/config/forkop.backup\n/etc/config/podkop\n/usr/bin/sing-box\n"), [ "/usr/bin/sing-box" ]);
    for (let data in [ "", "/usr/bin/sing-box", "/etc/../usr/bin/sing-box\n", "//usr/bin/sing-box\n",
        "/usr/bin/sing-box\n/usr/bin/sing-box\n", "/etc/secret\u0000x\n", "/etc/a\r\n" ])
        t.eq(preflight.target_paths(data), null);
});

t.test("real metadata reads are bounded and refuse symlinks, hardlinks and directories", () => {
    let root = fixture();
    let path = root + "/data";
    write(path, "test");
    t.eq(preflight.read_metadata(path, 4, root).data, "test");
    t.eq(preflight.read_metadata(path, 3, root).error, "size-limit");
    fs.symlink(path, root + "/link");
    t.eq(preflight.read_metadata(root + "/link", 8, root).error, "not-regular-file");
    fs.symlink(root + "/usr/lib", root + "/parent-link");
    t.eq(preflight.read_metadata(root + "/parent-link/opkg/status", 4096, root).error, "unsafe-parent-path");
    t.eq(stub.real.system("ln '" + path + "' '" + root + "/hardlink'"), 0);
    t.eq(preflight.read_metadata(path, 8, root).error, "hardlinked-file");
    t.eq(preflight.read_metadata(root, 8, root).error, "unsafe-root");
});

t.test("inode substitution is rejected before reading data", () => {
    let root = fixture();
    let path = root + "/data";
    write(path, "first");
    write(root + "/other", "other");
    let open = fs.open;
    fs.open = (name, mode) => open(name == path ? root + "/other" : name, mode);
    let value = preflight.read_metadata(path, 8, root);
    fs.open = open;
    t.eq(value.error, "changed-during-read");
});

t.test("untrusted file and ancestor permissions refuse before open", () => {
    let root = fixture();
    let path = root + "/usr/lib/opkg/status";
    let open = fs.open;
    let opened = false;
    fs.open = (name, mode) => { opened = true; return open(name, mode); };
    fs.chmod(path, 0666);
    t.eq(preflight.read_metadata(path, 4096, root).error, "unsafe-mode");
    fs.chmod(path, 0644);
    fs.chmod(root + "/usr/lib", 0775);
    t.eq(preflight.read_metadata(path, 4096, root).error, "unsafe-parent-path");
    fs.open = open;
    t.eq(opened, false);
    fs.chmod(root + "/usr/lib", 0755);
});

t.test("real collector reports only the implemented coverage and never permits install", () => {
    let root = fixture();
    let before = fs.readfile(root + "/usr/lib/opkg/status");
    stub.commands([]);
    let result = preflight.collect(root);
    t.eq(stub.calls(), []);
    stub.restore();
    t.eq(result.result, "incomplete");
    t.eq(result.complete, false);
    t.eq(result.install_allowed, false);
    t.ok(has(result, "checked", "metadata-read-complete"));
    t.ok(has(result, "incomplete", "not-implemented"));
    t.eq(fs.readfile(root + "/usr/lib/opkg/status"), before);
    t.eq(preflight.collect(root), result, "repeat reads have identical results");
});

t.test("foreign installed owners block planned paths without reading their contents", () => {
    let root = fixture();
    write(root + "/usr/lib/opkg/status", stanza("other-core") + stanza("another-core"));
    for (let name in [ "other-core", "another-core" ])
        write(root + "/usr/lib/opkg/info/" + name + ".list", "/usr/bin/sing-box\n");
    let result = preflight.collect(root);
    t.eq(result.result, "conflict");
    t.eq(length(filter(result.observations, (item) => item.state == "conflict")), 1);
    t.eq(result.complete, false);
    t.eq(result.install_allowed, false);
    t.excludes(sprintf("%J", result), "other-core");
});

t.test("matching package names do not prove our provenance", () => {
    let root = fixture();
    write(root + "/usr/lib/opkg/status", stanza("forkop"));
    write(root + "/usr/lib/opkg/info/forkop.list", "/etc/config/forkop\n");
    let result = preflight.collect(root);
    t.eq(result.result, "incomplete");
    t.ok(has(result, "incomplete", "package-name-does-not-prove-own-origin"));
});

t.test("missing and corrupt ownership data cannot become empty coverage", () => {
    let root = fixture();
    for (let data in [ "", "/etc/banner", "/etc/../usr/bin/sing-box\n" ]) {
        write(root + "/usr/lib/opkg/info/base-files.list", data);
        t.ok(has(preflight.collect(root), "incomplete", "ownership-list-invalid"));
    }
    fs.unlink(root + "/usr/lib/opkg/info/base-files.list");
    t.ok(has(preflight.collect(root), "incomplete", "ownership-list-unavailable"));
});

t.test("proven conflicts survive other incomplete observations", () => {
    let root = fixture();
    write(root + "/usr/lib/opkg/status", stanza("base-files") + stanza("missing"));
    write(root + "/usr/lib/opkg/info/base-files.list", "/etc/config/forkop\n");
    let result = preflight.collect(root);
    t.eq(result.result, "conflict");
    t.ok(has(result, "incomplete", "ownership-list-unavailable"));
});

t.test("APK and multiple databases fail closed without package-manager execution", () => {
    let root = fixture();
    write(root + "/lib/apk/db/installed", "P:synthetic-secret\n");
    t.ok(has(preflight.collect(root), "incomplete", "multiple-package-databases"));
    fs.unlink(root + "/usr/lib/opkg/status");
    let result = preflight.collect(root);
    t.ok(has(result, "incomplete", "apk-record-termination-invalid"));
    t.excludes(sprintf("%J", result), "synthetic-secret");
});

t.test("malformed metadata never enters the report", () => {
    let root = fixture();
    write(root + "/usr/lib/opkg/status", stanza("secret; do-not-execute"));
    let result = preflight.collect(root);
    t.eq(result.result, "incomplete");
    t.excludes(sprintf("%J", result), "secret");
});

t.test("rejected input still consumes the aggregate read budget", () => {
    let root = fixture();
    let status = "";
    let body = sprintf("%1048575s", "") + "\u0000";
    for (let i = 0; i < 17; i++) {
        status += stanza("package-" + i);
        write(root + "/usr/lib/opkg/info/package-" + i + ".list", body);
    }
    write(root + "/usr/lib/opkg/status", status);
    let open = fs.open;
    let lists_opened = 0;
    fs.open = (path, mode) => {
        if (match(path, /\.list$/))
            lists_opened++;
        return open(path, mode);
    };
    let result = preflight.collect(root);
    fs.open = open;
    t.ok(has(result, "incomplete", "aggregate-byte-limit"));
    t.ok(has(result, "incomplete", "ownership-list-nul-byte"));
    t.eq(lists_opened, 15, "status recheck is reserved before opening another 1 MiB list");
});

t.test("status and ownership-list size limits have distinct reasons", () => {
    let root = fixture();
    write(root + "/usr/lib/opkg/info/base-files.list", sprintf("%1048577s", ""));
    t.ok(has(preflight.collect(root), "incomplete", "ownership-list-size-limit"));
    write(root + "/usr/lib/opkg/status", sprintf("%4194305s", ""));
    t.ok(has(preflight.collect(root), "incomplete", "status-size-limit"));
});

t.done();
