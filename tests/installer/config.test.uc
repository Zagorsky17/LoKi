// Run the actual installer functions in an isolated directory with no real package commands.
let t = require("t");
let fs = require("fs");
let repo = require("repo");
let stub = require("stub");
let exec = require("core.exec");

const SOURCE = fs.readfile(repo.path("install.sh"));

function isolated(action, options) {
    let dir = stub.tmpdir();
    let config = dir + "/loki";
    let foreign = dir + "/foreign-state";
    fs.writefile(config, "original synthetic-secret");
    fs.chmod(config, 0600);
    fs.writefile(foreign, "foreign data");
    let source = replace(SOURCE, /\nmain "\$@"\s*$/, "\n");
    source = replace(source, /\/etc\/config\/loki/g, config);
    source = replace(source, /\/etc\/config\/loki-core/g, foreign);
    source = replace(source, /\/etc\/loki-core/g, dir + "/foreign-directory");
    let script = dir + "/test.sh";
    fs.writefile(script, source + "\n" +
        "WORK='" + dir + "' LOG='" + dir + "/log' EVENTS='" + dir + "/events'\n" +
        "NEED_LOKI=1 EXT=apk FILE_LOKI=fixture.apk\n" +
        "CHECK_STATUS=" + (options?.status ?? 0) + " PLAN='" + (options?.plan ?? "current") + "' EXTRACT_STATUS=" + (options?.extract_status ?? 0) + "\n" +
        "FOREIGN_CORES='' FOREIGN_CORE_FILES='' LEGACY_FILES='' REMOVE_FILES='' LEFTOVERS='" + foreign + "'\n" +
        "fail() { printf 'refused:%s\\n' \"$2\"; exit 17; }\n" +
        "log() { printf '%s\\n' \"$*\" >>\"$LOG\"; }\n" +
        "apk() { echo extraction >>\"$EVENTS\"; return \"$EXTRACT_STATUS\"; }\n" +
        "ucode() { echo checker >>\"$EVENTS\"; printf '{}'; return \"$CHECK_STATUS\"; }\n" +
        "jsonfilter() { case \"$2\" in '@.result') echo \"$PLAN\";; '@.from') echo 2.0.0;; '@.reason') echo foreign;; esac; }\n" +
        "refresh_db() { :; }\n" +
        "pkg_version() { [ \"$1\" != loki ] || echo 2.0.0; }\n" +
        "pkg_url() { echo '" + (options?.owner ?? "https://github.com/Zagorsky17/LoKi") + "'; }\n" +
        "uci() { echo 2.0.0; }\n" +
        "file_owner() { :; }\n" +
        "loki_status() { echo service-status >>\"$EVENTS\"; }\n" +
        action + "\necho accepted\n");
    let run = exec.combined([ "sh", script ]);
    return { ...run, config: fs.readfile(config), foreign: fs.readfile(foreign), events: fs.readfile(dir + "/events") ?? "", files: fs.lsdir(dir), dir };
}

t.test("only complete successful configuration checks permit the transaction to continue", () => {
    for (let plan in [ "current", "migrate" ]) {
        let result = isolated("check_config", { plan });
        t.eq(result.status, 0, result.output);
        t.contains(result.output, "accepted");
        t.eq(result.config, "original synthetic-secret");
    }
    for (let options in [ { status: 1, plan: "fail" }, { status: 127, plan: "" }, { plan: "reset" }, { plan: "unknown" },
        { status: 1, plan: "current" }, { plan: "current", extract_status: 1 } ]) {
        let result = isolated("check_config", options);
        t.ok(result.status != 0, sprintf("%J", options));
        t.excludes(result.output, "accepted");
        t.excludes(result.output, "synthetic-secret");
        t.eq(result.config, "original synthetic-secret");
        t.eq(result.foreign, "foreign data");
        if (options.extract_status)
            t.excludes(result.events, "checker", "a failed extraction cannot execute its contents");
    }
});

t.test("a foreign package is refused before service inspection and cannot be taken over", () => {
    for (let owner in [ "", "https://github.com/ushan0v/forkop", "https://example.invalid/other" ]) {
        let result = isolated("read_state", { owner });
        t.ok(result.status != 0, owner);
        t.excludes(result.events, "service-status");
        t.eq(result.config, "original synthetic-secret");
    }
    let own = isolated("read_state");
    t.eq(own.status, 0, own.output);
    t.contains(own.events, "service-status");
    t.excludes(SOURCE, "FORK_URL");
    t.excludes(SOURCE, "--force-downgrade");
});

t.test("legacy state is not deleted and an own backup copies rather than moves the original", () => {
    let result = isolated("remove_files; backup_config");
    t.eq(result.status, 0, result.output);
    t.eq(result.config, "original synthetic-secret");
    t.eq(result.foreign, "foreign data");
    let copies = filter(result.files, (name) => match(name, /^loki\./));
    t.eq(length(copies), 1);
    t.eq(fs.readfile(result.dir + "/" + copies[0]), result.config);
    t.eq(fs.stat(result.dir + "/" + copies[0]).mode & 0777, 0600);
    t.excludes(SOURCE, "LEGACY_FILES=");
});

t.test("setup failures name LoKi and require review of a masked report before sharing", () => {
    for (let language in [ "en", "ru" ]) {
        let result = isolated("RU=" + (language == "ru" ? "1" : "0") + "; F_VERSION=2.0.0; FILE_CORE=; FILE_APP=; FILE_I18N=; FILE_IP=; REMOVE_PKGS=; " +
            "restore_core() { :; }; repair_opkg_db() { :; }; opkg_unpacked() { return 0; }; " +
            "logread() { :; }; start_again() { :; }; fail() { printf '%s\\n' \"$@\"; exit \"$1\"; }; check_installed 1");
        t.eq(result.status, 3, result.output);
        t.contains(result.output, "LoKi 2.0.0");
        t.contains(result.output, "loki report masked");
        t.excludes(result.output, "Loki");
        t.excludes(result.output, "chat");
        t.excludes(result.output, "чат");
        t.excludes(result.output, "synthetic-secret");
        t.eq(result.config, "original synthetic-secret");
        t.eq(result.foreign, "foreign data");
    }
});

t.test("successful updates preserve unrelated conffile copies", () => {
    let result = isolated("CONFFILE_COPIES=\"$LEFTOVERS\" FILE_LOKI=''; clean_up_after");
    t.eq(result.status, 0, result.output);
    t.eq(result.foreign, "foreign data");
    t.eq(result.config, "original synthetic-secret");
});

t.test("uninstall purge preserves generic loki-core settings owned by another application", () => {
    let result = isolated("PURGE=1; DB_PHASE=0; needed_by() { :; }; may_ask() { return 1; }; " +
        "refresh_db() { DB_PHASE=$((DB_PHASE + 1)); }; pkg_version() { [ \"$DB_PHASE:$1\" != 1:loki ] || echo 2.0.0; }; " +
        "cleanup() { :; }; deadline() { :; }; perform() { :; }; find() { :; }; cp() { :; }; gone() { :; }; dropped() { :; }; uninstall");
    t.eq(result.status, 0, result.output);
    t.eq(result.foreign, "foreign data");
});

t.done();
