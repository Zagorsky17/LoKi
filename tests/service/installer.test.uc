// Modified for LoKi on 2026-10-31: use the project release repository.
let t = require("t");
let stub = require("stub");
let fs = require("fs");
let ubus = require("ubus");
let uloop = require("uloop");
let common = require("core.common");
let installer = require("service.installer");

let me = common.own_pid();
const MIRROR = "http://10.0.2.2:18090";

// The run's directory, and the system's files beside it in a directory of their own.
function fresh() {
    let dir = stub.tmpdir();
    let system = stub.tmpdir();
    installer.paths.state = dir + "/state.json";
    installer.paths.output = dir + "/output";
    installer.paths.script = dir + "/install.sh";
    installer.paths.manifest = dir + "/release.json";
    installer.paths.listing = dir + "/listing.json";
    installer.paths.start_lock = dir + "/start.lock";
    installer.paths.cli = system + "/forkop";
    installer.paths.proc = system + "/proc";
    installer.paths.install_log = system + "/forkop-install.log";
    installer.paths.ptmx = "/dev/ptmx";
    installer.paths.package_databases = [ system + "/installed" ];
    fs.writefile(system + "/installed", "forkop 2.0.0\n");
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

// A process whose command line names marker, as a runner's names installer_run; the second
// command keeps the shell from replacing itself with sleep.
function live_process(marker) {
    let pipe = stub.real.popen("sh -c 'sleep 30; :' " + marker + " >/dev/null 2>&1 & echo $!", "r");
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

t.test("the page learns when the run began and ended, and whether install.sh left this run's log", () => {
    fresh();
    let now = common.now_seconds();
    write_state({ child_pid: "4242", started_at: now - 30, finished_at: now, exit: 0 });
    t.eq([ installer.status(0).started_at, installer.status(0).finished_at, installer.status(0).log ], [ now - 30, now, false ]);
    fs.writefile(installer.paths.install_log, "install.sh --lang ru --quiet\n");
    t.eq(installer.status(0).log, true);
    write_state({ child_pid: null, started_at: now - 30, finished_at: now, exit: 1 });
    t.eq(installer.status(0).log, false, "a run that never started install.sh");
    write_state({ child_pid: "4242", started_at: now + 3600, finished_at: now + 3600, exit: 0 });
    t.eq(installer.status(0).log, false, "the log of an earlier install.sh");
});

t.test("the command line prints install.sh's log, and says when there is none", () => {
    fresh();
    fs.writefile(installer.paths.install_log, "$ apk add forkop.apk\nOK: 83.7 MiB in 199 packages\n");
    let printed = stub.capture(() => require("service.cli").main([ "installer_log" ], "/lib"));
    t.eq([ printed.result, printed.stdout ], [ 0, "$ apk add forkop.apk\nOK: 83.7 MiB in 199 packages\n" ]);
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
    stub.env({ FORKOP_DOWNLOAD_URL: MIRROR });
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
    stub.commands([
        [ /installer_run/, (argv) => {
            push(launched, argv[length(argv) - 1]);
            let current = state();
            fs.writefile(installer.paths.state, sprintf("%J", { ...current, runner_pid: me }));
            return { stdout: me + "\n" };
        } ]
    ]);
    let started = installer.start("variant", "", "0", "ru");
    t.eq(started.started, true);
    t.eq(launched, [ started.id ]);
    t.eq([ state().action, state().variant, state().purge, state().interactive, state().lang ], [ "variant", "", false, true, "ru" ]);
    t.eq(fs.readfile(installer.paths.output), "", "a new run starts with an empty terminal");

    let runner = live_process("installer_run");
    fs.writefile(installer.paths.state, sprintf("%J", { ...state(), runner_pid: runner }));
    let again = installer.start("update", "", "0", "ru");
    t.eq(again, { id: started.id, started: false });
    t.eq(length(launched), 1, "no second runner");
    kill(runner);
    stub.restore();
});

t.test("a removal asks nothing and carries the settings choice", () => {
    fresh();
    stub.commands([
        [ /installer_run/, () => {
            fs.writefile(installer.paths.state, sprintf("%J", { ...state(), runner_pid: me }));
            return { stdout: "1\n" };
        } ]
    ]);
    installer.start("uninstall", "", "1", "en");
    t.eq([ state().purge, state().interactive, state().variant ], [ true, false, null ]);
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
    stub.commands([ [ /installer_run/, { stdout: "999999\n" } ] ]);
    t.contains(t.throws(() => installer.start("update", "", "0", "ru")).message, "The installer did not start");
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
    stub.env({ FORKOP_DOWNLOAD_URL: source == "api" ? null : MIRROR });
    let result = { status: null };
    uloop.__on_run(() => steps(result));
    result.status = installer.run(value.id ?? "run-1");
    stub.env({});
    return result;
}

function read(offset) {
    return ubus.__invoke("forkop.installer", "read", { offset }).replied;
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

t.test("the runner downloads install.sh, runs it in a terminal and records how it ended", () => {
    let seen = {};
    run_with({}, (result) => {
        let downloads = uloop.__processes();
        t.eq(downloads[0].executable, "uclient-fetch");
        t.contains(join(" ", downloads[0].args), "-O " + installer.paths.script + " " + MIRROR + "/Zagorsky17/LoKi/releases/latest/download/install.sh");
        t.eq(state().runner_pid, me, "the runner records itself first");
        uloop.__exit(0, 0);
        t.contains(join(" ", uloop.__processes()[1].args), "release.json", "an install checks the release first");
        fs.writefile(installer.paths.manifest, "{\"version\":\"2.0.1\"}");
        uloop.__exit(1, 0);

        let pump = uloop.__processes()[2];
        let child = uloop.__processes()[3];
        t.eq([ pump.executable, pump.args[0], pump.args[3] ], [ "setsid", "sh", installer.paths.output ]);
        t.eq(child.executable, "/bin/sh");
        t.matches(child.args[3], /^\/dev\/pts\/[0-9]+$/, "install.sh gets the new terminal");
        t.eq(slice(child.args, 4), [ installer.paths.script, "--lang", "ru", "--quiet" ]);
        t.eq(child.env.TERM, "xterm");
        t.eq(state().child_pid, "" + child.pid);

        seen.running = read(0);
        seen.typed = ubus.__invoke("forkop.installer", "input", { id: "run-1", data: "2\r" }).replied;
        seen.other = ubus.__invoke("forkop.installer", "input", { id: "run-0", data: "2\r" }).replied;
        fs.writefile(installer.paths.output, "Готово!\r\n");
        // as apk does: a new file renamed over the old one
        fs.writefile(installer.paths.package_databases[0] + ".new", "forkop 2.0.1\n");
        fs.rename(installer.paths.package_databases[0] + ".new", installer.paths.package_databases[0]);
        uloop.__exit(3, 0);
        t.eq(state().finished_at, null, "what install.sh left in its terminal is read first");
        uloop.__raise("SIGTERM");
        uloop.__exit(2, 1);
        seen.finished = read(0);
        seen.typed_late = ubus.__invoke("forkop.installer", "input", { id: "run-1", data: "x" }).replied;
        uloop.__fire("timer");
    });
    t.eq([ seen.running.running, seen.running.interactive ], [ true, true ]);
    t.eq(seen.typed, { accepted: true });
    t.eq(seen.other, { accepted: false }, "keys for another run");
    t.eq([ seen.finished.running, seen.finished.exit, seen.finished.changed, seen.finished.data ], [ false, 0, true, "Готово!\r\n" ]);
    t.eq(seen.typed_late, { accepted: false }, "no keys once install.sh is gone");
    t.eq([ state().exit, state().changed ], [ 0, true ]);
    t.ok(fs.stat(installer.paths.script) == null && fs.stat(installer.paths.manifest) == null, "the downloads go");
});

t.test("a removal skips the release check, asks nothing and takes the run's files along", () => {
    let seen = {};
    run_with({ action: "uninstall", purge: true, interactive: false }, () => {
        uloop.__exit(0, 0);
        let child = uloop.__processes()[2];
        t.eq(slice(child.args, 4), [ installer.paths.script, "--lang", "ru", "--quiet", "--uninstall", "--purge" ]);
        t.contains(child.args[1], "</dev/null");
        t.eq(ubus.__invoke("forkop.installer", "input", { id: "run-1", data: "y\r" }).replied, { accepted: false });
        fs.unlink(installer.paths.cli);
        uloop.__exit(2, 0);
        uloop.__exit(1, 0);
        seen.finished = read(0);
        uloop.__fire("timer");
    });
    t.eq([ seen.finished.running, seen.finished.exit ], [ false, 0 ], "the page reads the end while the run lingers");
    t.eq([ fs.stat(installer.paths.state), fs.stat(installer.paths.output), fs.stat(common.parent_dir(installer.paths.state)) ],
        [ null, null, null ]);
});

t.test("a stop ends a download of the run's own and says what install.sh says on an interrupt", () => {
    let killed = [];
    let seen = {};
    stub.commands([ [ "kill", (argv) => { push(killed, join(" ", argv)); return { status: 0 }; } ] ]);
    run_with({}, () => {
        t.contains(join(" ", uloop.__processes()[0].args), "-q -T 30 -O");
        seen.stop = ubus.__invoke("forkop.installer", "stop", { id: "run-1" }).replied;
        seen.other = ubus.__invoke("forkop.installer", "stop", { id: "run-0" }).replied;
        seen.stopping = read(0).stop_requested;
        uloop.__exit(0, -15);
        uloop.__fire("timer");
    });
    stub.restore();
    t.eq([ seen.stop, seen.other, seen.stopping ], [ { accepted: true }, { accepted: false }, true ]);
    t.eq(killed, [ "kill 40000" ], "the download alone");
    t.eq(fs.readfile(installer.paths.output), "\u001b[1;33m[!]\u001b[0m Прервано, ничего не изменено\r\n");
    t.eq([ state().exit, state().stop_requested, length(uloop.__processes()) ], [ 1, true, 1 ]);
});

t.test("a stop interrupts install.sh's whole session as Ctrl+C does, once its trap and session exist", () => {
    let killed = [];
    let seen = {};
    let refusals = 1;
    stub.commands([ [ "kill", (argv) => { push(killed, join(" ", argv)); return { status: refusals-- > 0 ? 1 : 0 }; } ] ]);
    run_with({}, () => {
        uloop.__exit(0, 0);
        uloop.__exit(1, 8);
        seen.stop = ubus.__invoke("forkop.installer", "stop", { id: "run-1" }).replied;
        seen.early = length(killed);
        sigint(40003, "default");
        fire_once();
        seen.untrapped = length(killed);
        sigint(40003, "caught");
        fire_once();
        fire_once();
        uloop.__exit(3, 1);
        seen.late = ubus.__invoke("forkop.installer", "stop", { id: "run-1" }).replied;
        uloop.__exit(2, 0);
        uloop.__fire("timer");
    });
    stub.restore();
    t.eq(seen.stop, { accepted: true });
    t.eq([ seen.early, seen.untrapped ], [ 0, 0 ], "nothing before install.sh traps SIGINT");
    t.eq(killed, [ "kill -INT -- -40003", "kill -INT -- -40003" ], "sent again while the session did not exist yet");
    t.eq(seen.late, { accepted: false }, "nothing to stop once install.sh is gone");
    t.eq([ state().exit, state().stop_requested ], [ 1, true ]);
});

t.test("a stop while install.sh changes packages leaves it to finish, and its end stands", () => {
    let killed = [];
    let seen = {};
    stub.commands([ [ "kill", (argv) => { push(killed, join(" ", argv)); return { status: 0 }; } ] ]);
    run_with({}, () => {
        uloop.__exit(0, 0);
        uloop.__exit(1, 8);
        sigint(40003, "ignored");
        seen.stop = ubus.__invoke("forkop.installer", "stop", { id: "run-1" }).replied;
        seen.retries = fire_once();
        uloop.__exit(3, 0);
        uloop.__exit(2, 0);
        uloop.__fire("timer");
    });
    stub.restore();
    t.eq([ seen.stop, seen.retries ], [ { accepted: true }, 0 ]);
    t.eq(killed, [], "nothing reaches the package manager");
    t.eq([ state().exit, state().stop_requested ], [ 0, true ]);
});

t.test("Ctrl+C sent to the terminal is the stop, never the terminal's own SIGINT", () => {
    let seen = {};
    run_with({}, () => {
        uloop.__exit(0, 0);
        uloop.__exit(1, 8);
        seen.typed = ubus.__invoke("forkop.installer", "input", { id: "run-1", data: "\u0003" }).replied;
        seen.stopping = read(0).stop_requested;
        uloop.__exit(3, 1);
        uloop.__exit(2, 0);
        uloop.__fire("timer");
    });
    t.eq([ seen.typed, seen.stopping, state().stop_requested ], [ { accepted: true }, true, true ]);
});

t.test("install.sh that cannot be downloaded is tried three times and said as install.sh says it", () => {
    let fail_three_times = () => {
        for (let i = 0; i < 3; i++) {
            uloop.__exit(i, 4);
            uloop.__fire("timer");
        }
    };
    run_with({ lang: "en" }, () => {
        fail_three_times();
        t.eq(uloop.__processes()[3].executable + " " + join(" ", uloop.__processes()[3].args), "nslookup api.github.com");
        uloop.__exit(3, 1);
        uloop.__fire("timer");
    }, "api");
    t.eq(fs.readfile(installer.paths.output),
        "\u001b[1;31m[x]\u001b[0m Cannot download install.sh\r\n\u001b[1;33m[!]\u001b[0m The router cannot resolve api.github.com: check its DNS and internet connection\r\n");
    t.eq(state().exit, 1);

    run_with({}, () => {
        fail_three_times();
        uloop.__exit(3, 0);
        uloop.__fire("timer");
    }, "api");
    t.eq(fs.readfile(installer.paths.output),
        "\u001b[1;31m[x]\u001b[0m Не удалось скачать install.sh\r\n\u001b[1;33m[!]\u001b[0m Проверьте, открывается ли api.github.com с роутера\r\n");

    run_with({}, () => {
        fs.writefile(installer.paths.listing, "{\"tag_name\":\"1.0.5\",\"assets\":[{\"name\":\"forkop_1.0.5.apk\",\"url\":\"https://api.github.com/x/1\"}]}");
        uloop.__exit(0, 0);
        uloop.__fire("timer");
    }, "api");
    t.eq([ length(uloop.__processes()), state().exit ], [ 1, 1 ], "nothing is fetched for a file the listing has not got");
    t.eq(fs.readfile(installer.paths.output), "\u001b[1;31m[x]\u001b[0m В последнем релизе Forkop нет install.sh\r\n",
        "a release that predates install.sh, as 1.0.5 does");

    run_with({}, () => {
        uloop.__exit(0, 8);
        t.eq(join(" ", uloop.__processes()[1].args), "-q -T 30 -O " + installer.paths.listing + " https://api.github.com/rate_limit",
            "an answer of the server's own is not tried again, and the rate limit is looked up");
        fs.writefile(installer.paths.listing, "{\"resources\":{\"core\":{\"limit\":60,\"remaining\":0}}}");
        uloop.__exit(1, 0);
        uloop.__fire("timer");
    }, "api");
    t.eq(fs.readfile(installer.paths.output),
        "\u001b[1;31m[x]\u001b[0m GitHub пока не принимает запросы с этого адреса: без входа он даёт 60 запросов в час\r\n" +
        "\u001b[1;33m[!]\u001b[0m Запустите снова позже: лимит сбрасывается в течение часа\r\n");

    run_with({}, () => {
        uloop.__exit(0, 8);
        fs.writefile(installer.paths.listing, "{\"resources\":{\"core\":{\"limit\":60,\"remaining\":41}}}");
        uloop.__exit(1, 0);
        uloop.__fire("timer");
    }, "api");
    t.eq(fs.readfile(installer.paths.output), "\u001b[1;31m[x]\u001b[0m В последнем релизе Forkop нет install.sh\r\n",
        "an HTTP error with requests left is a missing release");

    run_with({}, () => {
        uloop.__exit(0, 8);
        uloop.__fire("timer");
    });
    t.eq([ length(uloop.__processes()), fs.readfile(installer.paths.output) ],
        [ 1, "\u001b[1;31m[x]\u001b[0m В последнем релизе Forkop нет install.sh\r\n" ], "a mirror's HTTP error is a missing file");
});

t.test("through GitHub's API the run reads the release's listing, then its files at their addresses there", () => {
    run_with({}, () => {
        let listing = uloop.__processes()[0];
        t.eq([ listing.executable, join(" ", listing.args) ],
            [ "uclient-fetch", "-q -T 30 -O " + installer.paths.listing + " https://api.github.com/repos/Zagorsky17/LoKi/releases/latest" ]);
        fs.writefile(installer.paths.listing, "{\"assets\":[{\"name\":\"install.sh\",\"url\":\"https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/1\"}," +
            "{\"name\":\"release.json\",\"url\":\"https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/2\"}]}");
        uloop.__exit(0, 0);
        t.eq(join(" ", uloop.__processes()[1].args), "-q -T 30 --header=Accept: application/octet-stream -O " + installer.paths.script +
            " https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/1");
        uloop.__exit(1, 0);
        t.eq(uloop.__processes()[2].args[5], installer.paths.manifest);
        t.eq(uloop.__processes()[2].args[6], "https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/2");
        fs.writefile(installer.paths.manifest, "{\"version\":\"2.0.1\"}");
        uloop.__exit(2, 0);
        t.eq(uloop.__processes()[4].args[4], installer.paths.script, "install.sh runs");
        uloop.__exit(4, 0);
        uloop.__exit(3, 0);
        uloop.__fire("timer");
    }, "api");
    t.eq(state().exit, 0);
    t.eq(fs.stat(installer.paths.listing), null, "the listing goes with the downloads");
});

t.test("a stop between two tries of a download ends the run at once", () => {
    run_with({}, () => {
        uloop.__exit(0, 4);
        t.eq(ubus.__invoke("forkop.installer", "stop", { id: "run-1" }).replied, { accepted: true });
        t.eq(uloop.__fire("timer"), 1, "only the linger: the next try is gone");
    });
    t.eq(fs.readfile(installer.paths.output), "\u001b[1;33m[!]\u001b[0m Прервано, ничего не изменено\r\n");
    t.eq([ state().exit, length(uloop.__processes()) ], [ 1, 1 ]);
});

t.test("a release that installs only from a console is shown, not installed", () => {
    run_with({ action: "variant", variant: "" }, () => {
        uloop.__exit(0, 0);
        fs.writefile(installer.paths.manifest, "{\"version\":\"3.0.0\",\"install_command\":\"sh <(wget -O - https://x/install.sh)\"}");
        uloop.__exit(1, 0);
        uloop.__fire("timer");
    });
    t.eq(fs.readfile(installer.paths.output),
        "\u001b[1;33m[!]\u001b[0m Forkop 3.0.0 устанавливается только этой командой в консоли:\r\nsh <(wget -O - https://x/install.sh)\r\n");
    t.eq([ state().exit, length(uloop.__processes()) ], [ 1, 2 ]);
});

t.test("a missing release.json leaves the check to install.sh", () => {
    run_with({}, () => {
        uloop.__exit(0, 0);
        uloop.__exit(1, 8);
        t.eq(length(uloop.__processes()), 4, "install.sh runs");
        uloop.__exit(2, 1);
        uloop.__exit(3, 3);
        uloop.__fire("timer");
    });
    t.eq(state().exit, 3);
});

t.test("a terminal that never lets go is left after a while, and the run ends", () => {
    let killed = [];
    stub.commands([ [ "kill", (argv) => { push(killed, join(" ", argv)); return { status: 0 }; } ] ]);
    run_with({}, () => {
        uloop.__exit(0, 0);
        uloop.__exit(1, 8);
        uloop.__exit(3, 0);
        uloop.__fire("timer");
        uloop.__fire("timer");
    });
    stub.restore();
    t.eq(killed, [ "kill -- -40002" ], "the pump's whole session");
    t.eq(state().exit, 0);
});

t.test("past the output limit the terminal is read into nothing, and that reader ends the run", () => {
    let killed = [];
    stub.commands([ [ "kill", (argv) => { push(killed, join(" ", argv)); return { status: 0 }; } ] ]);
    run_with({}, () => {
        uloop.__exit(0, 0);
        uloop.__exit(1, 8);
        uloop.__fire("interval");
        t.eq(length(uloop.__processes()), 4, "nothing to cap yet");
        fs.writefile(installer.paths.output, sprintf("%" + (installer.OUTPUT_LIMIT + 1) + "s", ""));
        uloop.__fire("interval");
        let reader = uloop.__processes()[4];
        t.eq([ reader.executable, reader.args[3] ], [ "setsid", installer.paths.output ]);
        t.contains(reader.args[2], ">/dev/null");
        uloop.__fire("interval");
        t.eq(length(uloop.__processes()), 5, "capped once");
        uloop.__exit(2, -15);
        uloop.__exit(3, 0);
        t.eq(state().finished_at, null, "the pump it replaced does not end the run");
        uloop.__exit(4, 1);
        uloop.__fire("timer");
    });
    stub.restore();
    t.eq(killed, [ "kill -- -40002" ]);
    t.eq(state().exit, 0);
});

t.test("a run another one is not is left alone", () => {
    fresh();
    write_state({ id: "run-2" });
    t.eq(installer.run("run-1"), 1);
    write_state({ finished_at: common.now_seconds(), exit: 0 });
    t.eq(installer.run("run-1"), 1, "a finished run");
});

t.done();
