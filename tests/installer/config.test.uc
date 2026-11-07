// Removed mutation helpers cannot bypass the read-only installer boundary.
let t = require("t");
let fs = require("fs");
let repo = require("repo");
let stub = require("stub");
let exec = require("core.exec");

const SOURCE = fs.readfile(repo.path("install.sh"));

function isolated(action, owner) {
    let dir = stub.tmpdir();
    let config = dir + "/loki";
    let foreign = dir + "/foreign-state";
    let copy = dir + "/loki-core.conffile-copy";
    for (let path in [ config, foreign, copy ]) {
        fs.writefile(path, path == config ? "original synthetic-secret" : "foreign data");
        fs.chmod(path, 0600);
    }
    let source = replace(SOURCE, /\nmain "\$@"\s*$/, "\n");
    source = replace(source, /\/etc\/config\/loki/g, config);
    let script = dir + "/test.sh";
    fs.writefile(script, source + "\n" +
        "MODE=check WORK='" + dir + "' LOG='" + dir + "/log' EVENTS='" + dir + "/events'\n" +
        "fail() { printf 'refused:%s\\n' \"$2\"; exit 17; }\n" +
        "forbidden() { printf '%s\\n' \"$*\" >>\"$EVENTS\"; exit 99; }\n" +
        "apk() { forbidden apk; }; opkg() { forbidden opkg; }; ntpd() { forbidden clock; }\n" +
        "rm() { forbidden remove; }; cp() { forbidden copy; }; mv() { forbidden move; }; touch() { forbidden touch; }\n" +
        "loki_status() { forbidden service; }; refresh_db() { :; }; file_owner() { :; }\n" +
        "pkg_version() { [ \"$1\" != loki ] || echo 2.0.0; }\n" +
        "pkg_url() { echo '" + (owner ?? "https://github.com/Zagorsky17/LoKi") + "'; }\n" +
        "uci() { echo 2.0.0; }; pick_language() { RU=0; }; setup_output() { :; }\n" +
        "FOREIGN_CORES='' FOREIGN_CORE_FILES=''\n" + action + "\n");
    let run = exec.combined([ "sh", script ]);
    return { ...run, config: fs.readfile(config), foreign: fs.readfile(foreign), copy: fs.readfile(copy),
        mode: fs.stat(config).mode & 0777, events: fs.readfile(dir + "/events") ?? "", dir };
}

function preserved(result) {
    t.eq(result.config, "original synthetic-secret");
    t.eq(result.foreign, "foreign data");
    t.eq(result.copy, "foreign data");
    t.eq(result.mode, 0600);
    t.eq(result.events, "");
    t.excludes(result.output, "synthetic-secret");
}

t.test("a foreign package is refused before further metadata inspection and cannot be taken over", () => {
    for (let owner in [ "", "https://github.com/ushan0v/forkop", "https://example.invalid/other" ]) {
        let result = isolated("read_state", owner);
        t.ok(result.status != 0, owner);
        preserved(result);
    }
    let own = isolated("read_state");
    t.eq(own.status, 0, own.output);
    preserved(own);
    for (let value in [ "FORK_URL", "LEGACY_FILES=", "--force-downgrade" ]) t.excludes(SOURCE, value);
});

t.test("deleted extraction, backup and transaction helpers are absent from the shell namespace", () => {
    let result = isolated("for name in check_config backup_config remove_files clean_up_after check_installed uninstall apply transaction; do\n" +
        "if command -v \"$name\" >/dev/null 2>&1; then forbidden \"$name\"; fi\ndone\n:");
    t.eq(result.status, 0, result.output);
    preserved(result);
});

t.test("legacy mutation options preserve own config, foreign state and unrelated conffile copies", () => {
    for (let args in [ [], [ "--variant", "base" ], [ "--uninstall" ], [ "--uninstall", "--purge" ] ]) {
        let result = isolated("MODE=install; " + exec.command_line([ "main", ...args ]));
        t.ok(result.status == 1 || result.status == 2, result.output);
        t.contains(result.output, "disabled");
        preserved(result);
    }
});

t.test("rejected variant input cannot become a shell command or reach configuration helpers", () => {
    for (let value in [ "base; touch injected-marker", "$(touch injected-marker)", "../synthetic-secret" ]) {
        let result = isolated("MODE=install; " + exec.command_line([ "main", "--variant", value ]));
        t.eq(result.status, 2, result.output);
        t.eq(fs.stat(result.dir + "/injected-marker"), null);
        preserved(result);
    }
});

t.done();
