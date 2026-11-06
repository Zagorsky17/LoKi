// Modified for LoKi on 2026-10-31: keep application downloads in the project repository.
// The backend package is built by the feed Makefile and by build.sh, each with its own
// dependency lists, layout and hooks; these checks hold the copies to each other.

let t = require("t");
let fs = require("fs");
let repo = require("repo");
let constants = require("core.constants");
let singbox_constants = require("singbox.constants");
let cli = require("service.cli");
let stub = require("stub");
let exec = require("core.exec");

const MAKEFILE = fs.readfile(repo.path("loki/Makefile"));
const BUILD_SH = fs.readfile(repo.path("build.sh"));

function lines(text) {
    return split(text, "\n");
}

// `\tNAME:=value` in the Makefile's package definition.
function makefile_field(name) {
    for (let line in lines(MAKEFILE)) {
        let found = match(line, regexp("^\\s+" + name + ":=(.*)$"));
        if (found)
            return found[1];
    }
    t.fail("loki/Makefile has no " + name);
}

// `NAME="value"` at the top of build.sh.
function build_sh_variable(name) {
    for (let line in lines(BUILD_SH)) {
        let found = match(line, regexp("^" + name + "=\"([^\"]*)\"$"));
        if (found)
            return found[1];
    }
    t.fail("build.sh has no " + name);
}

// The names a list holds, without the version an IPK `name (>= v)` or an APK `name>=v` sets.
function words(value) {
    value = replace(value, /\([^)]*\)/g, "");
    return filter(map(split(trim(value), /[ ,]+/), (word) => replace(word, /[<>=~].*$/, "")), (word) => word != "");
}

function sorted(list) {
    return sort(uniq(list));
}

t.test("application installer, updater and packages use the LoKi repository", () => {
    t.eq(constants.LOKI_RELEASE_REPO, "Zagorsky17/LoKi");
    let installer_repo = match(fs.readfile(repo.path("install.sh")), /\nLOKI_REPO=([^\n]+)\n/);
    t.eq(installer_repo ? installer_repo[1] : null, constants.LOKI_RELEASE_REPO);
    let core_repo = match(fs.readfile(repo.path("install.sh")), /\nCORE_REPO=([^\n]+)\n/);
    t.eq(core_repo ? core_repo[1] : null, constants.LOKI_RELEASE_REPO);
    t.eq(build_sh_variable("PROJECT_URL"), "https://github.com/" + constants.LOKI_RELEASE_REPO);
    t.eq(makefile_field("URL"), build_sh_variable("PROJECT_URL"));
});

t.test("the package requires the core version built with the bootstrap fix", () => {
    let version = match(fs.readfile(repo.path("core/upstream.env")), /\nCORE_VERSION=([^\n]+)\n/);
    t.eq(version ? version[1] : null, constants.SB_REQUIRED_VERSION);
    t.contains(fs.readfile(repo.path("install.sh")), "asset=core-release.json");
});

let makefile_depends = sorted(map(words(makefile_field("DEPENDS")), (word) => ltrim(word, "+")));

// OpenWrt adds libc to every package itself; the standalone packages spell it.
function without_libc(list) {
    return filter(list, (name) => name != "libc");
}

t.test("the IPK and APK packages depend on what the feed package depends on", () => {
    t.ok(length(makefile_depends) > 0);
    t.eq(sorted(without_libc(words(build_sh_variable("BACKEND_DEPENDS_IPK")))), makefile_depends, "IPK");
    t.eq(sorted(without_libc(words(build_sh_variable("BACKEND_DEPENDS_APK")))), makefile_depends, "APK");
});

t.test("packages accept the installed ip provider without selecting a replacement variant", () => {
    for (let dependencies in [ makefile_depends, words(build_sh_variable("BACKEND_DEPENDS_IPK")),
        words(build_sh_variable("BACKEND_DEPENDS_APK")) ]) {
        t.contains(dependencies, "ip");
        t.excludes(dependencies, "ip-tiny");
        t.excludes(dependencies, "ip-full");
    }
});

t.test("every native ucode module the library loads is a dependency", () => {
    let pipe = fs.popen("grep -rhoE 'require\\(\"[a-z]+\"\\)' '" + repo.path("loki/files/usr/lib") + "'", "r");
    let found = pipe.read("all");
    pipe.close();
    let modules = sorted(map(split(trim(found), "\n"), (call) => match(call, /"([a-z]+)"/)[1]));
    t.ok(length(modules) > 0);
    for (let module in modules)
        t.contains(makefile_depends, "ucode-mod-" + module, module);
});

// A name the command line lacks prints the usage and fails, which a package script ignores.
t.test("every command a package hook or an init script runs is one the command line has", () => {
    let sources = [
        MAKEFILE, BUILD_SH,
        fs.readfile(repo.path("loki/files/etc/init.d/loki")),
        fs.readfile(repo.path("luci-app-loki/Makefile"))
    ];
    let names = [];
    for (let source in sources)
        for (let call in match(source, /(\/usr\/bin\/loki|"\$LOKI_BIN") ([a-z_]+)/g) ?? [])
            push(names, call[2]);
    names = sorted(names);
    for (let hook in [ "package_prerm", "package_postinst", "luci_prerm", "luci_postinst", "initd_start", "initd_reload" ])
        t.contains(names, hook, "found the hooks");
    for (let name in names)
        t.ok(cli.COMMANDS[name] != null, name + " is not a command");
});

// A command just before postinst leaves a fresh validation stamp, which would run the old
// release's hooks from the old bytecode.
t.test("every postinst migrates the configuration, then runs its hook with the cache revalidated", () => {
    let calls = 0;
    for (let source in [ MAKEFILE, BUILD_SH ]) {
        let previous = "";
        for (let line in lines(source)) {
            if (index(line, "loki package_postinst") >= 0) {
                calls++;
                t.contains(line, "LOKI_BYTECODE_VALIDATION_TTL=0 /usr/bin/loki package_postinst");
                t.contains(previous + line, "/usr/lib/loki/config/migration.uc migrate");
            }
            previous = line;
        }
    }
    t.eq(calls, 4, "the feed postinst, the IPK postinst and the two APK upgrade paths");
});

t.test("both packagers install the reset configuration and the fw4 include", () => {
    t.contains(MAKEFILE, "./files/etc/config/loki $(1)/usr/share/loki/default-config");
    t.contains(BUILD_SH, "loki/files/etc/config/loki\" \"$output_root/usr/share/loki/default-config\"");
    t.contains(MAKEFILE, "./files/usr/share/nftables.d/chain-pre/input/loki.nft $(1)/usr/share/nftables.d/chain-pre/input/loki.nft");
    t.contains(BUILD_SH, "\"$output_root/usr/share/nftables.d/chain-pre/input/loki.nft\"");
});

t.test("a sysupgrade keeps the Tailscale identities, which no UCI option holds", () => {
    t.eq(fs.readfile(repo.path("loki/files/lib/upgrade/keep.d/loki")), "/etc/loki/\n");
    t.contains(MAKEFILE, "./files/lib/upgrade/keep.d/loki $(1)/lib/upgrade/keep.d/loki");
    t.contains(BUILD_SH, "\"$output_root/lib/upgrade/keep.d/loki\"");
});

t.test("both packagers stamp the release into the files that carry the placeholder", () => {
    t.eq(constants.LOKI_VERSION, "__COMPILED_VERSION_VARIABLE__");
    t.contains(MAKEFILE, "s/__COMPILED_VERSION_VARIABLE__/$(LOKI_COMPILED_VERSION)/g' $(1)/usr/lib/loki/core/constants.uc");
    t.contains(BUILD_SH, "\"$output_root/usr/lib/loki/core/constants.uc\"");
    t.contains(fs.readfile(repo.path("luci-app-loki/htdocs/luci-static/resources/view/loki/main.js")), "__COMPILED_VERSION_VARIABLE__");
    t.contains(BUILD_SH, "\"$output_root/www/luci-static/resources/view/loki/main.js\"");
});

t.test("the fw4 input include accepts the traffic Loki marks and the DNS it redirects", () => {
    let include = fs.readfile(repo.path("loki/files/usr/share/nftables.d/chain-pre/input/loki.nft"));
    t.contains(include, "meta mark & " + constants.NFT_FAKEIP_MARK + " == " + constants.NFT_FAKEIP_MARK);
    t.contains(include, "ct status dnat meta l4proto { tcp, udp } th dport " + singbox_constants.SOURCE_DNS_INBOUND_PORT);
});

t.test("the init script starts at the priority the autostart link is named after", () => {
    t.contains(lines(fs.readfile(repo.path("loki/files/etc/init.d/loki"))), "START=" + constants.LOKI_START_PRIORITY);
});

t.test("build.sh explains itself and refuses a malformed version before building", () => {
    let run = (args) => {
        let pipe = fs.popen("bash '" + repo.path("build.sh") + "' " + args + " 2>&1", "r");
        let output = pipe.read("all");
        return { status: pipe.close(), output };
    };
    let help = run("--help");
    t.eq(help.status, 0);
    t.contains(help.output, "Usage");
    let malformed = run("1.2");
    t.ok(malformed.status != 0);
    t.contains(malformed.output, "x.y.z");
});

t.test("retired tunnel modules and commands cannot enter the packages", () => {
    for (let path in [ "singbox/tailscale.uc", "singbox/amnezia.uc" ])
        t.eq(fs.stat(repo.path("loki/files/usr/lib/" + path)), null, path);
    t.eq(cli.COMMANDS.generate_warp_profile, null);
    let bundle = fs.readfile(repo.path("luci-app-loki/htdocs/luci-static/resources/view/loki/main.js"));
    for (let entry in [ "generate_warp_profile", "/tailscale", "showTailscaleDetailsModal", "parseWireGuardConfig", "parseOpenVPNConfig", "parseOpenConnectConfig" ])
        t.excludes(bundle, entry);
});

t.test("project documentation cannot publish an inherited GitHub Pages site", () => {
    t.eq(fs.stat(repo.path("docs")), null, "only the product READMEs remain");
    t.eq(fs.stat(repo.path(".github/workflows/docs.yml")), null);
    for (let name in fs.lsdir(repo.path(".github/workflows")) ?? []) {
        if (!match(name, /\.ya?ml$/))
            continue;
        let workflow = fs.readfile(repo.path(".github/workflows/" + name));
        t.excludes(workflow, "actions/deploy-pages@", name);
        t.excludes(workflow, "actions/upload-pages-artifact@", name);
        t.eq(match(workflow, /pages[ \t]*:[ \t]*write/), null, name + " cannot write Pages");
    }
});

t.test("packages contain only LoKi's configuration migration framework", () => {
    for (let name in [ "v1_0_5", "v2_0_0", "url_1_0_5" ])
        t.eq(fs.stat(repo.path("loki/files/usr/lib/config/migrations/" + name + ".uc")), null);
    let source = fs.readfile(repo.path("loki/files/usr/lib/config/migration.uc"));
    for (let entry in [ "remove_leftovers", "after_commit", "migrate-fixture", "keep_aside", "config.migrations.v2_0_0" ])
        t.excludes(source, entry);
    let defaults = fs.readfile(repo.path("loki/files/etc/config/loki"));
    t.contains(defaults, "option config_format 'loki'");
    t.eq(require("config.migration").MIN_CONFIG_VERSION, "2.0.0");
    for (let name in fs.lsdir(repo.path("tests/fixtures")))
        t.eq(match(name, /^loki-1\.0\..*\.conf$/), null);
});

t.test("LoKi menu labels retain the technical route and permission identifiers", () => {
    let menu = json(fs.readfile(repo.path("luci-app-loki/root/usr/share/luci/menu.d/luci-app-loki.json")));
    t.eq(keys(menu), [ "admin/services/loki" ]);
    t.eq(menu["admin/services/loki"].title, "LoKi");
    t.eq(menu["admin/services/loki"].action.path, "loki/loki");
    t.eq(menu["admin/services/loki"].depends.acl, [ "luci-app-loki" ]);
    let acl = json(fs.readfile(repo.path("luci-app-loki/root/usr/share/rpcd/acl.d/luci-app-loki.json")));
    t.eq(keys(acl), [ "luci-app-loki" ]);
    t.contains(acl["luci-app-loki"].description, "LoKi");
    t.eq(acl["luci-app-loki"].write.uci.loki, [ "read", "write" ]);
    t.eq(acl["luci-app-loki"].read.file, null);
});

t.test("the RPC implementation and the local resolver replace the executable reader", () => {
    t.eq(fs.stat(repo.path("loki/files/usr/bin/loki-read")), null);
    t.excludes(BUILD_SH, 'loki-read');
    t.excludes(MAKEFILE, 'loki-read');
    t.contains(MAKEFILE, '$(INSTALL_DATA) ../install.sh $(1)/usr/share/loki/install.sh');
    t.contains(BUILD_SH, 'install -m 0644 "$ROOT_DIR/install.sh" "$output_root/usr/share/loki/install.sh"');
    t.contains(fs.readfile(repo.path("loki/files/usr/lib/service/lifecycle.uc")), '"/usr/share/loki/install.sh"');
    t.excludes(fs.readfile(repo.path("loki/files/usr/lib/service/lifecycle.uc")), '"/usr/bin/loki-read"');
});

t.test("the actual backend root includes trusted RPC and the installed resolver", () => {
    let dir = stub.tmpdir();
    let start = index(BUILD_SH, "\nmake_dir() {");
    let end = index(BUILD_SH, "\nbuild_app_root() {");
    t.ok(start >= 0 && end > start);
    let script = dir + "/root.sh";
    fs.writefile(script, "set -euo pipefail\n" + substr(BUILD_SH, start, end - start) +
        '\nROOT_DIR=$1 RELEASE_VERSION=2.0.0; build_backend_root "$2"\n');
    let root = dir + "/root";
    let run = exec.combined([ "bash", script, repo.root, root ]);
    t.eq(run.status, 0, run.output);
    t.eq(fs.stat(root + "/usr/bin/loki-read"), null);
    t.eq(fs.readfile(root + "/usr/lib/loki/service/rpc.uc"), fs.readfile(repo.path("loki/files/usr/lib/service/rpc.uc")));
    t.eq(fs.stat(root + "/usr/share/loki/install.sh").mode & 0777, 0644);
    t.eq(fs.readfile(root + "/usr/share/loki/install.sh"), fs.readfile(repo.path("install.sh")));
});

// Evaluate the real initializers only: package/network actions lie after this boundary.
function sdk_initializers(overrides) {
    let exec = require("core.exec");
    let boundary = index(BUILD_SH, "\nBACKEND_DESCRIPTION=");
    t.ok(boundary > 0, "the initializer boundary exists before any package action");
    let dir = trim(exec.output([ "mktemp", "-d" ]) ?? "");
    t.ok(dir != "", "a private test directory was created");
    let script = dir + "/settings.sh";
    let prefix = substr(BUILD_SH, 0, boundary);
    fs.writefile(script, prefix + "\nprintf '%s\\n' \"$IPK_SDK_URL\" \"$APK_SDK_URL\" \"$SDK_CACHE_DIR\" \"$SDK_DIR\" \"$BUILD_DIR\"\n");
    let argv = [ "env", "-u", "IPK_SDK_URL", "-u", "APK_SDK_URL", "-u", "SDK_CACHE_DIR", "-u", "SDK_DIR", "-u", "BUILD_DIR", "XDG_CACHE_HOME=" + dir + "/cache" ];
    for (let name in keys(overrides))
        push(argv, name + "=" + overrides[name]);
    push(argv, "bash", script, "2.0.0", dir + "/unused-output");
    let result = exec.capture(argv);
    let output_created = fs.stat(dir + "/unused-output") != null;
    fs.unlink(script);
    fs.rmdir(dir);
    t.eq(result.status, 0, "initializer evaluation succeeded");
    t.eq(output_created, false, "no build directory or packages were created");
    let values = split(trim(result.stdout), "\n");
    t.eq(length(values), 5);
    return { ipk: values[0], apk: values[1], cache: values[2], sdk: values[3], build: values[4] };
}

function official_sdk(url, version, gcc) {
    let found = match(url, /^https:\/\/downloads\.openwrt\.org\/releases\/([^/]+)\/targets\/x86\/64\/openwrt-sdk-([^_]+)_gcc-([^_]+)_musl\.Linux-x86_64\.tar\.zst$/);
    t.ok(found != null, "an official Linux x86_64 SDK for target x86/64 is selected");
    t.eq(found[1], version, "release directory");
    t.eq(found[2], version + "-x86-64", "archive version and target agree");
    t.eq(found[3], gcc, "the pinned toolchain is retained");
}

t.test("SDK defaults select current releases with matching archives and target toolchains", () => {
    let defaults = sdk_initializers({});
    official_sdk(defaults.ipk, "24.10.8", "13.3.0");
    official_sdk(defaults.apk, "25.12.6", "14.3.0");
    t.eq(defaults.sdk, defaults.cache + "/extracted", "the cache and extracted directory remain coupled by default");
    t.contains(defaults.cache, "/cache/loki/openwrt-sdk");
    t.contains(defaults.build, "/cache/loki/build");
    let empty = sdk_initializers({ IPK_SDK_URL: "", APK_SDK_URL: "" });
    t.eq(empty.ipk, defaults.ipk, "an empty override retains the default");
    t.eq(empty.apk, defaults.apk);
});

t.test("SDK URL overrides are independent literal values and retain isolated build paths", () => {
    let defaults = sdk_initializers({});
    let custom_ipk = "https://example.invalid/ipk $(printf literal); 'quoted'.tar.zst";
    let custom_apk = "https://example.invalid/apk?part=one&part=two";
    let ipk_only = sdk_initializers({ IPK_SDK_URL: custom_ipk });
    t.eq(ipk_only.ipk, custom_ipk, "shell punctuation is data, without re-evaluation");
    t.eq(ipk_only.apk, defaults.apk, "the other package format keeps its default");
    let apk_only = sdk_initializers({ APK_SDK_URL: custom_apk });
    t.eq(apk_only.ipk, defaults.ipk);
    t.eq(apk_only.apk, custom_apk);
    let isolated = sdk_initializers({ IPK_SDK_URL: custom_ipk, APK_SDK_URL: custom_apk,
        SDK_CACHE_DIR: "/tmp/sdk cache fixture", SDK_DIR: "/tmp/sdk extracted fixture", BUILD_DIR: "/tmp/sdk build fixture" });
    t.eq(isolated.ipk, custom_ipk);
    t.eq(isolated.apk, custom_apk);
    t.eq(isolated.cache, "/tmp/sdk cache fixture");
    t.eq(isolated.sdk, "/tmp/sdk extracted fixture");
    t.eq(isolated.build, "/tmp/sdk build fixture");
});

t.done();
