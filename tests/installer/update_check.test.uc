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

t.test("installer help is available without package or platform preparation", () => {
    let result = exec.combined([ "sh", repo.path("install.sh"), "--help", "--lang", "en" ]);
    t.eq(result.status, 0, result.output);
    t.contains(result.output, "--check");
    t.contains(result.output, "--uninstall");
});

t.test("native installation retains package verification and refuses forced file takeover", () => {
    let source = fs.readfile(repo.path("install.sh"));
    for (let name in [ "check_packages", "check_dependencies", "download_packages", "apply", "uninstall" ])
        t.contains(source, "\n" + name + "()", name);
    for (let command in [ "--force-overwrite", "--force-space", "--nodeps" ])
        t.excludes(source, command);
    t.contains(source, "/var/lock/loki-package-install.lock");
});

t.done();
