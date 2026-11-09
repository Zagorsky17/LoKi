let t = require("t");
let dependencies = require("service.preflight_dependencies");

const REQUIRED = [ "libc", "ca-bundle", "ucode", "ucode-mod-fs", "ucode-mod-resolv", "ucode-mod-socket",
    "ucode-mod-ubus", "ucode-mod-uloop", "ucode-mod-uci", "uclient-fetch", "kmod-nft-tproxy", "nftables", "kmod-nft-nat", "ip", "luci-base" ];

function record(name, depends, provides) {
    return { name, version: "1", depends: depends ?? "", provides: provides ?? "" };
}

function fixture() { return map(REQUIRED, (name) => record(name)); }
function item(packages, name) { return filter(packages, (package) => package.name == name)[0]; }
function result(packages, format, name) { return filter(dependencies.check(packages, format), (row) => row.object == name)[0]; }
function exact(name, version, format) { return format == "ipk" ? name + " (= " + version + ")" : name + "=" + version; }
function join_terms(values, format) { return join(format == "ipk" ? ", " : " ", values); }

t.test("all declared common requirements are observed independently of LoKi candidate components", () => {
    for (let format in [ "ipk", "apk" ]) {
        let rows = dependencies.check(fixture(), format);
        t.eq(length(rows), 15);
        t.eq(sort(map(rows, (row) => row.object)), sort(map(REQUIRED, (name) => name)));
        t.eq(length(filter(rows, (row) => row.state == "checked" && row.reason == "system-dependency-metadata-present")), 15);
        let missing = dependencies.check([], format);
        t.eq(length(filter(missing, (row) => row.state == "incomplete" && row.reason == "required-system-package-missing")), 15);
        t.excludes(sprintf("%J", missing), "loki-core");
    }
});

t.test("virtual ip accepts either installed variant and can use a healthy provider", () => {
    for (let format in [ "ipk", "apk" ]) {
        for (let variant in [ "ip-tiny", "ip-full" ]) {
            let packages = filter(fixture(), (package) => package.name != "ip");
            push(packages, record(variant, "", "ip"));
            t.eq(result(packages, format, "ip").state, "checked");
        }
        let packages = filter(fixture(), (package) => package.name != "ip");
        push(packages, record("ip-full", "unavailable-private-package", "ip"));
        push(packages, record("ip-tiny", "", "ip"));
        let rows = dependencies.check(packages, format);
        t.eq(filter(rows, (row) => row.object == "ip")[0].state, "checked");
        t.excludes(sprintf("%J", rows), "unavailable-private-package");
    }
});

t.test("transitive requirements, cycles and unrelated broken metadata never become a PM plan", () => {
    for (let format in [ "ipk", "apk" ]) {
        let packages = fixture();
        item(packages, "ucode").depends = "lib-a";
        push(packages, record("lib-a", "lib-b"));
        push(packages, record("lib-b", "lib-a"));
        push(packages, record("unused-private-package", "unsupported >= syntax"));
        t.eq(result(packages, format, "ucode").state, "checked");
        item(packages, "lib-b").depends = join_terms([ "lib-a", "missing-private-package" ], format);
        let rows = dependencies.check(packages, format);
        t.eq(filter(rows, (row) => row.object == "ucode")[0].reason, "required-system-dependency-missing");
        for (let private in [ "lib-a", "lib-b", "unused-private-package", "missing-private-package" ])
            t.excludes(sprintf("%J", rows), private);
        t.eq(result(packages, format, "libc").state, "checked");
    }
});

t.test("byte-identical exact versions are evidence and unreviewed comparisons stay incomplete", () => {
    for (let format in [ "ipk", "apk" ]) {
        let packages = fixture();
        item(packages, "ucode").depends = exact("lib-a", "1.0-r1", format);
        let library = record("lib-a"); library.version = "1.0-r1"; push(packages, library);
        t.eq(result(packages, format, "ucode").state, "checked");
        library.version = "1.0-r2";
        t.eq(result(packages, format, "ucode").reason, "system-dependency-version-unverified");
        library.name = "lib-a-abi"; library.provides = "lib-a"; library.version = "1.0-r1";
        t.eq(result(packages, format, "ucode").reason, "system-dependency-version-unverified");
        library.name = "lib-a"; library.provides = "";
        item(packages, "ucode").depends = format == "ipk" ? "lib-a (>= 1.0-r1)" : "lib-a>=1.0-r1";
        t.eq(result(packages, format, "ucode").reason, "system-dependency-constraint-unverified");
        item(packages, "ucode").depends = "";
        for (let value in [ null, "", true, 1, "1\u0000synthetic-private", "1 private-tail", "1\n", "1\r", "1\t", sprintf("%129s", "x") ]) {
            item(packages, "ucode").version = value;
            let row = result(packages, format, "ucode");
            t.eq(row.reason, "system-package-version-unverified");
            t.excludes(sprintf("%J", row), "synthetic-private");
        }
    }
});

t.test("malformed metadata, hidden aliases and unsupported formats never report success or private text", () => {
    for (let format in [ "ipk", "apk" ]) {
        for (let value in [ null, [], 12, "../synthetic-private", "lib-a\u0000synthetic-private", exact("lib-a", "1", format) + "\u0000synthetic-private", "lib-a | synthetic-private",
            "lib-a (", "lib-a;synthetic-private", sprintf("%8193s", "x") ]) {
            let packages = fixture(); push(packages, record("lib-a")); item(packages, "ucode").depends = value;
            let row = result(packages, format, "ucode");
            t.eq(row.state, "incomplete");
            t.excludes(sprintf("%J", row), "synthetic-private");
        }
        let packages = filter(fixture(), (package) => package.name != "ip");
        push(packages, record("private-provider", "", "bad\u0000ip"));
        let row = result(packages, format, "ip");
        t.eq(row.reason, "system-dependency-providers-unverified");
        t.excludes(sprintf("%J", row), "private-provider");
    }
    for (let format in [ null, "", "deb", "ipk\u0000synthetic-private" ]) {
        let rows = dependencies.check(fixture(), format);
        t.eq(length(filter(rows, (row) => row.state == "checked")), 0);
        t.excludes(sprintf("%J", rows), "synthetic-private");
    }
    for (let packages in [ null, {}, [ record("bad/name") ], [ record("libc\n") ], [ record("libc"), record("libc") ] ])
        t.eq(length(filter(dependencies.check(packages, "ipk"), (row) => row.state == "checked")), 0);
});

t.test("entry, term and recursion bounds stop excessive metadata and retain their exact edge", () => {
    for (let format in [ "ipk", "apk" ]) {
        let packages = fixture();
        for (let i = 15; i < 4096; i++) push(packages, record("unused-" + i));
        t.eq(result(packages, format, "ucode").state, "checked");
        push(packages, record("one-extra"));
        t.eq(length(filter(dependencies.check(packages, format), (row) => row.state == "checked")), 0);
        for (let count in [ 128, 129 ]) {
            packages = fixture(); let terms = [];
            for (let i = 0; i < count; i++) push(terms, "lib-a");
            item(packages, "ucode").depends = join_terms(terms, format);
            push(packages, record("lib-a"));
            t.eq(result(packages, format, "ucode").state, count == 128 ? "checked" : "incomplete");
        }
        for (let count in [ 63, 64 ]) {
            packages = fixture(); item(packages, "ucode").depends = "chain-0";
            for (let i = 0; i < count; i++) push(packages, record("chain-" + i, i + 1 < count ? "chain-" + (i + 1) : ""));
            t.eq(result(packages, format, "ucode").state, count == 63 ? "checked" : "incomplete");
        }
        for (let extra in [ false, true ]) {
            packages = fixture(); let outer = []; let inner = [];
            for (let i = 0; i < 127; i++) push(outer, "lib-a");
            for (let i = 0; i < 128; i++) push(inner, "lib-b");
            if (extra) push(outer, "libc");
            item(packages, "ucode").depends = join_terms(outer, format);
            push(packages, record("lib-a", join_terms(inner, format)));
            push(packages, record("lib-b"));
            let row = result(packages, format, "ucode");
            t.eq(row.state, extra ? "incomplete" : "checked");
            if (extra) t.eq(row.reason, "system-dependency-work-limit");
        }
        packages = fixture(); let aliases = [];
        for (let i = 0; i < 128; i++) push(aliases, "alias-" + i);
        for (let i = 0; i < 128; i++) push(packages, record("provider-" + i, "", join_terms(aliases, format)));
        t.eq(result(packages, format, "ucode").state, "checked");
        push(packages, record("provider-extra", "", "one-extra-alias"));
        let rows = dependencies.check(packages, format);
        t.eq(length(filter(rows, (row) => row.state == "checked")), 0);
        t.eq(rows[0].reason, "system-dependency-metadata-limit");
    }
});

t.test("explicit name and exact-version byte limits preserve the 128-byte edge", () => {
    for (let format in [ "ipk", "apk" ]) {
        for (let count in [ 128, 129 ]) {
            let name = "l"; let version = "1";
            for (let i = 1; i < count; i++) { name += "x"; version += "0"; }
            let packages = fixture();
            item(packages, "ucode").depends = exact(name, "1", format);
            push(packages, record(name));
            let rows = dependencies.check(packages, format);
            if (count == 128) t.eq(filter(rows, (row) => row.object == "ucode")[0].state, "checked");
            else t.eq(length(filter(rows, (row) => row.state == "checked")), 0);
            packages = fixture();
            item(packages, "ucode").depends = exact("library", version, format);
            let library = record("library"); library.version = version; push(packages, library);
            t.eq(result(packages, format, "ucode").state, count == 128 ? "checked" : "incomplete");
        }
    }
});

t.test("APK versioned virtual providers resolve their advertised version", () => {
    let packages = filter(fixture(), (package) => package.name != "ip");
    push(packages, { ...record("ip-tiny", "", "ip=6.18.0-r2"), version: "6.18.0-r2" });
    t.eq(result(packages, "apk", "ip").state, "checked");
    item(packages, "ucode").depends = "virtual-library=1";
    push(packages, { ...record("actual-library", "", "virtual-library=1"), version: "2" });
    t.eq(result(packages, "apk", "ucode").state, "checked", "compare the provided version, not the package version");
    item(packages, "ucode").depends = "virtual-library=2";
    t.eq(result(packages, "apk", "ucode").state, "incomplete");
    item(packages, "actual-library").provides = "virtual-library";
    t.eq(result(packages, "apk", "ucode").state, "incomplete", "an unversioned alias cannot prove an exact constraint");
    item(packages, "ucode").depends = "";
    packages = filter(packages, (package) => package.name != "ip-tiny");
    t.eq(result(packages, "apk", "ip").reason, "required-system-package-missing", "valid versioned providers do not obscure a missing dependency");
});

t.done();
