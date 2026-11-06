let t = require("t");
let fs = require("fs");
let stub = require("stub");
let services = require("service.preflight_services");

function fixture() {
    let root = stub.tmpdir();
    fs.chmod(root, 0755);
    stub.real.system("umask 022; mkdir -p '" + root + "/etc/rc.d' '" + root + "/etc/init.d'");
    return root;
}

function query(data, status) {
    stub.commands([[ "exec timeout", { stdout: data, status: status || 0 } ]]);
}

function has(result, state, reason) {
    return length(filter(result, (item) => item.state == state && item.reason == reason)) > 0;
}

function failed_directory_close(thrown) {
    let root = fixture();
    let opendir = fs.opendir;
    let closed = 0;
    let result;
    let exception = null;
    fs.opendir = (path) => {
        let directory = opendir(path);
        return { read: () => directory.read(), close: () => { closed++; directory.close();
            if (thrown) die("synthetic-private-close"); return false; } };
    };
    query("{}");
    try { result = services.collect(root); }
    catch (e) { exception = e.message; }
    fs.opendir = opendir;
    stub.restore();
    t.eq(exception, null);
    t.eq(closed, 1);
    t.ok(has(result, "incomplete", "autostart-directory-read-failed"));
    t.eq(has(result, "checked", "autostart-directory-read-complete"), false);
    t.excludes(sprintf("%J", result), "synthetic-private");
    query("{}");
    let repeated = services.collect(root);
    stub.restore();
    t.ok(has(repeated, "checked", "autostart-directory-read-complete"));
}

t.test("a false directory close refuses autostart coverage", () => failed_directory_close(false));
t.test("a throwing directory close is private and refuses autostart coverage", () => failed_directory_close(true));

t.test("pinned procd shapes support missing instances, stopped processes and private metadata", () => {
    let result = services.parse(sprintf("%J", { empty: {}, stopped: { autostart: false, instances: {
        main: { running: false, exit_code: 0, command: [ "synthetic-private-command" ], env: { TOKEN: "synthetic-secret" } }
    } }, podkop: { instances: { main: { running: true, pid: 123 } } } }));
    t.eq(result.services, 3);
    t.eq(result.instances, 2);
    t.eq(result.known, [ { name: "podkop", active: true, pending: false } ]);
    t.excludes(sprintf("%J", result), "synthetic-private-command");
    t.excludes(sprintf("%J", result), "synthetic-secret");
});

t.test("invalid snapshots never become a successful empty inventory", () => {
    for (let data in [ "", "{}x", "{} {}", "{}\u0000", "null", "[]", "{\"x\":null}",
        "{\"x\":{\"instances\":[]}}", "{\"x\":{\"autostart\":1}}", "{\"x\":{\"triggers\":false}}",
        "{\"x\":{\"instances\":{\"i\":{}}}}", "{\"x\":{\"instances\":{\"i\":{\"running\":1}}}}",
        "{\"x\":{\"instances\":{\"i\":{\"running\":true,\"pid\":0}}}}",
        "{\"x\":{\"instances\":{\"i\":{\"running\":true,\"pid\":1.5}}}}",
        "{\"x\":{\"instances\":{\"i\":{\"running\":false,\"pid\":1}}}}",
        "{\"x\":{\"instances\":{\"i\":{\"running\":false,\"respawn\":false}}}}" ])
        t.ok(services.parse(data).error != null);
});

t.test("service and instance counts are bounded independently of the response byte cap", () => {
    let value = {};
    for (let i = 0; i < 4097; i++) value["s" + i] = {};
    t.eq(services.parse(sprintf("%J", value)).error, "service-response-shape-invalid");
    value = { test: { instances: {} } };
    for (let i = 0; i < 4097; i++) value.test.instances["i" + i] = { running: false };
    t.eq(services.parse(sprintf("%J", value)).error, "service-response-shape-invalid");
});

t.test("only the fixed read-only query is issued and oversize output is not retained", () => {
    let root = fixture();
    query(sprintf("%262145s", ""));
    let result = services.collect(root);
    let commands = stub.command_lines();
    stub.restore();
    t.ok(has(result, "incomplete", "service-response-size-limit"));
    t.eq(commands, [ "exec timeout -s KILL 5 ubus call service list {\"verbose\":true}" ]);
});

t.test("running own services and inactive respawn or triggers remain unverified", () => {
    let root = fixture();
    query(sprintf("%J", { loki: { instances: { main: { running: true, pid: 20 } } },
        podkop: { instances: { main: { running: false, respawn: {} } } },
        "loki-state": { triggers: [ [ "synthetic-private-trigger" ] ] } }));
    let result = services.collect(root);
    stub.restore();
    t.ok(has(result, "incomplete", "existing-service-origin-unverified"));
    t.ok(has(result, "incomplete", "service-restart-trigger-unverified"));
    t.ok(has(result, "incomplete", "service-process-and-origin-unverified"));
    t.excludes(sprintf("%J", result), "synthetic-private-trigger");
});

t.test("inactive known services and dangling or non-executable init leftovers are not conflicts", () => {
    let root = fixture();
    fs.symlink("../init.d/podkop", root + "/etc/rc.d/S95podkop");
    query('{"podkop":{"instances":{"main":{"running":false}}}}');
    let first = services.collect(root);
    stub.restore();
    t.ok(has(first, "checked", "known-service-inactive"));
    t.ok(has(first, "checked", "autostart-dangling-link"));
    fs.writefile(root + "/etc/init.d/podkop", "synthetic-private-init-body");
    fs.chmod(root + "/etc/init.d/podkop", 0644);
    query("{}");
    let second = services.collect(root);
    stub.restore();
    t.ok(has(second, "checked", "autostart-entry-not-executable"));
    t.eq(length(filter(first, (item) => item.state == "conflict")), 0);
    t.eq(length(filter(second, (item) => item.state == "conflict")), 0);
});

t.test("arbitrary link destinations, file bodies and unknown startup names are never reported or executed", () => {
    let root = fixture();
    fs.symlink("../../synthetic-secret-destination", root + "/etc/rc.d/S95podkop");
    fs.writefile(root + "/etc/rc.d/S90synthetic-private-name", "synthetic-secret-body");
    let open = fs.open;
    let readfile = fs.readfile;
    fs.open = () => die("file bodies must not be opened");
    fs.readfile = () => die("file bodies must not be read");
    query("{}");
    let result = services.collect(root);
    stub.restore();
    fs.open = open;
    fs.readfile = readfile;
    t.ok(has(result, "incomplete", "autostart-link-target-unverified"));
    t.ok(has(result, "incomplete", "unclassified-autostart-entry"));
    t.excludes(sprintf("%J", result), "synthetic-secret");
    t.excludes(sprintf("%J", result), "synthetic-private-name");
});

t.test("unsafe autostart parents and symlink directories are refused", () => {
    let root = fixture();
    fs.chmod(root + "/etc", 0777);
    query("{}");
    let unsafe = services.collect(root);
    stub.restore();
    t.ok(has(unsafe, "incomplete", "autostart-directory-unavailable"));
    fs.chmod(root + "/etc", 0755);
    fs.rmdir(root + "/etc/rc.d");
    fs.symlink(root + "/synthetic-private-dir", root + "/etc/rc.d");
    query("{}");
    let linked = services.collect(root);
    stub.restore();
    t.ok(has(linked, "incomplete", "autostart-directory-unavailable"));
    t.excludes(sprintf("%J", linked), "synthetic-private-dir");
});

t.test("writable and hardlinked startup entries cannot be trusted as enabled scripts", () => {
    let root = fixture();
    let path = root + "/etc/rc.d/S95podkop";
    fs.writefile(path, "synthetic-private-init-body");
    fs.chmod(path, 0777);
    query("{}");
    let writable = services.collect(root);
    stub.restore();
    fs.chmod(path, 0755);
    t.eq(stub.real.system("ln '" + path + "' '" + root + "/alias'"), 0);
    query("{}");
    let linked = services.collect(root);
    stub.restore();
    t.ok(has(writable, "incomplete", "autostart-entry-unverified"));
    t.ok(has(linked, "incomplete", "autostart-entry-unverified"));
    t.eq(fs.readfile(path), "synthetic-private-init-body");
});

t.test("a link inode changed during target inspection is incomplete", () => {
    let root = fixture();
    let path = root + "/etc/rc.d/S95podkop";
    fs.symlink("../init.d/podkop", path);
    let lstat = fs.lstat;
    let readlink = fs.readlink;
    let changed = false;
    fs.readlink = (name) => { let value = readlink(name); changed = true; return value; };
    fs.lstat = (name) => { let info = lstat(name); if (changed && name == path) info.inode++; return info; };
    query("{}");
    let result = services.collect(root);
    stub.restore();
    fs.lstat = lstat;
    fs.readlink = readlink;
    t.ok(has(result, "incomplete", "autostart-entry-changed"));
});

t.test("directory entry budget, read errors and node changes close handles and refuse coverage", () => {
    let root = fixture();
    let opendir = fs.opendir;
    let lstat = fs.lstat;
    let closed = 0;
    let entries = 0;
    fs.opendir = () => ({ read: () => { entries++; return "S90private-unknown"; }, close: () => { closed++; return true; } });
    query("{}");
    let limit = services.collect(root);
    stub.restore();
    let first_entries = entries;
    let first_closed = closed;
    fs.opendir = () => ({ read: () => die("synthetic-private-read-error"), close: () => { closed++; return true; } });
    query("{}");
    let error = services.collect(root);
    stub.restore();
    let second_closed = closed;
    let changed = false;
    fs.opendir = () => ({ read: () => null, close: () => { closed++; changed = true; return true; } });
    fs.lstat = (path) => {
        let info = lstat(path);
        if (changed && path == root + "/etc/rc.d") info.inode++;
        return info;
    };
    query("{}");
    let raced = services.collect(root);
    stub.restore();
    fs.opendir = opendir;
    fs.lstat = lstat;
    t.eq(first_entries, 4096);
    t.eq(first_closed, 1);
    t.ok(has(limit, "incomplete", "autostart-directory-entry-limit"));
    t.eq(second_closed, 2);
    t.ok(has(error, "incomplete", "autostart-directory-read-failed"));
    t.eq(closed, 3);
    t.ok(has(raced, "incomplete", "autostart-directory-changed"));
    t.excludes(sprintf("%J", error), "synthetic-private-read-error");
});

t.test("pipe read failures close their handle and do not leak exception contents", () => {
    let root = fixture();
    let popen = fs.popen;
    let closed = false;
    fs.popen = () => ({ read: () => die("synthetic-private-pipe-error"), close: () => { closed = true; return 0; } });
    let result = services.collect(root);
    fs.popen = popen;
    t.eq(closed, true);
    t.ok(has(result, "incomplete", "service-query-failed"));
    t.excludes(sprintf("%J", result), "synthetic-private-pipe-error");
});

t.done();
