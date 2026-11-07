let t = require("t");
let stub = require("stub");
let fs = require("fs");
let apk = require("service.preflight_apk");
let preflight = require("service.preflight");

function record(name, body) {
    return "P:" + name + "\nV:1.0-r1\nA:all\nS:100\nI:100\n" + (body || "") + "\n";
}

function fixture(data) {
    let root = stub.tmpdir();
    fs.chmod(root, 0755);
    stub.real.system("umask 022; mkdir -p '" + root + "/lib/apk/db'");
    fs.writefile(root + "/lib/apk/db/installed", data);
    fs.chmod(root + "/lib/apk/db/installed", 0644);
    return root;
}

function has(result, state, reason) {
    return length(filter(result.observations, (item) => item.state == state && item.reason == reason)) > 0;
}

t.test("APK directory/file records retain ownership without executing metadata", () => {
    let data = record("base-files", "T:$(touch synthetic-secret)\nf:S\nF:\nM:0:0:755\nR:banner\na:0:0:644\nZ:Q1AAAAAAAAAAAAAAAAAAAAAAAAAAA=\nF:etc\nR:my file\n");
    t.eq(apk.parse(data), { packages: [{ name: "base-files", version: "1.0-r1", depends: "", provides: "", entries: [
        { path: "/", type: "directory" }, { path: "/banner", type: "non-directory" },
        { path: "/etc", type: "directory" }, { path: "/etc/my file", type: "non-directory" }
    ] }] });
    t.eq(apk.parse(record("empty")), { packages: [{ name: "empty", version: "1.0-r1", depends: "", provides: "", entries: [] }] });
});

t.test("APK parser refuses truncation, control bytes and unsupported fields", () => {
    for (let data in [ "", null, "P:test\n", record("test") + "\n", record("test", "T:bad\u0000data\n"),
        record("test", "T:bad\rdata\n"), record("test", "?:unsupported\n"), record("test", "e:future\n"),
        record("test", "broken\n") ])
        t.ok(apk.parse(data).error != null);
});

t.test("APK path grammar refuses traversal and aliases without normalizing them", () => {
    for (let directory in [ "/etc", "etc/", "etc//config", ".", "..", "etc/../config", "etc\tconfig" ])
        t.eq(apk.parse(record("test", "F:" + directory + "\n")).error, "apk-directory-invalid");
    for (let file in [ "", "/loki", "../loki", ".", "..", "a/b", "a\tb" ])
        t.eq(apk.parse(record("test", "F:etc\nR:" + file + "\n")).error, "apk-file-invalid");
});

t.test("APK ordering and duplicates cannot silently replace ownership", () => {
    for (let body in [ "R:loki\n", "a:0:0:644\n", "M:0:0:755\n", "Z:Q1AAAA\n",
        "F:etc\nR:loki\nR:loki\n", "F:etc\nF:etc\n", "P:other\n",
        "F:etc\nV:2\n", "F:etc\nR:loki\nM:0:0:755\n", "F:etc\nR:loki\na:0:0:644\na:0:0:644\n",
        "F:etc\nR:loki\nZ:Q1AAAA\nZ:Q1AAAA\n", "F:etc\nR:loki\nF:etc/loki\n" ])
        t.ok(apk.parse(record("test", body)).error != null);
    t.eq(apk.parse(record("test") + record("test")).error, "apk-package-duplicate");
});

t.test("APK identity, ACL and broken state failures have fixed reasons", () => {
    t.eq(apk.parse(record("../../synthetic-secret")).error, "apk-identity-invalid");
    for (let mode in [ "0:0:888", "0:-1:644", "4294967296:0:644", "0:9999999999:644", "0:0:644:bad secret", "0:0:644:Q1\t" ])
        t.eq(apk.parse(record("test", "F:etc\nM:" + mode + "\n")).error, "apk-acl-invalid");
    for (let flag in [ "f", "s", "x", "Sx", "z", "" ])
        t.eq(apk.parse(record("test", "f:" + flag + "\n")).error, "apk-broken-or-unknown-flags");
    t.eq(apk.parse(record("test", "q:-1\n")).error, "apk-number-invalid");
});

t.test("APK parser bounds bytes, lines, packages and entries", () => {
    t.eq(apk.parse(record("test", "T:" + sprintf("%4194304s", "") + "\n")).error, "apk-byte-limit");
    t.eq(apk.parse(record("test", "T:" + sprintf("%8192s", "") + "\n")).error, "apk-line-limit");
    let packages = "";
    for (let i = 0; i < 4097; i++) packages += record("test-" + i);
    t.eq(apk.parse(packages).error, "apk-package-limit");
    let files = "F:etc\n";
    for (let i = 0; i < 16384; i++) files += "R:f" + i + "\n";
    t.eq(apk.parse(record("test", files)).error, "apk-entry-limit");
});

t.test("APK collector compares exact candidate paths and does not execute PM or hooks", () => {
    let root = fixture(record("base-files", "F:etc\nR:banner\nR:loki.backup\n"));
    let path = root + "/lib/apk/db/installed";
    let before = fs.readfile(path);
    let query4 = "exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -s KILL 2 /sbin/ip -Numeric -j -4 rule list";
    let query6 = replace(query4, "-j -4", "-j -6");
    let route4 = replace(query4, "rule list", "route show table all");
    let route6 = replace(route4, "-j -4", "-j -6");
    let resources = "exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -s KILL 2 /bin/df -Pk / /tmp";
    let nft = "exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -s KILL 1 /usr/sbin/nft -j list tables";
    stub.commands([[ resources, { stdout: "Filesystem 1024-blocks Used Available Capacity Mounted on\nrootfs 1000 400 500 45% /\ntmpfs 2000 100 1900 5% /tmp\n" } ],
        [ query4, { stdout: "[]" } ], [ query6, { stdout: "[]" } ],
        [ route4, { stdout: "[]" } ], [ route6, { stdout: "[]" } ],
        [ nft, { stdout: '{"nftables":[{"metainfo":{"json_schema_version":1}}]}' } ],
        [ "exec timeout", { stdout: "{}" } ]]);
    let first = preflight.collect(root);
    let second = preflight.collect(root);
    t.eq(first, second);
    t.eq(first.result, "incomplete");
    t.eq(first.install_allowed, false);
    t.ok(has(first, "checked", "metadata-read-complete"));
    t.eq(length(filter(first.observations, (item) => item.kind == "policy-routes" && item.state == "checked" &&
        (item.object == "ipv4" || item.object == "ipv6"))), 2);
    t.eq(fs.readfile(path), before);
    t.eq(stub.command_lines(), [ "exec timeout -s KILL 5 ubus call service list {\"verbose\":true}",
        query4, query4, query6, query6, route4, route4, route6, route6, nft, nft, resources,
        "exec timeout -s KILL 5 ubus call service list {\"verbose\":true}", query4, query4, query6, query6,
        route4, route4, route6, route6, nft, nft, resources ]);
});

t.test("APK conflicting owners survive and names never establish own provenance", () => {
    let body = "F:usr/bin\nR:loki-core\n";
    let root = fixture(record("loki-core", body));
    t.ok(has(preflight.collect(root), "incomplete", "package-name-does-not-prove-own-origin"));
    fs.writefile(root + "/lib/apk/db/installed", record("loki-core", body) + record("loki", body));
    t.ok(has(preflight.collect(root), "conflict", "multiple-packages-claim-candidate-path"));
    fs.writefile(root + "/lib/apk/db/installed", record("synthetic-secret", body));
    let result = preflight.collect(root);
    t.ok(has(result, "conflict", "foreign-package-owns-candidate-path"));
    t.excludes(sprintf("%J", result), "synthetic-secret");
    t.eq(result.install_allowed, false);
});

t.test("APK directory claims cannot hide a collision with a candidate file", () => {
    let result = preflight.collect(fixture(record("foreign", "F:usr/bin/loki-core\n")));
    t.ok(has(result, "conflict", "foreign-package-owns-candidate-path"));
});

t.test("APK changed, writable and symlink databases fail closed", () => {
    let root = fixture(record("base-files"));
    let path = root + "/lib/apk/db/installed";
    let open = fs.open;
    let calls = 0;
    fs.open = (name, mode) => {
        if (name == path && ++calls == 2) fs.writefile(path, record("other"));
        return open(name, mode);
    };
    let result = preflight.collect(root);
    fs.open = open;
    t.ok(has(result, "incomplete", "apk-changed-or-unavailable-on-recheck"));
    fs.chmod(path, 0666);
    t.ok(has(preflight.collect(root), "incomplete", "apk-installed-unsafe-mode"));
    fs.rename(path, path + ".data");
    fs.symlink(path + ".data", path);
    t.ok(has(preflight.collect(root), "incomplete", "apk-installed-not-regular-file"));
});

t.test("APK dependencies retain the version and aliases from the same parsed record", () => {
    let parsed = apk.parse(record("ip-full", "D:libc kernel=6.12.1-r1\np:ip ip-full-any\n"));
    t.eq(parsed.packages[0], { name: "ip-full", version: "1.0-r1", depends: "libc kernel=6.12.1-r1",
        provides: "ip ip-full-any", entries: [] });
});

t.test("a changed APK recheck cannot grant dependency coverage", () => {
    let data = record("ucode");
    let root = fixture(data);
    let path = root + "/lib/apk/db/installed";
    let open = fs.open;
    let reads = 0;
    fs.open = (name, mode) => {
        let file = open(name, mode);
        if (name != path || file == null) return file;
        return { fileno: () => file.fileno(), error: () => file.error(), close: () => file.close(),
            read: (count) => { let text = file.read(count); return ++reads == 2 ? replace(text, "1.0-r1", "9.0-r1") : text; } };
    };
    let result;
    let error;
    try { stub.commands([[ () => true, { stdout: "{}" } ]]); result = preflight.collect(root); }
    catch (e) { error = e; }
    fs.open = open; stub.restore();
    if (error != null) die(error);
    t.eq(reads, 2);
    t.ok(has(result, "incomplete", "apk-changed-or-unavailable-on-recheck"));
    t.eq(length(filter(result.observations, (row) => row.kind == "dependencies" && row.state == "checked")), 0);
    t.eq(fs.readfile(path), data);
});


t.test("APK identity byte boundaries and repeated scans retain the same grammar", () => {
    let name = "p" + sprintf("%0127d", 0);
    let version = "1" + sprintf("%0127d", 0);
    let arch = "a" + sprintf("%063d", 0);
    let data = replace(record(name), "V:1.0-r1\nA:all", "V:" + version + "\nA:" + arch);
    let result = apk.parse(data);
    t.eq(result.packages[0].name, name);
    t.eq(result.packages[0].version, version);
    t.eq(apk.parse(data), result);
    for (let invalid in [ replace(data, "P:" + name, "P:" + name + "x"),
        replace(data, "V:" + version, "V:" + version + "1"), replace(data, "A:" + arch, "A:" + arch + "x") ])
        t.eq(apk.parse(invalid).error, "apk-identity-invalid");
});


t.test("APK number and digest byte boundaries retain their original limits", () => {
    let number = sprintf("%020d", 0);
    t.ok(apk.parse(record("test", "q:" + number + "\n")).error == null);
    t.eq(apk.parse(record("test", "q:" + number + "0\n")).error, "apk-number-invalid");
    let digest = sprintf("%0128d", 0);
    t.ok(apk.parse(record("test", "F:etc\nR:f\nZ:" + digest + "\n")).error == null);
    t.eq(apk.parse(record("test", "F:etc\nR:f\nZ:" + digest + "0\n")).error, "apk-digest-invalid");
});

t.done();
