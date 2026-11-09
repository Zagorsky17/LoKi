// Modified for LoKi on 2026-11-03: product labels in user-facing messages.
// The Components tab's run of install.sh. A process of its own gives install.sh a
// pseudo-terminal, so the run shows the colors and asks the questions it does over SSH, and
// outlives the page, rpcd and every package the run replaces. The page follows the run through
// the ubus object that process publishes, and through the CLI once it is gone; the files below
// are read by whichever Loki version is installed when the run ends, so their format stays.

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let constants = require("core.constants");
let lock = require("service.lock");

const OBJECT_NAME = "loki.installer";
const SCHEMA = 1;
const ACTIONS = [ "check", "update", "variant", "uninstall" ];
const VARIANTS = [ "base", "full", "tiny" ];
const LANGUAGES = [ "ru", "en" ];
// A finished run keeps answering this long, so a page watching it reads the end even when the
// run removed Loki and its CLI.
const LINGER_MS = 60000;
// install.sh prints a few kilobytes; a run that floods its terminal goes on without the rest.
const OUTPUT_LIMIT = 262144;
const READ_LIMIT = 65536;
const INPUT_LIMIT = 1024;
const RUNNER_WAIT_MS = 5000;
// What install.sh left in its terminal is read this long after it exits: a process it started
// may hold the terminal open for good.
const DRAIN_MS = 2000;
const PUBLISH_TRIES = 10;
// install.sh's shell becomes a session of its own a moment after it starts; until then an
// interrupt of that session is sent again.
const INTERRUPT_TRIES = 10;
// SSH and LuCI execute the same protected package-manager installer.
const API_URL = "https://api.github.com";

let paths = {
    state: "/tmp/loki-installer/state.json",
    output: "/tmp/loki-installer/output",
    script: "/tmp/loki-installer/install.sh",
    local_script: "/usr/share/loki/install.sh",
    candidate: "/tmp/loki-installer/candidate",
    manifest: "/tmp/loki-installer/release.json",
    sums: "/tmp/loki-installer/SHA256SUMS",
    listing: "/tmp/loki-installer/listing.json",
    start_lock: "/tmp/loki-installer/start.lock",
    install_lock: "/var/lock/loki-package-install.lock",
    cli: "/usr/bin/loki",
    install_log: "/tmp/loki-installer/install.log",
    proc: "/proc",
    ptmx: "/dev/ptmx",
    exe: "/proc/self/exe",
    package_databases: [ "/lib/apk/db/installed", "/usr/lib/opkg/status" ]
};

// The run's own lines, written the way install.sh writes its own.
const TEXTS = {
    download_failed: [ "Cannot download install.sh", "Не удалось скачать install.sh" ],
    unresolved: [ "The router cannot resolve %s: check its DNS and internet connection",
        "Роутер не может определить адрес %s: проверьте DNS и подключение к интернету" ],
    unreachable: [ "Check that %s opens from the router", "Проверьте, открывается ли %s с роутера" ],
    command_only: [ "LoKi %s installs only with this command in a console:",
        "LoKi %s устанавливается только этой командой в консоли:" ],
    no_script: [ "The latest LoKi release has no install.sh", "В последнем релизе LoKi нет install.sh" ],
    rate_limited: [ "GitHub refuses more requests from this address for now: it allows 60 an hour without an account",
        "GitHub пока не принимает запросы с этого адреса: без входа он даёт 60 запросов в час" ],
    try_later: [ "Run it again later: the limit is reset within the hour", "Запустите снова позже: лимит сбрасывается в течение часа" ],
    no_terminal: [ "Cannot open a terminal for the installer", "Не удалось открыть терминал для установщика" ],
    interrupted: [ "Interrupted: nothing was changed", "Прервано, ничего не изменено" ],
    invalid_release: [ "The release metadata is missing or invalid", "Сведения о релизе отсутствуют или повреждены" ],
    checksum_failed: [ "The installer or its manifest failed SHA256 verification", "Установщик или его manifest не прошёл проверку SHA256" ],
    invalid_checker: [ "The installed update checker is missing or has unsafe ownership or permissions", "Установленная проверка обновлений отсутствует или имеет небезопасного владельца или права" ],
    invalid_source: [ "The release source must use a valid HTTPS URL", "Источник релиза должен использовать допустимый HTTPS URL" ]
};

const MARKS = { error: "\u001b[1;31m[x]\u001b[0m", warn: "\u001b[1;33m[!]\u001b[0m" };

function text(lang, key, ...args) {
    return sprintf(TEXTS[key][lang == "ru" ? 1 : 0], ...args);
}

// A terminal ends its lines with CR LF, and these lines go beside its output; what to do about a
// failure is a line of its own under it, marked as a warning.
function mark_line(mark, message) {
    return MARKS[mark] + " " + message + "\r\n";
}

function plain_line(message) {
    return message + "\r\n";
}

function read_state() {
    let value = common.read_json_file(paths.state);
    return type(value) == "object" && value.schema == SCHEMA ? value : null;
}

function write_state(value) {
    return common.write_file_atomic(paths.state, sprintf("%J\n", value));
}

// install.sh traps SIGINT while it has changed nothing and ignores it while it changes packages,
// and the package manager it then runs would still take a SIGINT sent to its session: the
// kernel's masks tell which phase it is in, SIGINT being bit 1.
function sigint_disposition(pid) {
    let status = fs.readfile(paths.proc + "/" + pid + "/status");
    if (status == null)
        return null;
    let ignored = match(status, /\nSigIgn:\s*([0-9a-f]+)/);
    let caught = match(status, /\nSigCgt:\s*([0-9a-f]+)/);
    let has = (mask) => mask != null && (hex(substr(mask[1], length(mask[1]) - 1, 1)) & 2) != 0;
    if (has(ignored))
        return "ignored";
    return has(caught) ? "caught" : "default";
}

// The run's files are read only through Loki, so a run that removed Loki takes them along.
function forget_run() {
    fs.unlink(paths.state);
    fs.unlink(paths.output);
    fs.rmdir(common.parent_dir(paths.state));
}

// Checked by the command line, so a pid the kernel has given to another process does not count.
function process_is(pid, marker) {
    pid = common.as_string(pid);
    return common.pid_alive(pid) && index(fs.readfile("/proc/" + pid + "/cmdline") ?? "", marker) >= 0;
}

function runner_alive(state) {
    return process_is(state?.runner_pid, "installer_run");
}

// The CLI that started the run waits until its process has recorded itself, and install.sh may
// outlive that process: while any of the three lives, the run goes on.
function run_alive(state) {
    return process_is(state.starter_pid, "installer_start") || runner_alive(state) ||
        process_is(state.child_pid, paths.script);
}

function running(state) {
    return state != null && state.finished_at == null;
}

// A run whose processes all died without recording its end is recorded as interrupted.
function settle(state) {
    if (!running(state) || run_alive(state))
        return state;
    state = { ...state, interrupted: true, finished_at: common.now_seconds() };
    write_state(state);
    return state;
}

function current() {
    return settle(read_state());
}

function active() {
    return running(current()) || lock.held(paths.install_lock) || require("service.update").pending();
}

// The longest prefix of data that ends on a whole UTF-8 character, so a character a read cut in
// two arrives whole with the next read.
function whole_characters(data) {
    let n = length(data);
    for (let back = 1; back <= 3 && back <= n; back++) {
        let byte = ord(data, n - back);
        if (byte < 0x80)
            return n;
        if (byte >= 0xc0) {
            let size = byte >= 0xf0 ? 4 : byte >= 0xe0 ? 3 : 2;
            return back >= size ? n : n - back;
        }
    }
    return n;
}

function read_output(offset) {
    let file = fs.open(paths.output, "r");
    if (file == null)
        return "";
    if (offset > 0)
        file.seek(offset);
    let data = file.read(READ_LIMIT) ?? "";
    file.close();
    return substr(data, 0, whole_characters(data));
}

// install.sh empties its log as it starts, so a log no older than the run's start is this run's.
function log_stat() {
    let stat = fs.lstat(paths.install_log);
    return stat?.type == "file" && stat.uid == fs.stat("/proc/self").uid && stat.nlink == 1 &&
        (stat.mode & 0777) == 0600 && stat.size <= OUTPUT_LIMIT ? stat : null;
}

function has_log(state) {
    let stat = log_stat();
    return state.child_pid != null && stat != null && stat.mtime >= int(state.started_at ?? 0);
}


function log_text() {
    let before = log_stat();
    if (before == null) return null;
    let file = fs.open(paths.install_log, "re");
    if (file == null) return null;
    let data, safe = false;
    let files = require("service.preflight_files");
    try {
        let fd = "/proc/self/fd/" + file.fileno();
        if (files.same_node(before, fs.stat(fd))) {
            fs.error();
            data = file.read(OUTPUT_LIMIT + 1);
            safe = file.error() == null && type(data) == "string" && length(data) == before.size &&
                files.same_node(before, fs.stat(fd)) && files.same_node(before, fs.lstat(paths.install_log));
        }
    }
    catch (e) {}
    try { safe = file.close() === true && safe; }
    catch (e) { safe = false; }
    return safe ? data : null;
}

// The run as the page shows it, with its output from offset on.
function snapshot(state, offset) {
    if (state == null)
        return { id: "", running: false };
    offset = int(offset || 0);
    if (offset < 0)
        offset = 0;
    let data = read_output(offset);
    return {
        id: state.id,
        action: state.action,
        variant: state.variant,
        purge: state.purge,
        interactive: state.interactive,
        running: running(state),
        exit: state.exit,
        interrupted: state.interrupted === true,
        stop_requested: state.stop_requested === true,
        changed: state.changed === true,
        started_at: state.started_at,
        finished_at: state.finished_at,
        log: has_log(state),
        offset,
        next: offset + length(data),
        data,
        check_result: state.check_result ?? null
    };
}

function status(offset) {
    return snapshot(current(), offset);
}

// install.sh's options for a run; a bare --variant asks for the build and goes last. The page
// offers the log behind a button, so the package manager's output stays in it.
function install_arguments(action, variant, purge, lang) {
    let argv = [ "--lang", lang, "--quiet" ];
    if (action == "uninstall") {
        push(argv, "--uninstall");
        if (purge)
            push(argv, "--purge");
    }
    else if (action == "check")
        push(argv, "--check");
    else if (action == "variant") {
        push(argv, "--variant");
        if (variant != "")
            push(argv, variant);
    }
    return argv;
}

// The mirror install.sh downloads from instead of GitHub, if one is set.
function mirror_url() {
    return getenv("LOKI_DOWNLOAD_URL") || null;
}

// The latest release's file at the mirror.
function release_url(file) {
    return mirror_url() + "/" + constants.LOKI_RELEASE_REPO + "/releases/latest/download/" + file;
}

// GitHub's account of the latest release, which gives each file's address in the API.
function listing_url() {
    return API_URL + "/repos/" + constants.LOKI_RELEASE_REPO + "/releases/latest";
}

function safe_version(value, core) {
    return type(value) == "string" && length(value) <= 96 && index(value, chr(0)) < 0 &&
        match(value, core ? /^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}(-r[0-9]{1,9})?$/ : /^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$/) != null;
}

function valid_manifest(content) {
    let value = common.parse_json(content);
    return type(value) == "object" && value.schema === 1 && value.name == "loki" && safe_version(value.version, false) &&
        safe_version(value.requires?.["loki-core"], true) &&
        (value.tag == null || (type(value.tag) == "string" && index(value.tag, chr(0)) < 0 &&
            match(value.tag, /^v?[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}(-r[0-9]{1,9})?$/) != null));
}

function valid_asset_url(url) {
    return type(url) == "string" && index(url, chr(0)) < 0 &&
        match(url, /^https:\/\/api\.github\.com\/repos\/Zagorsky17\/LoKi\/releases\/assets\/[0-9]+$/) != null;
}

function valid_mirror(url) {
    return type(url) == "string" && index(url, chr(0)) < 0 && !match(url, /[[:cntrl:] ]/) &&
        match(url, /^https:\/\/([a-zA-Z0-9.-]+|\[[a-fA-F0-9:]+\])(:[0-9]{1,5})?(\/[a-zA-Z0-9._~\/-]*)?$/) != null &&
        index("/" + join("/", slice(split(url, "/"), 3)) + "/", "/../") < 0;
}

// Read-role checks only execute the installed package's root-owned resolver.
function protected_checker(file, directory) {
    return file?.type == "file" && file.uid === 0 && (file.mode & 0022) == 0 && file.size > 0 && file.size <= 524288 &&
        directory?.type == "directory" && directory.uid === 0 && (directory.mode & 0022) == 0;
}

function verified_file(path, name, sums) {
    let stat = fs.lstat(path);
    if (stat?.type != "file" || stat.size <= 0 || stat.size > 524288 || type(sums) != "string" || length(sums) > 1048576)
        return false;
    let expected = null;
    for (let line in split(sums, "\n")) {
        let fields = match(trim(line), /^([a-fA-F0-9]{64}) [ *]([^ ]+)$/);
        if (fields?.[2] == name) {
            if (expected != null)
                return false;
            expected = lc(fields[1]);
        }
    }
    if (expected == null)
        return false;
    let actual = exec.capture([ "sha256sum", path ]);
    return actual.status == 0 && split(actual.stdout, " ")[0] == expected;
}

function parse_update_result(output) {
    let result = null;
    let records = 0;
    for (let line in split(output, "\n")) {
        let value = common.parse_json(trim(line));
        if (type(value) != "object" || value.schema !== 1)
            continue;
        records++;
        if (value.success === false && type(value.reason) == "string" && match(value.reason, /^[a-z_]{1,64}$/))
            result = { schema: 1, success: false, reason: value.reason };
        else if (value.success === true && type(value.available) == "bool" && safe_version(value.latest?.app, false) && safe_version(value.latest?.core, true) &&
            type(value.installed?.app) == "string" && type(value.installed?.core) == "string" &&
            match(value.installed.app, /^[A-Za-z0-9.+~_-]{0,96}$/) && match(value.installed.core, /^[A-Za-z0-9.+~_-]{0,96}$/) &&
            index(value.installed.app, chr(0)) < 0 && index(value.installed.core, chr(0)) < 0 &&
            index([ "", "base", "full", "tiny", "custom" ], value.installed?.variant) >= 0)
            result = { schema: 1, success: true, available: value.available, installed: { app: value.installed.app, core: value.installed.core, variant: value.installed.variant },
                latest: { app: value.latest.app, core: value.latest.core } };
    }
    return records == 1 ? result : null;
}

function asset_url(listing, file) {
    let value = common.parse_json(listing);
    let found = filter(type(value?.assets) == "array" ? value.assets : [], (asset) => asset?.name == file);
    return length(found) == 1 && valid_asset_url(found[0].url) ? found[0].url : null;
}

// GitHub's /rate_limit answer, which costs no request: whether the API refuses this address now.
function rate_limited(answer) {
    return common.parse_json(answer)?.resources?.core?.remaining === 0;
}

function url_host(url) {
    let host = replace(url, /^[a-z]+:\/\//, "");
    host = split(host, "/")[0];
    return replace(host, /:[0-9]+$/, "");
}

// What install.sh runs with: the terminal's type, nothing of the library this process loaded.
function child_environment() {
    let env = { ...getenv(), TERM: "xterm" };
    delete env.NO_COLOR;
    delete env.LOKI_LIB;
    env.LOKI_INSTALL_LOG = paths.install_log;
    return env;
}

// ucode keeps the files it loaded open without close-on-exec; the shells close every inherited
// descriptor but the one named, so install.sh and what it starts hold neither those nor the
// terminal's master.
function close_inherited(keep) {
    return sprintf("for fd in /proc/$$/fd/*; do fd=${fd##*/}; [ \"$fd\" -gt 2 ] && [ \"$fd\" != %d ] && eval \"exec $fd<&-\"; done; ", keep);
}

// A run that may ask gets the terminal as its controlling one; a removal asks nothing, because
// the page asked about the settings already, and without a controlling terminal install.sh
// asks nothing while its output keeps the terminal's colors.
function child_script(interactive) {
    return close_inherited(-1) + (interactive
        ? "tty=$1; shift; exec setsid -c /bin/sh \"$@\" <\"$tty\" >\"$tty\" 2>&1"
        : "tty=$1; shift; exec setsid /bin/sh \"$@\" </dev/null >\"$tty\" 2>&1");
}

// cat copies what install.sh writes as it comes, until install.sh and whatever it started let go
// of the terminal; BusyBox head would hold it back in a stdio buffer.
function pump_script(fd) {
    return close_inherited(fd) + sprintf("exec cat <&%d >>\"$0\"", fd);
}

// Past the output limit the terminal is still read, so install.sh never blocks on a full one.
function drain_script(fd) {
    return close_inherited(fd) + sprintf("exec cat <&%d >/dev/null", fd);
}

function little_endian() {
    let header = fs.readfile(paths.exe, 6);
    return header == null || ord(header, 5) != 2;
}

function unsigned(bytes, little) {
    let value = 0;
    for (let i = 0; i < length(bytes); i++)
        value = value * 256 + ord(bytes, little ? length(bytes) - 1 - i : i);
    return value;
}

// A new pseudo-terminal: { master, tty }, or null. TIOCSPTLCK unlocks its other side, TIOCGPTN
// names it; both are _IOW and _IOR of 'T', which ioctl() encodes for the running architecture.
function open_terminal() {
    let master = fs.open(paths.ptmx, "r+");
    if (master == null)
        return null;
    let number = master.ioctl(fs.IOC_DIR_READ, ord("T"), 0x30, 4);
    if (master.ioctl(fs.IOC_DIR_WRITE, ord("T"), 0x31, "\u0000\u0000\u0000\u0000") == null || number == null) {
        master.close();
        return null;
    }
    return { master, tty: "/dev/pts/" + unsigned(number, little_endian()) };
}

// A package manager that replaces its database by a rename leaves a new inode even within the
// second the mtime counts.
function path_signature(path) {
    let stat = fs.stat(path);
    return stat == null ? "-" : stat.inode + ":" + stat.mtime + ":" + stat.size;
}

function package_signature() {
    return join("|", map(paths.package_databases, (path) => path_signature(path)));
}

function append_output(data) {
    let file = fs.open(paths.output, "a");
    if (file == null)
        return false;
    file.write(data);
    file.close();
    return true;
}

// The command a release that cannot be installed from the page names in its release.json.
function install_command(manifest) {
    let value = common.parse_json(manifest);
    let command = type(value) == "object" ? common.as_string(value.install_command) : "";
    return trim(command) == "" ? null : { command: trim(command), version: common.as_string(value.version) };
}

function valid_run(action, variant, lang) {
    return index(ACTIONS, action) >= 0 && index(LANGUAGES, lang) >= 0 &&
        (variant == "" || (action == "variant" && index(VARIANTS, variant) >= 0));
}

function new_id() {
    let now = clock();
    return sprintf("%d-%d", now[0], int(now[1] / 1000));
}

// A finished run's process may still be answering under the object name the next run takes.
function retire(state) {
    if (state == null || !runner_alive(state))
        return;
    let pid = common.as_string(state.runner_pid);
    exec.ok([ "kill", pid ]);
    for (let i = 0; i < 30 && runner_alive(state); i++)
        sleep(100);
    if (runner_alive(state))
        exec.ok([ "kill", "-KILL", pid ]);
}

function spawn_runner(id) {
    return trim(exec.output([ "sh", "-c", "setsid \"$@\" </dev/null >/dev/null 2>&1 1000>&- & echo $!", "sh",
        constants.LOKI_BIN, "installer_run", id ]) ?? "");
}

// The run is the runner's once it has recorded itself in the state.
function wait_for_runner(id) {
    for (let waited = 0; waited < RUNNER_WAIT_MS; waited += 100) {
        let state = read_state();
        if (state?.id != id || state.runner_pid != null || state.finished_at != null)
            return state;
        sleep(100);
    }
    return read_state();
}

// Starts a run unless one goes on: { id, started }, the id of the run the page then follows.
function start(action, variant, purge, lang) {
    action = common.as_string(action);
    variant = common.as_string(variant);
    lang = common.as_string(lang);
    if (!valid_run(action, variant, lang))
        die("Invalid installer run: " + join(" ", [ action, variant, lang ]));

    let owner = common.own_pid();
    require("core.cache_path").ensure({ cache_path: paths.state });
    if (!lock.acquire(paths.start_lock, owner, 5))
        die("Another installer run is starting");

    let state = current();
    if (running(state)) {
        lock.release(paths.start_lock, owner);
        return { id: state.id, started: false };
    }
    let ui = require("service.ui");
    if (!lock.acquire(ui.paths.service_action_lock, owner, 5)) {
        lock.release(paths.start_lock, owner);
        die("Another service action is starting");
    }
    ui.refresh();
    if (lock.held(paths.install_lock) || lock.held(ui.paths.reload_lock) || ui.active_action() != "") {
        lock.release(ui.paths.service_action_lock, owner);
        lock.release(paths.start_lock, owner);
        die("Another service action or installer is running");
    }
    retire(state);

    let id = new_id();
    for (let path in [ paths.output, paths.script, paths.manifest, paths.sums ])
        fs.unlink(path);
    common.write_file(paths.output, "");
    let written = write_state({
        schema: SCHEMA,
        id,
        action,
        variant: action == "variant" ? variant : null,
        purge: action == "uninstall" && (purge === true || purge == "1"),
        lang,
        interactive: action != "uninstall" && action != "check",
        starter_pid: owner,
        runner_pid: null,
        child_pid: null,
        started_at: common.now_seconds(),
        finished_at: null,
        exit: null,
        changed: false,
        interrupted: false
    });
    // Publish the run while the same lock excludes new UI service jobs.
    lock.release(ui.paths.service_action_lock, owner);
    if (written)
        spawn_runner(id);

    let recorded = written ? wait_for_runner(id) : null;
    lock.release(paths.start_lock, owner);
    if (recorded?.id == id && recorded.runner_pid != null)
        return { id, started: true };
    if (recorded?.id == id && recorded.finished_at == null)
        write_state({ ...recorded, starter_pid: null, interrupted: true, finished_at: common.now_seconds() });
    die("The installer did not start");
}

// The process a run lives in: it runs the protected installed entry in a pseudo-terminal, serves the
// page and lingers once install.sh has exited. Every module is loaded before install.sh starts,
// so a run that replaces the library never runs a mix of two versions.
function run(id) {
    let uloop = require("uloop");
    let ubus = require("ubus");

    let state = read_state();
    if (state?.id != id || state.finished_at != null)
        return 1;
    state = { ...state, runner_pid: common.own_pid() };
    write_state(state);

    let packages_before = package_signature();
    let env = child_environment();
    let terminal = null;
    let child = null;
    let pump = null;
    let child_exit = null;
    let pump_done = false;
    let leftover = null;
    let size_watch = null;
    let finished = false;

    function finish(exit_code) {
        if (finished)
            return;
        finished = true;
        // ucode's ?. stops a member access on null, never the call after it
        if (leftover != null)
            leftover.cancel();
        if (size_watch != null)
            size_watch.cancel();
        if (terminal != null)
            terminal.master.close();
        terminal = null;
        fs.unlink(paths.script);
        fs.unlink(paths.manifest);
        fs.unlink(paths.sums);
        fs.unlink(paths.listing);
        let check_result = state.action == "check" ? parse_update_result(fs.readfile(paths.output) ?? "") : null;
        if (state.action == "check" && check_result == null) {
            check_result = { schema: 1, success: false, reason: "incomplete" };
            if (exit_code == 0)
                exit_code = 1;
        }
        if (state.action == "check" && check_result?.success === true && exit_code != 0)
            check_result = { schema: 1, success: false, reason: "process_failed" };
        if (state.action == "check" && check_result?.success !== true && exit_code == 0)
            exit_code = 1;
        state = { ...state, check_result, exit: exit_code, finished_at: common.now_seconds(),
            changed: state.action != "check" && package_signature() != packages_before };
        write_state(state);
        uloop.timer(LINGER_MS, () => uloop.end());
    }

    function fail_with(lines) {
        append_output(join("", lines));
        finish(1);
    }

    function record_stop() {
        if (state.stop_requested === true)
            return;
        state = { ...state, stop_requested: true };
        write_state(state);
    }

    // Until install.sh has set its trap and setsid has made its session, the interrupt waits.
    function interrupt_child(tries) {
        if (child_exit != null)
            return;
        let disposition = sigint_disposition(child.pid());
        if (disposition == "ignored")
            return;
        if (disposition == "caught" && exec.ok([ "kill", "-INT", "--", "-" + child.pid() ]))
            return;
        if (tries > 1)
            uloop.timer(100, () => interrupt_child(tries - 1));
    }

    // While install.sh has changed nothing its whole session gets SIGINT, as from Ctrl+C, and it
    // stops; while it changes packages it finishes, and the end it reports stands.
    function stop() {
        if (finished || child_exit != null)
            return false;
        record_stop();
        if (child != null)
            interrupt_child(INTERRUPT_TRIES);
        return true;
    }

    function stop_pump() {
        if (pump != null && !pump_done)
            exec.ok([ "kill", "--", "-" + pump.pid() ]);
    }

    function on_child_exit(code) {
        child_exit = code;
        if (pump_done)
            finish(code);
        else
            leftover = uloop.timer(DRAIN_MS, () => {
                stop_pump();
                finish(child_exit);
            });
    }

    function on_pump_exit() {
        pump_done = true;
        if (child_exit != null)
            finish(child_exit);
    }

    // In a session of its own, so a pump that never sees the end is stopped with what it started;
    // only the pump in charge ends the run when it exits.
    function start_pump(script) {
        let current = null;
        current = uloop.process("setsid", [ "sh", "-c", script, paths.output ], env, () => {
            if (current == pump)
                on_pump_exit();
        });
        pump = current;
    }

    function cap_output(fd) {
        if (pump_done || (fs.stat(paths.output)?.size ?? 0) <= OUTPUT_LIMIT)
            return;
        size_watch.cancel();
        let copying = pump;
        start_pump(drain_script(fd));
        exec.ok([ "kill", "--", "-" + copying.pid() ]);
    }

    function start_install() {
        let arguments;
        try {
            arguments = install_arguments(state.action, state.variant ?? "", state.purge, state.lang);
        }
        catch (e) { return fail_with([ mark_line("error", "The prepared component kit is missing, invalid or incompatible") ]); }
        terminal = open_terminal();
        if (terminal == null)
            return fail_with([ mark_line("error", text(state.lang, "no_terminal")) ]);

        let fd = terminal.master.fileno();
        start_pump(pump_script(fd));
        size_watch = uloop.interval(1000, () => cap_output(fd));
        child = uloop.process("/bin/sh", [ "-c", child_script(state.interactive), "sh", terminal.tty, paths.script,
            ...arguments ], env, on_child_exit);
        state = { ...state, child_pid: common.as_string(child.pid()) };
        write_state(state);
    }


    function read_method(request) {
        return snapshot(state, request.args.offset);
    }

    function input_method(request) {
        let data = common.as_string(request.args.data);
        if (request.args.id != state.id || finished || child_exit != null || !state.interactive || terminal == null || data == "")
            return { accepted: false };
        // Ctrl+C is the stop, never the terminal's own SIGINT, which would reach the package manager
        let parts = split(substr(data, 0, INPUT_LIMIT), "\u0003");
        data = join("", parts);
        if (data != "") {
            terminal.master.write(data);
            terminal.master.flush();
        }
        if (length(parts) > 1)
            stop();
        return { accepted: true };
    }

    function stop_method(request) {
        return { accepted: request.args.id == state.id && stop() };
    }

    uloop.init();
    // libubox drops a SIGTERM that arrives before the loop runs; these handlers are queued
    uloop.signal("SIGTERM", () => {
        if (finished)
            uloop.end();
    });
    uloop.signal("SIGHUP", () => null);
    uloop.signal("SIGINT", () => null);

    let connection = ubus.connect();
    let object = null;
    for (let i = 0; connection != null && object == null && i < PUBLISH_TRIES; i++) {
        object = connection.publish(OBJECT_NAME, {
            read: { call: read_method, args: { id: "", offset: 0, ubus_rpc_session: "" } },
            input: { call: input_method, args: { id: "", data: "", ubus_rpc_session: "" } },
            stop: { call: stop_method, args: { id: "", ubus_rpc_session: "" } }
        });
        if (object == null)
            sleep(200);
    }
    if (object == null)
        exec.log("warn", "The installer could not publish the ubus object " + OBJECT_NAME + "; the page cannot type into its terminal");

    if (mirror_url() && !valid_mirror(mirror_url()))
        fail_with([ mark_line("error", text(state.lang, "invalid_source")) ]);
    else {
        let trusted = protected_checker(fs.lstat(paths.local_script), fs.lstat(common.parent_dir(paths.local_script)));
        let source = trusted ? fs.readfile(paths.local_script) : null;
        if (source == null || !common.write_file_atomic(paths.install_log, "", 0600) || !common.write_file_atomic(paths.script, source, 0600))
            fail_with([ mark_line("error", text(state.lang, "invalid_checker")) ]);
        else
            start_install();
    }
    uloop.run();
    if (connection != null)
        connection.disconnect();
    if (!fs.access(paths.cli))
        forget_run();
    return 0;
}

return {
    OBJECT_NAME,
    ACTIONS,
    LINGER_MS,
    OUTPUT_LIMIT,
    paths,
    read_state,
    current,
    active,
    running,
    snapshot,
    log_text,
    status,
    whole_characters,
    install_arguments,
    release_url,
    listing_url,
    asset_url,
    rate_limited,
    url_host,
    child_script,
    pump_script,
    drain_script,
    install_command,
    unsigned,
    start,
    run,
    valid_manifest,
    valid_asset_url,
    valid_mirror,
    verified_file,
    protected_checker,
    parse_update_result
};
