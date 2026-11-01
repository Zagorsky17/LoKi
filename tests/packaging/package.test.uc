// Modified for LoKi on 2026-10-31: keep application downloads in the project repository.
// The backend package is built by the feed Makefile and by build.sh, each with its own
// dependency lists, layout and hooks; these checks hold the copies to each other.

let t = require("t");
let fs = require("fs");
let repo = require("repo");
let constants = require("core.constants");
let singbox_constants = require("singbox.constants");
let cli = require("service.cli");

const MAKEFILE = fs.readfile(repo.path("forkop/Makefile"));
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
    t.fail("forkop/Makefile has no " + name);
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
    t.eq(constants.FORKOP_RELEASE_REPO, "Zagorsky17/LoKi");
    let installer_repo = match(fs.readfile(repo.path("install.sh")), /\nFORKOP_REPO=([^\n]+)\n/);
    t.eq(installer_repo ? installer_repo[1] : null, constants.FORKOP_RELEASE_REPO);
    let core_repo = match(fs.readfile(repo.path("install.sh")), /\nCORE_REPO=([^\n]+)\n/);
    t.eq(core_repo ? core_repo[1] : null, constants.FORKOP_RELEASE_REPO);
    t.eq(build_sh_variable("PROJECT_URL"), "https://github.com/" + constants.FORKOP_RELEASE_REPO);
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
    t.eq(sorted(without_libc(words(build_sh_variable("BACKEND_DEPENDS_APK")))),
        sorted(map(makefile_depends, (name) => name == "ip-tiny" ? "ip" : name)), "APK, where ip-tiny is the ip any iproute2 provides");
});

t.test("every native ucode module the library loads is a dependency", () => {
    let pipe = fs.popen("grep -rhoE 'require\\(\"[a-z]+\"\\)' '" + repo.path("forkop/files/usr/lib") + "'", "r");
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
        fs.readfile(repo.path("forkop/files/etc/init.d/forkop")),
        fs.readfile(repo.path("luci-app-forkop/root/etc/uci-defaults/50_luci-forkop"))
    ];
    let names = [];
    for (let source in sources)
        for (let call in match(source, /(\/usr\/bin\/forkop|"\$FORKOP_BIN") ([a-z_]+)/g) ?? [])
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
            if (index(line, "forkop package_postinst") >= 0) {
                calls++;
                t.contains(line, "FORKOP_BYTECODE_VALIDATION_TTL=0 /usr/bin/forkop package_postinst");
                t.contains(previous + line, "/usr/lib/forkop/config/migration.uc migrate");
            }
            previous = line;
        }
    }
    t.eq(calls, 4, "the feed postinst, the IPK postinst and the two APK upgrade paths");
});

t.test("both packagers install the reset configuration and the fw4 include", () => {
    t.contains(MAKEFILE, "./files/etc/config/forkop $(1)/usr/share/forkop/default-config");
    t.contains(BUILD_SH, "forkop/files/etc/config/forkop\" \"$output_root/usr/share/forkop/default-config\"");
    t.contains(MAKEFILE, "./files/usr/share/nftables.d/chain-pre/input/forkop.nft $(1)/usr/share/nftables.d/chain-pre/input/forkop.nft");
    t.contains(BUILD_SH, "\"$output_root/usr/share/nftables.d/chain-pre/input/forkop.nft\"");
});

t.test("a sysupgrade keeps the Tailscale identities, which no UCI option holds", () => {
    t.eq(fs.readfile(repo.path("forkop/files/lib/upgrade/keep.d/forkop")), "/etc/forkop/\n");
    t.contains(MAKEFILE, "./files/lib/upgrade/keep.d/forkop $(1)/lib/upgrade/keep.d/forkop");
    t.contains(BUILD_SH, "\"$output_root/lib/upgrade/keep.d/forkop\"");
});

t.test("both packagers stamp the release into the files that carry the placeholder", () => {
    t.eq(constants.FORKOP_VERSION, "__COMPILED_VERSION_VARIABLE__");
    t.contains(MAKEFILE, "s/__COMPILED_VERSION_VARIABLE__/$(FORKOP_COMPILED_VERSION)/g' $(1)/usr/lib/forkop/core/constants.uc");
    t.contains(BUILD_SH, "\"$output_root/usr/lib/forkop/core/constants.uc\"");
    t.contains(fs.readfile(repo.path("luci-app-forkop/htdocs/luci-static/resources/view/forkop/main.js")), "__COMPILED_VERSION_VARIABLE__");
    t.contains(BUILD_SH, "\"$output_root/www/luci-static/resources/view/forkop/main.js\"");
});

t.test("the fw4 input include accepts the traffic Forkop marks and the DNS it redirects", () => {
    let include = fs.readfile(repo.path("forkop/files/usr/share/nftables.d/chain-pre/input/forkop.nft"));
    t.contains(include, "meta mark & " + constants.NFT_FAKEIP_MARK + " == " + constants.NFT_FAKEIP_MARK);
    t.contains(include, "ct status dnat meta l4proto { tcp, udp } th dport " + singbox_constants.SOURCE_DNS_INBOUND_PORT);
});

t.test("the init script starts at the priority the autostart link is named after", () => {
    t.contains(lines(fs.readfile(repo.path("forkop/files/etc/init.d/forkop"))), "START=" + constants.FORKOP_START_PRIORITY);
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

t.done();
