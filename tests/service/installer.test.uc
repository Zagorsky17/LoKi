// Modified for LoKi on 2026-11-01: use project releases and wait for the test process to start.
let t = require("t");
let stub = require("stub");
let fs = require("fs");
let ubus = require("ubus");
let uloop = require("uloop");
let common = require("core.common");
let installer = require("service.installer");
let commands = stub.commands;
stub.commands = (handlers) => commands([ ...handlers, [ "logger", {} ] ]);

let me = common.own_pid();
const MIRROR = "https://10.0.2.2:18090";

// The run's directory, and the system's files beside it in a directory of their own.
function fresh() {
    let dir = stub.tmpdir();
    fs.chmod(dir, 0700);
    let system = stub.tmpdir();
    installer.paths.state = dir + "/state.json";
    installer.paths.candidate = dir + "/candidate";
    require("service.update").paths.state = dir + "/update/state.json";
    installer.paths.output = dir + "/output";
    installer.paths.script = dir + "/install.sh";
    installer.paths.local_script = system + "/install.sh";
    fs.writefile(installer.paths.local_script, "#!/bin/sh\nexit 0\n");
    fs.chmod(installer.paths.local_script, 0644);
    installer.paths.manifest = dir + "/release.json";
    installer.paths.sums = dir + "/SHA256SUMS";
    installer.paths.listing = dir + "/listing.json";
    installer.paths.start_lock = dir + "/start.lock";
    installer.paths.install_lock = dir + "/install.lock";
    let ui = require("service.ui");
    ui.paths.service_action_lock = dir + "/service.lock";
    ui.paths.service_actions = dir + "/service-actions";
    ui.paths.reload_lock = dir + "/reload.lock";
    installer.paths.cli = system + "/loki";
    installer.paths.proc = system + "/proc";
    installer.paths.install_log = system + "/loki-install.log";
    installer.paths.ptmx = "/dev/ptmx";
    installer.paths.package_databases = [ system + "/installed" ];
    fs.writefile(system + "/installed", "loki 2.0.0\n");
    fs.writefile(installer.paths.cli, "");
    fs.mkdir(installer.paths.proc);
    return dir;
}

// How a process treats SIGINT, as /proc/PID/status shows it: SIGINT is bit 1 of each mask.
function sigint(pid, disposition) {
    let mask = (set) => set ? "0000000000000002" : "0000000000000000";
    fs.mkdir(installer.paths.proc + "/" + pid);
    fs.writefile(installer.paths.proc + "/" + pid + "/status", "Name:\tsh\nSigBlk:\t0000000000000000\nSigIgn:\t" +
        mask(disposition == "ignored") + "\nSigCgt:\t" + mask(disposition == "caught") + "\n");
}

function state() {
    return common.read_json_file(installer.paths.state);
}

function write_state(value) {
    fs.writefile(installer.paths.state, sprintf("%J", {
        schema: 1, id: "run-1", action: "update", variant: null, purge: false, lang: "ru", interactive: true,
        starter_pid: null, runner_pid: null, child_pid: null, started_at: common.now_seconds(), finished_at: null,
        exit: null, changed: false, interrupted: false, ...value
    }));
}

// The child reports its own PID after exec, before closing the pipe; ':' keeps its command line stable.
function live_process(marker) {
    let pipe = stub.real.popen("sh -c 'echo $$; exec >/dev/null 2>&1; sleep 30; :' " + marker + " &", "r");
    let pid = trim(pipe.read("all"));
    pipe.close();
    return pid;
}

function kill(pid) {
    stub.real.system("kill " + pid + " 2>/dev/null");
}

// The bytes of a UTF-8 text, cut where wanted: ucode versions disagree on what "\xd0" means.
let cyrillic = "ж";
let euro = "€";
let emoji = "😀";

function real_sha() {
    return [ "sha256sum", (argv, command) => {
        let pipe = stub.real.popen(command, "r");
        let stdout = pipe.read("all");
        return { stdout, status: pipe.close() };
    } ];
}

t.test("the page learns when the run began and ended, and whether install.sh left this run's log", () => {
    fresh();
    let now = common.now_seconds();
    write_state({ child_pid: "4242", started_at: now - 30, finished_at: now, exit: 0 });
    t.eq([ installer.status(0).started_at, installer.status(0).finished_at, installer.status(0).log ], [ now - 30, now, false ]);
    fs.writefile(installer.paths.install_log, "install.sh --lang ru --quiet\n");
    fs.chmod(installer.paths.install_log, 0600);
    t.eq(installer.status(0).log, true);
    write_state({ child_pid: null, started_at: now - 30, finished_at: now, exit: 1 });
    t.eq(installer.status(0).log, false, "a run that never started install.sh");
    write_state({ child_pid: "4242", started_at: now + 3600, finished_at: now + 3600, exit: 0 });
    t.eq(installer.status(0).log, false, "the log of an earlier install.sh");
});

t.test("the command line prints install.sh's log, and says when there is none", () => {
    fresh();
    fs.writefile(installer.paths.install_log, "$ apk add loki.apk\nOK: 83.7 MiB in 199 packages\n");
    fs.chmod(installer.paths.install_log, 0600);
    let printed = stub.capture(() => require("service.cli").main([ "installer_log" ], "/lib"));
    t.eq([ printed.result, printed.stdout ], [ 0, "$ apk add loki.apk\nOK: 83.7 MiB in 199 packages\n" ]);
    fs.unlink(installer.paths.install_log);
    let missing = stub.capture(() => require("service.cli").main([ "installer_log" ], "/lib"));
    t.eq([ missing.result, missing.stderr ], [ 1, "install.sh has left no log\n" ]);
});

t.test("install.sh gets the language and --quiet, then what the run does; a bare --variant goes last", () => {
    t.eq(installer.install_arguments("update", "", false, "ru"), [ "--lang", "ru", "--quiet" ]);
    t.eq(installer.install_arguments("variant", "", false, "en"), [ "--lang", "en", "--quiet", "--variant" ]);
    t.eq(installer.install_arguments("variant", "tiny", false, "ru"), [ "--lang", "ru", "--quiet", "--variant", "tiny" ]);
    t.eq(installer.install_arguments("uninstall", "", false, "ru"), [ "--lang", "ru", "--quiet", "--uninstall" ]);
    t.eq(installer.install_arguments("uninstall", "", true, "ru"), [ "--lang", "ru", "--quiet", "--uninstall", "--purge" ]);
});

t.test("a run that may ask takes the terminal as its controlling one, a removal takes none", () => {
    let asking = installer.child_script(true);
    let silent = installer.child_script(false);
    t.contains(asking, "setsid -c /bin/sh \"$@\" <\"$tty\" >\"$tty\" 2>&1");
    t.contains(silent, "setsid /bin/sh \"$@\" </dev/null >\"$tty\" 2>&1");
    t.excludes(silent, "setsid -c");
    for (let script in [ asking, silent ])
        t.contains(script, "eval \"exec $fd<&-\"", "every descriptor ucode leaves open is closed");
    t.contains(installer.pump_script(7), "[ \"$fd\" != 7 ]", "the pump keeps the terminal it reads");
    t.contains(installer.pump_script(7), "exec cat <&7 >>\"$0\"");
    t.excludes(installer.pump_script(7), "head", "nothing holds the output back in a buffer");
    t.contains(installer.drain_script(7), "exec cat <&7 >/dev/null", "past the limit the terminal is still read");
    t.contains(installer.drain_script(7), "[ \"$fd\" != 7 ]");
});

t.test("a read hands over whole UTF-8 characters only", () => {
    t.eq(installer.whole_characters("ab"), 2);
    t.eq(installer.whole_characters("a" + cyrillic), 1 + length(cyrillic));
    t.eq(installer.whole_characters("a" + substr(cyrillic, 0, 1)), 1, "a two-byte character cut after its first byte");
    t.eq(installer.whole_characters("a" + substr(euro, 0, 2)), 1, "a three-byte character cut after two");
    t.eq(installer.whole_characters("a" + substr(emoji, 0, 3)), 1, "a four-byte character cut after three");
    t.eq(installer.whole_characters("a" + emoji), 1 + length(emoji));
    t.eq(installer.whole_characters(""), 0);
});

t.test("the latest release comes through GitHub's API, or from a mirror at github.com's release paths", () => {
    t.eq(installer.listing_url(), "https://api.github.com/repos/Zagorsky17/LoKi/releases/latest");
    let listing = "{\"assets\":[{\"name\":\"release.json\",\"url\":\"https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/2\"}," +
        "{\"name\":\"install.sh\",\"url\":\"https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/1\"}]}";
    t.eq(installer.asset_url(listing, "install.sh"), "https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/1");
    t.eq(installer.asset_url(listing, "SHA256SUMS"), null, "a file the release has not got");
    t.eq([ installer.asset_url("{\"message\":\"Not Found\"}", "install.sh"), installer.asset_url(null, "install.sh") ], [ null, null ]);
    t.eq([ installer.rate_limited("{\"resources\":{\"core\":{\"remaining\":0}}}"),
        installer.rate_limited("{\"resources\":{\"core\":{\"remaining\":12}}}"), installer.rate_limited(null) ], [ true, false, false ]);
    stub.env({ LOKI_DOWNLOAD_URL: MIRROR });
    t.eq(installer.release_url("release.json"), MIRROR + "/Zagorsky17/LoKi/releases/latest/download/release.json");
    stub.restore();
    t.eq(installer.url_host(MIRROR + "/Zagorsky17/LoKi"), "10.0.2.2");
    t.eq(installer.url_host("https://api.github.com"), "api.github.com");
});

t.test("a release that installs only from a console names its command", () => {
    t.eq(installer.install_command("{\"version\":\"3.0.0\",\"install_command\":\" sh <(wget -O - x) --y \"}"),
        { command: "sh <(wget -O - x) --y", version: "3.0.0" });
    t.eq(installer.install_command("{\"version\":\"2.0.1\"}"), null);
    t.eq(installer.install_command("{\"install_command\":\"  \"}"), null);
    t.eq(installer.install_command("not json"), null);
    t.eq(installer.install_command(null), null);
});

t.test("the terminal's number is read in the processor's byte order", () => {
    t.eq(installer.unsigned("\u0003\u0001\u0000\u0000", true), 259);
    t.eq(installer.unsigned("\u0000\u0000\u0001\u0003", false), 259);
});

t.test("the page reads the run's output from where it stopped", () => {
    fresh();
    write_state({ runner_pid: me });
    fs.writefile(installer.paths.output, "[*] " + cyrillic + "\r\n" + substr(euro, 0, 2));
    let all = installer.snapshot(installer.read_state(), 0);
    t.eq([ all.id, all.action, all.interactive, all.running, all.exit, all.offset ], [ "run-1", "update", true, true, null, 0 ]);
    t.eq(all.data, "[*] " + cyrillic + "\r\n", "the cut character waits for the next read");
    t.eq(all.next, length(all.data));
    let rest = installer.snapshot(installer.read_state(), all.next);
    t.eq([ rest.data, rest.next ], [ "", all.next ]);
    t.eq(installer.snapshot(installer.read_state(), 10000).data, "", "an offset past the end");
    t.eq(installer.snapshot(null, 0), { id: "", running: false }, "no run yet");
});

t.test("a run whose processes all died is recorded as interrupted, one with a live process goes on", () => {
    fresh();
    write_state({ runner_pid: "999999", child_pid: "999998" });
    let settled = installer.current();
    t.eq([ settled.interrupted, settled.finished_at != null, installer.active() ], [ true, true, false ]);
    t.eq(state().interrupted, true, "the record says so for the next reader");

    let runner = live_process("installer_run");
    write_state({ runner_pid: runner });
    t.eq(installer.active(), true, "a runner alive");
    kill(runner);

    let reused = live_process("something_else");
    write_state({ runner_pid: reused });
    t.eq(installer.active(), false, "a pid the kernel gave to another process");
    kill(reused);

    let starter = live_process("installer_start");
    write_state({ starter_pid: starter });
    t.eq(installer.active(), true, "the CLI that started the run waits for its runner");
    kill(starter);
});

t.test("a start launches the runner, and a start while a run goes on follows that run", () => {
    fresh();
    let launched = [];
    stub.commands([ real_sha(),
        [ /installer_run/, (argv) => {
            push(launched, argv[length(argv) - 1]);
            let current = state();
            fs.writefile(installer.paths.state, sprintf("%J", { ...current, runner_pid: me }));
            return { stdout: me + "\n" };
        } ]
    ]);
    let started = installer.start("check", "", "0", "ru");
    t.eq(started.started, true);
    t.eq(launched, [ started.id ]);
    t.eq([ state().action, state().variant, state().purge, state().interactive, state().lang ], [ "check", null, false, false, "ru" ]);
    t.eq(fs.readfile(installer.paths.output), "", "a new run starts with an empty terminal");

    let runner = live_process("installer_run");
    fs.writefile(installer.paths.state, sprintf("%J", { ...state(), runner_pid: runner }));
    let again = installer.start("check", "", "0", "ru");
    t.eq(again, { id: started.id, started: false });
    t.eq(length(launched), 1, "no second runner");
    kill(runner);
    stub.restore();
});

t.test("a start with what install.sh does not take is refused", () => {
    fresh();
    t.contains(t.throws(() => installer.start("dance", "", "0", "ru")).message, "Invalid installer run");
    t.contains(t.throws(() => installer.start("update", "full", "0", "ru")).message, "Invalid installer run", "a build only with variant");
    t.contains(t.throws(() => installer.start("variant", "huge", "0", "ru")).message, "Invalid installer run");
    t.contains(t.throws(() => installer.start("update", "", "0", "de")).message, "Invalid installer run");
    t.eq(state(), null, "nothing recorded");
});

t.test("a runner that never records itself leaves an interrupted run", () => {
    fresh();
    stub.commands([ real_sha(), [ /installer_run/, { stdout: "999999\n" } ] ]);
    t.contains(t.throws(() => installer.start("check", "", "0", "ru")).message, "The installer did not start");
    stub.restore();
    t.eq([ state().interrupted, state().finished_at != null ], [ true, true ]);
});

// Runs the runner over a recorded run; `steps` are what happens while its loop runs. The run
// downloads from a mirror, or through GitHub's API when `source` is "api".
function run_with(value, steps, source) {
    fresh();
    write_state(value);
    ubus.__reset();
    uloop.__reset();
    stub.env({ LOKI_DOWNLOAD_URL: source == "api" ? null : MIRROR });
    let result = { status: null };
    uloop.__on_run(() => { fs.writefile(installer.paths.script, "#!/bin/sh\nexit 0\n"); steps(result); });
    let original_lstat = fs.lstat;
    {
        fs.chmod(installer.paths.local_script, value.local_mode ?? 0644);
        // Model package permissions independently of the test user's umask.
        fs.chmod(common.parent_dir(installer.paths.local_script), value.local_directory_mode ?? 0755);
        if (value.local_missing)
            fs.unlink(installer.paths.local_script);
        // Root ownership is synthetic; no test writes to the host's package directory.
        fs.lstat = (path) => {
            let stat = original_lstat(path);
            return stat != null && (path == installer.paths.local_script || path == common.parent_dir(installer.paths.local_script)) ? { ...stat, uid: 0 } : stat;
        };
    }
    try { result.status = installer.run(value.id ?? "run-1"); }
    catch (error) { fs.lstat = original_lstat; die(error.message); }
    fs.lstat = original_lstat;
    stub.env({});
    return result;
}

function read(offset) {
    return ubus.__invoke("loki.installer", "read", { offset }).replied;
}

// The timers set so far fire once each, and those they set wait for the next call.
function fire_once() {
    let due = filter(uloop.__timers(), (entry) => !entry.cancelled && entry.kind == "timer");
    for (let entry in due) {
        entry.cancelled = true;
        entry.callback();
    }
    return length(due);
}

t.test("a stop interrupts install.sh's whole session as Ctrl+C does, once its trap and session exist", () => {
    let killed = [];
    let seen = {};
    let refusals = 1;
    stub.commands([ real_sha(), [ "kill", (argv) => { push(killed, join(" ", argv)); return { status: refusals-- > 0 ? 1 : 0 }; } ] ]);
    run_with({ action: "check", interactive: false }, () => {
        seen.stop = ubus.__invoke("loki.installer", "stop", { id: "run-1" }).replied;
        seen.early = length(killed);
        sigint(40001, "default");
        fire_once();
        seen.untrapped = length(killed);
        sigint(40001, "caught");
        fire_once();
        fire_once();
        uloop.__exit(1, 1);
        seen.late = ubus.__invoke("loki.installer", "stop", { id: "run-1" }).replied;
        uloop.__exit(0, 0);
        uloop.__fire("timer");
    });
    stub.restore();
    t.eq(seen.stop, { accepted: true });
    t.eq([ seen.early, seen.untrapped ], [ 0, 0 ], "nothing before install.sh traps SIGINT");
    t.eq(killed, [ "kill -INT -- -40001", "kill -INT -- -40001" ], "sent again while the session did not exist yet");
    t.eq(seen.late, { accepted: false }, "nothing to stop once install.sh is gone");
    t.eq([ state().exit, state().stop_requested ], [ 1, true ]);
});

t.test("a checker ignoring SIGINT is not sent a destructive signal", () => {
    let killed = [];
    let seen = {};
    stub.commands([ real_sha(), [ "kill", (argv) => { push(killed, join(" ", argv)); return { status: 0 }; } ] ]);
    run_with({ action: "check", interactive: false }, () => {
        sigint(40001, "ignored");
        seen.stop = ubus.__invoke("loki.installer", "stop", { id: "run-1" }).replied;
        seen.retries = fire_once();
        uloop.__exit(1, 0);
        uloop.__exit(0, 0);
        uloop.__fire("timer");
    });
    stub.restore();
    t.eq([ seen.stop, seen.retries ], [ { accepted: true }, 0 ]);
    t.eq(killed, [], "nothing reaches the package manager");
    t.eq([ state().exit, state().stop_requested ], [ 1, true ]);
});

t.test("a terminal that never lets go is left after a while, and the run ends", () => {
    let killed = [];
    stub.commands([ real_sha(), [ "kill", (argv) => { push(killed, join(" ", argv)); return { status: 0 }; } ] ]);
    run_with({ action: "check", interactive: false }, () => {
        uloop.__exit(1, 0);
        uloop.__fire("timer");
        uloop.__fire("timer");
    });
    stub.restore();
    t.eq(killed, [ "kill -- -40000" ], "the pump's whole session");
    t.eq(state().exit, 1);
});

t.test("past the output limit the terminal is read into nothing, and that reader ends the run", () => {
    let killed = [];
    stub.commands([ real_sha(), [ "kill", (argv) => { push(killed, join(" ", argv)); return { status: 0 }; } ] ]);
    run_with({ action: "check", interactive: false }, () => {
        uloop.__fire("interval");
        t.eq(length(uloop.__processes()), 2, "nothing to cap yet");
        fs.writefile(installer.paths.output, sprintf("%" + (installer.OUTPUT_LIMIT + 1) + "s", ""));
        uloop.__fire("interval");
        let reader = uloop.__processes()[2];
        t.eq([ reader.executable, reader.args[3] ], [ "setsid", installer.paths.output ]);
        t.contains(reader.args[2], ">/dev/null");
        uloop.__fire("interval");
        t.eq(length(uloop.__processes()), 3, "capped once");
        uloop.__exit(0, -15);
        uloop.__exit(1, 0);
        t.eq(state().finished_at, null, "the pump it replaced does not end the run");
        uloop.__exit(2, 1);
        uloop.__fire("timer");
    });
    stub.restore();
    t.eq(killed, [ "kill -- -40000" ]);
    t.eq(state().exit, 1);
});

t.test("a run another one is not is left alone", () => {
    fresh();
    write_state({ id: "run-2" });
    t.eq(installer.run("run-1"), 1);
    write_state({ finished_at: common.now_seconds(), exit: 0 });
    t.eq(installer.run("run-1"), 1, "a finished run");
});

t.test("release validation still rejects malformed manifests and modified bytes behind the apply gate", () => {
    let manifest = { schema: 1, name: "loki", version: "2.0.1", tag: "2.0.1", requires: { "loki-core": "1.14.4-r4" } };
    t.eq(installer.valid_manifest(sprintf("%J", manifest)), true);
    for (let value in [ null, "not json", "{}", sprintf("%J", { ...manifest, schema: 2 }),
        sprintf("%J", { ...manifest, name: "other" }), sprintf("%J", { ...manifest, version: "2.0.1; id" }),
        sprintf("%J", { ...manifest, requires: {} }), sprintf("%J", { ...manifest, tag: "../../other" }) ])
        t.eq(installer.valid_manifest(value), false);
    fresh();
    fs.writefile(installer.paths.script, "#!/bin/sh\nexit 0\n");
    let pipe = stub.real.popen("sha256sum '" + installer.paths.script + "'", "r");
    let digest = split(pipe.read("all"), " ")[0];
    pipe.close();
    t.eq(installer.verified_file(installer.paths.script, "install.sh", digest + "  install.sh\n"), true);
    fs.writefile(installer.paths.script, "#!/bin/sh\necho modified\n");
    t.eq(installer.verified_file(installer.paths.script, "install.sh", digest + "  install.sh\n"), false);
});

t.test("release asset URLs cannot leave the fixed HTTPS LoKi API namespace", () => {
    for (let url in [ "http://api.github.com/repos/Zagorsky17/LoKi/releases/assets/1", "https://elsewhere.invalid/asset", "file:///etc/passwd",
        "https://api.github.com/repos/other/project/releases/assets/1", "https://api.github.com@elsewhere.invalid/asset",
        "https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/1?token=synthetic-secret" ])
        t.eq(installer.asset_url(sprintf("%J", { assets: [ { name: "install.sh", url } ] }), "install.sh"), null);
});

t.test("checks are noninteractive and retain a structured result without package reload", () => {
    t.eq(installer.install_arguments("check", "", false, "en"), [ "--lang", "en", "--quiet", "--check" ]);
    let result = { schema: 1, success: true, available: false, installed: { app: "2.0.0", core: "1.14.4-r3", variant: "base" },
        latest: { app: "2.0.0", core: "1.14.4-r3" } };
    run_with({ action: "check", interactive: false }, () => {
        t.eq(length(uloop.__processes()), 2);
        t.eq(length(filter(uloop.__processes(), (process) => process.executable == "uclient-fetch")), 0);
        t.contains(join(" ", uloop.__processes()[1].args), "--check");
        fs.writefile(installer.paths.output, sprintf("%J\n", result));
        fs.writefile(installer.paths.package_databases[0], "changed elsewhere");
        uloop.__exit(1, 0);
        uloop.__exit(0, 0);
    });
    t.eq([ state().exit, state().changed, state().check_result ], [ 0, false, result ]);
    for (let output in [ "", "not json", "{\"schema\":1,\"success\":true,\"available\":false}", sprintf("%J\n%J", result, result) ])
        t.eq(installer.parse_update_result(output), null, output);
    t.eq(installer.parse_update_result('{"schema":1,"success":false,"reason":"network"}'), { schema: 1, success: false, reason: "network" });
});

t.test("a live SSH installer or service job excludes another LuCI installer start", () => {
    fresh();
    let lock = require("service.lock");
    lock.acquire(installer.paths.install_lock, me);
    t.eq(installer.active(), true);
    t.contains(t.throws(() => installer.start("check", "", "0", "en")).message, "running");
    t.eq(state(), null);
    lock.release(installer.paths.install_lock, me);
    let ui = require("service.ui");
    common.ensure_dir(ui.paths.service_actions);
    fs.writefile(ui.paths.service_actions + "/busy.json", sprintf("%J", { action: "reload", running: true, pid: me, started_at: common.now_seconds() }));
    t.contains(t.throws(() => installer.start("check", "", "0", "ru")).message, "running");
    t.eq(state(), null);
});

t.test("bootstrap SHA entries and asset names are unique and canonical", () => {
    fresh();
    fs.writefile(installer.paths.script, "#!/bin/sh\nexit 0\n");
    let pipe = stub.real.popen("sha256sum '" + installer.paths.script + "'", "r");
    let digest = split(pipe.read("all"), " ")[0];
    pipe.close();
    let valid = digest + "  install.sh\n";
    t.eq(installer.verified_file(installer.paths.script, "install.sh", valid), true);
    for (let sums in [ "", valid + valid, digest + "  install.sh extra\n", "nothex  install.sh\n", digest + "  other.sh\n" ])
        t.eq(installer.verified_file(installer.paths.script, "install.sh", sums), false, sums);
    let asset = { name: "install.sh", url: "https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/1" };
    t.eq(installer.asset_url(sprintf("%J", { assets: [ asset, asset ] }), "install.sh"), null);
});

t.test("every action refuses an unsafe installed script without remote fallback", () => {
    for (let action in [ "check", "update", "uninstall" ])
    for (let options in [ { local_missing: true }, { local_mode: 0666 }, { local_directory_mode: 0775 } ]) {
        run_with({ action, interactive: false, ...options }, () => {
            t.eq(length(uloop.__processes()), 0);
        });
        t.eq(state().exit, 1);
        if (action == "check") t.eq(state().check_result.success, false);
    }
    let file = { type: "file", uid: 0, mode: 0644, size: 100 };
    let directory = { type: "directory", uid: 0, mode: 0755 };
    t.eq(installer.protected_checker(file, directory), true);
    for (let change in [ { uid: 1000 }, { mode: 0664 }, { type: "link" }, { size: 0 }, { size: 524289 } ])
        t.eq(installer.protected_checker({ ...file, ...change }, directory), false);
    for (let change in [ { uid: 1000 }, { mode: 0777 }, { type: "link" } ])
        t.eq(installer.protected_checker(file, { ...directory, ...change }), false);
});

t.test("a check cannot report success after a failed child or a failed result with exit zero", () => {
    let success = { schema: 1, success: true, available: false, installed: { app: "2.0.0", core: "1.14.4-r3", variant: "base" }, latest: { app: "2.0.0", core: "1.14.4-r3" } };
    for (let code in [ 1, -9 ]) {
        run_with({ action: "check", interactive: false }, () => {
            fs.writefile(installer.paths.output, sprintf("%J\n", success));
            uloop.__exit(1, code);
            uloop.__exit(0, 0);
        });
        t.eq(state().check_result.success, false);
        t.ok(state().exit != 0);
    }
    run_with({ action: "check", interactive: false }, () => {
        fs.writefile(installer.paths.output, '{"schema":1,"success":false,"reason":"network"}\n');
        uloop.__exit(1, 0);
        uloop.__exit(0, 0);
    });
    t.eq(state().check_result.success, false);
    t.ok(state().exit != 0);
});

t.test("an interrupted durable update remains visible after its process and lease disappear", () => {
    fresh();
    let update = require("service.update");
    let pending = update.pending;
    update.pending = () => true;
    let busy = installer.active();
    update.pending = pending;
    t.eq(busy, true);
    t.eq(installer.status(0).running, false);
});

t.test("installer logs refuse public, linked and oversized files without disclosing their contents", () => {
    fresh();
    let path = installer.paths.install_log, keep = path + ".keep";
    fs.writefile(keep, "synthetic-private-sentinel");
    fs.symlink(keep, path);
    t.eq(installer.log_text(), null);
    t.eq(fs.readfile(keep), "synthetic-private-sentinel");
    fs.unlink(path);
    fs.writefile(path, "private log");fs.chmod(path, 0600);
    t.eq(installer.log_text(), "private log");
    fs.chmod(path, 0644);t.eq(installer.log_text(), null);
    fs.chmod(path, 0600);
    t.eq(stub.real.system(require("core.exec").command_line([ "ln", path, path + ".link" ])), 0);
    t.eq(installer.log_text(), null);
    fs.unlink(path + ".link");
    fs.writefile(path, sprintf("%" + (installer.OUTPUT_LIMIT + 1) + "s", ""));
    t.eq(installer.log_text(), null);
});




t.test("native UI actions execute only the protected installed script without an offline kit", () => {
    for (let action in [ "check", "update", "uninstall" ]) {
        stub.commands([ real_sha() ]);
        run_with({ action, interactive: false }, () => {
            let children = uloop.__processes();
            t.eq(length(children), 2);
            t.eq(children[1].executable, "/bin/sh");
            t.contains(join(" ", children[1].args), installer.paths.script);
            t.excludes(join(" ", children[1].args), "--candidate");
            t.eq(children[1].env.LOKI_INSTALL_LOG, installer.paths.install_log);
            t.eq(fs.lstat(installer.paths.install_log).mode & 0777, 0600);
            if (action == "uninstall") t.contains(join(" ", children[1].args), "--uninstall");
            uloop.__exit(1, 0); uloop.__exit(0, 0);
        });
        stub.restore();
    }
});

t.test("private installer defaults work with the OpenWrt var symlink without following it", () => {
    let dir=stub.tmpdir();fs.chmod(dir,0700);
    for(let name in ["/tmp","/tmp/run"])fs.mkdir(dir+name,0755);
    for(let name in ["/tmp/loki-installer","/tmp/run/loki-installer"])fs.mkdir(dir+name,0700);
    fs.symlink("tmp",dir+"/var");
    let defaults=stub.fresh("service.installer").paths;
    let worker=stub.fresh("service.update").paths;
    t.eq(worker.log,defaults.install_log);
    for(let name in ["state","output","script","candidate","manifest","sums","listing","start_lock","install_log"]) {
        let result,error;
        try {result=require("core.cache_path").validate({cache_path:dir+defaults[name]});}
        catch(e){error=e;}
        t.eq(error,null,"the private spool must not traverse the var alias: "+name);
        t.eq(result,dir+defaults[name]);
    }
});

t.done();
