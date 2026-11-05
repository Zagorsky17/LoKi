let t = require("t");
let stub = require("stub");
let fs = require("fs");
let preflight = require("service.preflight");

const RULE_QUERY4 = "exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -s KILL 2 /sbin/ip -Numeric -j -4 rule list";
const RULE_QUERY6 = replace(RULE_QUERY4, "-j -4", "-j -6");
const RESOURCE_QUERY = "exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -s KILL 2 /bin/df -Pk / /tmp";
const NFT_QUERY = "exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -s KILL 1 /usr/sbin/nft -j list tables";
const NFT_JSON = '{"nftables":[{"metainfo":{"json_schema_version":1}}]}';
const RESOURCE_DF = "Filesystem 1024-blocks Used Available Capacity Mounted on\nprivate-device 1000 400 500 45% /\ntmpfs 2000 100 1900 5% /tmp\n";

function readonly_probes(service_reply) {
    return stub.commands([[ RESOURCE_QUERY, { stdout: RESOURCE_DF } ], [ RULE_QUERY4, { stdout: "[]" } ], [ RULE_QUERY6, { stdout: "[]" } ],
        [ NFT_QUERY, { stdout: NFT_JSON } ],
        [ "exec timeout", service_reply ]]);
}

function expected_probes() {
    return [ 'exec timeout -s KILL 5 ubus call service list {"verbose":true}',
        RULE_QUERY4, RULE_QUERY4, RULE_QUERY6, RULE_QUERY6, NFT_QUERY, NFT_QUERY, RESOURCE_QUERY ];
}

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
    t.eq(preflight.target_paths("/etc/config/loki.backup\n/etc/config/podkop\n/usr/bin/loki-core\n"), [ "/usr/bin/loki-core" ]);
    for (let data in [ "", "/usr/bin/loki-core", "/etc/../usr/bin/loki-core\n", "//usr/bin/loki-core\n",
        "/usr/bin/loki-core\n/usr/bin/loki-core\n", "/etc/secret\u0000x\n", "/etc/a\r\n" ])
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
    readonly_probes({ stdout: "{}" });
    let result = preflight.collect(root);
    let again = preflight.collect(root);
    t.eq(stub.command_lines(), [ ...expected_probes(), ...expected_probes() ]);
    stub.restore();
    t.eq(result.result, "incomplete");
    t.eq(result.complete, false);
    t.eq(result.install_allowed, false);
    t.ok(has(result, "checked", "metadata-read-complete"));
    t.ok(has(result, "incomplete", "not-implemented"));
    t.eq(fs.readfile(root + "/usr/lib/opkg/status"), before);
    t.eq(again, result, "repeat reads have identical results");
});

t.test("foreign installed owners block planned paths without reading their contents", () => {
    let root = fixture();
    write(root + "/usr/lib/opkg/status", stanza("other-core") + stanza("another-core"));
    for (let name in [ "other-core", "another-core" ])
        write(root + "/usr/lib/opkg/info/" + name + ".list", "/usr/bin/loki-core\n");
    let result = preflight.collect(root);
    t.eq(result.result, "conflict");
    t.eq(length(filter(result.observations, (item) => item.state == "conflict")), 1);
    t.eq(result.complete, false);
    t.eq(result.install_allowed, false);
    t.excludes(sprintf("%J", result), "other-core");
});

t.test("matching package names do not prove our provenance", () => {
    let root = fixture();
    write(root + "/usr/lib/opkg/status", stanza("loki"));
    write(root + "/usr/lib/opkg/info/loki.list", "/etc/config/loki\n");
    let result = preflight.collect(root);
    t.eq(result.result, "incomplete");
    t.ok(has(result, "incomplete", "package-name-does-not-prove-own-origin"));
});

t.test("missing and corrupt ownership data cannot become empty coverage", () => {
    let root = fixture();
    for (let data in [ "", "/etc/banner", "/etc/../usr/bin/loki-core\n" ]) {
        write(root + "/usr/lib/opkg/info/base-files.list", data);
        t.ok(has(preflight.collect(root), "incomplete", "ownership-list-invalid"));
    }
    fs.unlink(root + "/usr/lib/opkg/info/base-files.list");
    t.ok(has(preflight.collect(root), "incomplete", "ownership-list-unavailable"));
});

t.test("proven conflicts survive other incomplete observations", () => {
    let root = fixture();
    write(root + "/usr/lib/opkg/status", stanza("base-files") + stanza("missing"));
    write(root + "/usr/lib/opkg/info/base-files.list", "/etc/config/loki\n");
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

t.test("a directory at a critical file target is a conflict even without a package owner", () => {
    let root = fixture();
    stub.real.system("umask 022; mkdir -p '" + root + "/usr/bin/loki'");
    let result = preflight.collect(root);
    t.eq(result.result, "conflict");
    t.ok(has(result, "conflict", "candidate-target-type-conflict"));
    t.eq(result.install_allowed, false);
});

t.test("a candidate symlink never opens or reports its private target", () => {
    let root = fixture();
    stub.real.system("umask 022; mkdir -p '" + root + "/usr/bin'");
    let secret = root + "/synthetic-private-target";
    write(secret, "synthetic-secret-must-stay-private");
    fs.symlink(secret, root + "/usr/bin/loki");
    let open = fs.open;
    let opened = false;
    fs.open = (path, mode) => {
        if (path == secret || path == root + "/usr/bin/loki") opened = true;
        return open(path, mode);
    };
    let result = preflight.collect(root);
    fs.open = open;
    t.ok(has(result, "conflict", "candidate-path-symlink"));
    t.eq(opened, false);
    t.excludes(sprintf("%J", result), "synthetic-private-target");
    t.excludes(sprintf("%J", result), "synthetic-secret-must-stay-private");
    t.eq(fs.readfile(secret), "synthetic-secret-must-stay-private");
});

t.test("symlink and writable parent paths cannot become checked absence", () => {
    for (let kind in [ "link", "writable" ]) {
        let root = fixture();
        if (kind == "link") fs.symlink(root + "/private-parent", root + "/usr/bin");
        else {
            fs.mkdir(root + "/usr/bin", 0777);
            fs.chmod(root + "/usr/bin", 0777);
        }
        let result = preflight.collect(root);
        t.ok(has(result, "incomplete", kind == "link" ? "candidate-parent-symlink" : "candidate-parent-unsafe"));
        t.eq(result.install_allowed, false);
        t.excludes(sprintf("%J", result), "private-parent");
    }
});

t.test("unowned regular files are origin unverified and are not read or removed", () => {
    let root = fixture();
    stub.real.system("umask 022; mkdir -p '" + root + "/usr/bin'");
    let path = root + "/usr/bin/loki";
    write(path, "synthetic-private-existing-file");
    let result = preflight.collect(root);
    t.ok(has(result, "incomplete", "candidate-existing-file-origin-unverified"));
    t.eq(fs.readfile(path), "synthetic-private-existing-file");
    t.excludes(sprintf("%J", result), "synthetic-private-existing-file");
    t.eq(preflight.collect(root), result);
});

t.test("missing paths have bounded checked absence but the full installation gate stays closed", () => {
    let result = preflight.collect(fixture());
    t.ok(has(result, "checked", "candidate-path-absent"));
    t.eq(result.complete, false);
    t.eq(result.install_allowed, false);
    t.eq(result.result, "incomplete");
});

t.test("active foreign service metadata is bounded and never exposes commands or environment", () => {
    let root = fixture();
    readonly_probes({ stdout: sprintf("%J", { podkop: { instances: { main: {
        running: true, pid: 123, command: [ "synthetic-private-command", "synthetic-secret" ],
        env: { TOKEN: "synthetic-secret" }
    } } } }) });
    let result = preflight.collect(root);
    let commands = stub.command_lines();
    stub.restore();
    t.ok(has(result, "incomplete", "foreign-service-active-unverified"));
    t.eq(commands, expected_probes());
    t.excludes(sprintf("%J", result), "synthetic-secret");
    t.excludes(sprintf("%J", result), "synthetic-private-command");
    t.eq(result.install_allowed, false);
});

t.test("service query errors do not become an empty service inventory", () => {
    let root = fixture();
    readonly_probes({ status: 2, stdout: "synthetic-private-query-error" });
    let result = preflight.collect(root);
    stub.restore();
    t.ok(has(result, "incomplete", "service-query-failed"));
    t.excludes(sprintf("%J", result), "synthetic-private-query-error");
    t.eq(result.install_allowed, false);
});

t.test("enabled competing init links are inspected without executing or stopping their scripts", () => {
    let root = fixture();
    stub.real.system("umask 022; mkdir -p '" + root + "/etc/init.d' '" + root + "/etc/rc.d'");
    let script = root + "/etc/init.d/podkop";
    let marker = root + "/must-not-exist";
    write(script, "#!/bin/sh\ntouch '" + marker + "'\n");
    fs.chmod(script, 0755);
    fs.symlink("../init.d/podkop", root + "/etc/rc.d/S95podkop");
    readonly_probes({ stdout: "{}" });
    let result = preflight.collect(root);
    let commands = stub.command_lines();
    stub.restore();
    t.ok(has(result, "incomplete", "enabled-service-origin-unverified"));
    t.eq(fs.lstat(marker), null);
    t.eq(commands, expected_probes());
    t.eq(result.install_allowed, false);
});

t.test("disabled init leftovers alone are not conflicting or executed", () => {
    let root = fixture();
    stub.real.system("umask 022; mkdir -p '" + root + "/etc/init.d' '" + root + "/etc/rc.d'");
    write(root + "/etc/init.d/podkop", "synthetic-unused-init-body");
    readonly_probes({ stdout: "{}" });
    let result = preflight.collect(root);
    stub.restore();
    t.ok(has(result, "checked", "autostart-directory-read-complete"));
    t.eq(result.result, "incomplete");
    t.excludes(sprintf("%J", result), "synthetic-unused-init-body");
});

function listener_fixture(root, broken) {
    stub.real.system("umask 022; mkdir -p '" + root + "/proc/self/net'");
    for (let name in [ "tcp", "tcp6", "udp", "udp6" ]) {
        let v6 = substr(name, -1) == "6";
        let udp = substr(name, 0, 3) == "udp";
        let header = "sl local_address " + (v6 ? "remote_address" : "rem_address") +
            " st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode" + (udp ? " ref pointer drops" : "") + "\n";
        let address = v6 ? "00000000000000000000000000000000" : "00000000";
        let row = "0: " + address + ":0035 " + address + ":0000 " + (udp ? "07" : "0A") +
            " 00000000:00000000 00:00000000 00000000 0 0 12345 1 0000000000000000" + (udp ? " 0" : "") + "\n";
        write(root + "/proc/self/net/" + name, broken == name ? header + "malformed-private-row\n" : header + row);
    }
}

t.test("standalone collector includes all four bounded listener snapshots", () => {
    let root = fixture();
    listener_fixture(root);
    readonly_probes({ stdout: "{}" });
    let result = preflight.collect(root);
    stub.restore();
    t.eq(length(filter(result.observations, (item) => item.kind == "listeners" &&
        item.reason == "listener-table-read-complete")), 4);
    t.ok(has(result, "incomplete", "listener-candidate-port-occupied-unverified"));
    t.eq(result.install_allowed, false);
});

t.test("a malformed socket table is incomplete rather than an empty listener inventory", () => {
    let root = fixture();
    listener_fixture(root, "udp6");
    readonly_probes({ stdout: "{}" });
    let result = preflight.collect(root);
    stub.restore();
    t.ok(has(result, "incomplete", "listener-table-row-invalid"));
    t.excludes(sprintf("%J", result), "malformed-private-row");
    t.eq(result.complete, false);
});

t.test("socket discovery keeps mandatory ownership and namespace gaps", () => {
    let root = fixture();
    listener_fixture(root);
    readonly_probes({ stdout: "{}" });
    let result = preflight.collect(root);
    stub.restore();
    t.ok(has(result, "incomplete", "listener-process-ownership-unverified"));
    t.ok(has(result, "incomplete", "listener-namespace-and-bind-configuration-unverified"));
});

t.test("process discovery reports unreadable procfs instead of granting installation", () => {
    let root = fixture();
    readonly_probes({ stdout: "{}" });
    let result = preflight.collect(root);
    stub.restore();
    t.ok(has(result, "incomplete", "process-directory-unavailable"));
    t.eq(result.complete, false);
    t.eq(result.install_allowed, false);
});

t.test("an empty fixture procfs cannot prove system process or script coverage", () => {
    let root = fixture();
    fs.mkdir(root + "/proc", 0755);
    readonly_probes({ stdout: "{}" });
    let result = preflight.collect(root);
    stub.restore();
    t.ok(has(result, "checked", "process-directory-read-complete"));
    t.ok(has(result, "incomplete", "process-namespace-and-visibility-unverified"));
    t.ok(has(result, "incomplete", "process-script-and-package-origin-unverified"));
    t.eq(result.complete, false);
    t.eq(result.install_allowed, false);
});

t.test("policy rule snapshots cover both families and retain mandatory ownership gaps", () => {
    let root = fixture();
    stub.commands([
        [ (argv) => index(argv, "/sbin/ip") >= 0, { stdout: "[]\n" } ],
        [ (argv) => index(argv, "/usr/sbin/nft") >= 0, { stdout: NFT_JSON } ],
        [ "exec timeout", { stdout: "{}" } ]
    ]);
    let result = preflight.collect(root);
    stub.restore();
    t.eq(length(filter(result.observations, (item) => item.reason == "policy-rule-snapshot-read-complete")), 2);
    t.ok(has(result, "incomplete", "policy-rules-ownership-configuration-unverified"));
    t.ok(has(result, "incomplete", "policy-routes-and-namespace-unverified"));
    t.eq(result.complete, false);
    t.eq(result.install_allowed, false);
});

t.test("ambiguous policy rule JSON is incomplete and never exposes raw private values", () => {
    let root = fixture();
    stub.commands([
        [ (argv) => index(argv, "/sbin/ip") >= 0,
          { stdout: '[{"priority":105,"src":"all","table":"105","fwmark":"0x4000000","fwmark":"0x100000"}]' } ],
        [ (argv) => index(argv, "/usr/sbin/nft") >= 0, { stdout: NFT_JSON } ],
        [ "exec timeout", { stdout: "{}" } ]
    ]);
    let result = preflight.collect(root);
    stub.restore();
    t.ok(has(result, "incomplete", "policy-rule-json-invalid"));
    t.excludes(sprintf("%J", result), "0x100000");
    t.eq(result.install_allowed, false);
});

t.test("resource observations distinguish readable snapshots from unverified transaction budgets", () => {
    let root = fixture();
    readonly_probes({ stdout: "{}" });
    let result = preflight.collect(root);
    t.ok(has(result, "incomplete", "resource-memory-unavailable"));
    t.ok(has(result, "checked", "resource-filesystem-snapshot-read-complete"));
    t.ok(has(result, "incomplete", "resource-transaction-budget-namespace-unverified"));
    t.eq([ result.result, result.complete, result.install_allowed ], [ "incomplete", false, false ]);
    t.excludes(sprintf("%J", result), "private-device");
    t.eq(stub.command_lines(), expected_probes());
});

t.done();
