let t = require("t");
let fs = require("fs");
let repo = require("repo");
let stub = require("stub");
let exec = require("core.exec");

function parsed(args) {
    let dir = stub.tmpdir();
    let source = replace(fs.readfile(repo.path("install.sh")), /\nmain "\$@"\s*$/, "\n");
    let script = dir + "/check.sh";
    fs.writefile(script, source + "\nparse_args \"$@\"\nprintf '%s|%s|%s' \"$MODE\" \"$BAD_ARG\" \"$ASK_VARIANT\"\n");
    return exec.combined([ "sh", script, ...args ]);
}

t.test("a separate update check is explicit and cannot combine with installation actions", () => {
    t.eq(parsed([ "--check" ]).output, "check||0");
    for (let args in [ [ "--check", "--uninstall" ], [ "--uninstall", "--check" ], [ "--check", "--purge" ],
        [ "--check", "--variant", "base" ], [ "--check", "--variant" ] ])
        t.ok(parsed(args).output != "check||0", sprintf("%J", args));
});

t.test("all mutating installer entries refuse before package, download, clock, service or configuration operations", () => {
    for (let args in [ [], [ "--variant", "base" ], [ "--variant" ], [ "--uninstall" ],
        [ "--uninstall", "--purge" ], [ "--quiet" ], [ "--force" ] ]) {
        let dir = stub.tmpdir();
        let log = dir + "/existing.log";
        let events = dir + "/events";
        fs.writefile(log, "previous own log");
        fs.writefile(dir + "/openwrt_release", "DISTRIB_RELEASE='synthetic'\n");
        let source = replace(fs.readfile(repo.path("install.sh")), /\nmain "\$@"\s*$/, "\n");
        source = replace(source, /\/etc\/openwrt_release/g, dir + "/openwrt_release");
        let script = dir + "/gate.sh";
        fs.writefile(script, source + "\nLOG='" + log + "' EVENTS='" + events + "'\n" +
            "forbidden() { printf '%s\\n' \"$*\" >>\"$EVENTS\"; exit 99; }\n" +
            "id() { echo 0; }; pick_language() { RU=0; }; setup_output() { :; }\n" +
            "detect_package_manager() { forbidden package-manager; }\n" +
            "download_packages() { forbidden package-download; }; resolve_release() { forbidden metadata; }\n" +
            "apply() { forbidden apply; }; uninstall() { forbidden uninstall; }; lock() { forbidden lock; }\n" +
            "uci() { forbidden UCI; }; ntpd() { forbidden clock; }; cleanup() { :; }\n" +
            "main \"$@\"\n");
        let result = exec.combined([ "sh", script, ...args ]);
        t.ok(result.status == 1 || result.status == 2, sprintf("%J: %s", args, result.output));
        if (index(args, "--force") < 0)
            t.contains(result.output, "disabled");
        t.eq(fs.readfile(events), null);
        t.eq(fs.readfile(log), "previous own log");
    }
});

t.test("installer help is available without package or platform preparation", () => {
    let result = exec.combined([ "sh", repo.path("install.sh"), "--help", "--lang", "en" ]);
    t.eq(result.status, 0, result.output);
    t.contains(result.output, "--check");
    t.contains(result.output, "disabled");
});

t.test("the metadata checker contains no legacy package mutation implementations", () => {
    let source = fs.readfile(repo.path("install.sh"));
    for (let name in [ "apply", "uninstall", "transaction", "install_dependencies", "world_drop",
        "update_lists", "download_packages", "plan_ip_swap", "plan_removals", "stop_services", "stop_cores",
        "remove_files", "predelete_core", "restore_core", "repair_opkg_db", "drop_dependencies", "backup_config",
        "check_config", "start_loki", "start_again", "clean_up_after", "prompt", "choose_variant", "ask_translation" ])
        t.excludes(source, "\n" + name + "()", name);
    for (let command in [ "opkg install", "opkg remove", "opkg update", "apk add", "apk del", "apk update", "ntpd -n -q" ])
        t.excludes(source, command);
});

t.done();
