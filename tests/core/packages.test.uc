let t = require("t");
let stub = require("stub");
let fs = require("fs");
let packages = require("core.packages");

let dir = stub.tmpdir();
packages.paths.opkg_status = dir + "/missing-status";
packages.paths.sing_box_version = dir + "/loki-core.version";

const STATUS = "Package: libc\nVersion: 1.2.5-r4\nStatus: install ok installed\n\n" +
    "Package: loki\nVersion: 1.0.5\nDepends: libc, curl\nStatus: install user installed\n\n" +
    "Package: luci-app-passwall\nVersion: 4.0.0\nStatus: install ok not-installed\n\n" +
    "Package: zapret\nVersion: 72.20260307-r1\nStatus: install hold installed\n\n" +
    "Package: byedpi\nVersion: 0.17\nStatus: install prefer,user not-installed\n";

t.test("the opkg status file answers for installed stanzas only", () => {
    t.eq(packages.opkg_status_version(STATUS, "loki"), "1.0.5");
    t.eq(packages.opkg_status_version(STATUS, "libc"), "1.2.5-r4", "the first stanza is read");
    t.eq(packages.opkg_status_version(STATUS, "zapret"), "72.20260307-r1", "a held package is still installed");
    t.eq(packages.opkg_status_version(STATUS, "luci-app-passwall"), "", "not-installed ends in installed");
    t.eq(packages.opkg_status_version(STATUS, "byedpi"), "");
    t.eq(packages.opkg_status_version(STATUS, "absent"), "");
    t.eq(packages.opkg_status_version(STATUS, "fork"), "", "a prefix of a name is not that package");
    t.eq(packages.opkg_status_version("Package: tailpkg\nVersion: 9.9\nStatus: install ok installed", "tailpkg"), "9.9",
        "the last stanza needs no trailing blank line");
});

t.test("an opkg version is read from the status file without taking the opkg lock", () => {
    packages.paths.opkg_status = dir + "/status";
    fs.writefile(packages.paths.opkg_status, STATUS);
    stub.commands([]);
    t.eq(packages.opkg_version("zapret"), "72.20260307-r1");
    t.eq(stub.calls(), []);
    stub.restore();
    packages.paths.opkg_status = dir + "/missing-status";
});

function apk(handlers) {
    stub.commands([
        [ "sh -c command -v apk", {} ],
        [ "apk info -e", {} ],
        ...handlers,
        [ /^'apk'/, { status: 1 } ]
    ]);
}

t.test("an apk version comes from the installed list, whatever the description says", () => {
    apk([ [ "apk list --installed zapret", { stdout: "<zapret> zapret-72.20260307-r1 aarch64_cortex-a53 {feeds/base/zapret} [installed]\n" } ] ]);
    t.eq(packages.apk_version("zapret"), "72.20260307-r1");
    apk([ [ "apk info -v zapret", { stdout: "zapret: zapret\n" } ] ]);
    t.eq(packages.apk_version("zapret"), "", "a description is not a version");
    stub.restore();
});

t.test("the loki-core version is the one the core records, and only a well-formed one", () => {
    let installed = [ [ "apk list --installed loki-core", { stdout: "<loki-core> loki-core-1.14.4-r6 aarch64 {local} [installed]\n" } ] ];
    apk(installed);
    for (let recorded in [ "1.13.14-extended-2.5.3-f1", "1.13.14-extended-2.5.2-forkop.14", "1.14.4-loki.1" ]) {
        fs.writefile(packages.paths.sing_box_version, recorded + "\n");
        t.eq(packages.version("loki-core"), "", "a foreign version record is not an own build");
    }
    fs.writefile(packages.paths.sing_box_version, "1.13.14.2.5.3.1-r0\n");
    t.eq(packages.version("loki-core"), "", "a malformed record is not replaced by the package version");
    fs.unlink(packages.paths.sing_box_version);
    t.eq(packages.version("loki-core"), "1.14.4-r6", "without a record the package version answers");
    stub.restore();

    fs.writefile(packages.paths.sing_box_version, "1.14.1~rc1-extended-2.7.2-f122\n");
    t.eq(packages.sing_box_version(), "", "an unrelated fork is not an own version record");
    fs.writefile(packages.paths.sing_box_version, "garbage\n");
    t.eq(packages.sing_box_version(), "");
});

t.test("a core release records X.Y.Z-rN and a build between releases X.Y.Z-rN+K", () => {
    for (let recorded in [ "1.14.4-r1", "1.14.4-r12", "1.14.4-r1+5", "1.14.4-r0+12" ]) {
        fs.writefile(packages.paths.sing_box_version, recorded + "\n");
        t.eq(packages.sing_box_version(), recorded);
    }
    for (let recorded in [ "1.14.4-r", "1.14.4-r1+", "1.14.4-r1+5+6", "1.14.4-rc.1", "1.14.4-f.1" ]) {
        fs.writefile(packages.paths.sing_box_version, recorded + "\n");
        t.eq(packages.sing_box_version(), "", recorded);
    }
});

t.test("the variant is the one the core package records, and only a known one", () => {
    packages.paths.sing_box_variant = dir + "/loki-core.variant";
    for (let variant in [ "base", "full", "tiny", "custom" ]) {
        fs.writefile(packages.paths.sing_box_variant, variant + "\n");
        t.eq(packages.sing_box_variant(), variant);
    }
    fs.writefile(packages.paths.sing_box_variant, "nightly\n");
    t.eq(packages.sing_box_variant(), "");
    fs.unlink(packages.paths.sing_box_variant);
    t.eq(packages.sing_box_variant(), "", "a core no package installed");
});

t.done();
