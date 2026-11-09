// A stand-in Clash API controller on a private Unix socket, in a process that leaves with
// the test: the backend talks to it over a real socket, and a test sets the reply and reads the
// requests it received.

let fs = require("fs");
let stub = require("stub");
let repo = require("repo");
let common = require("core.common");

function start() {
    let dir = stub.tmpdir();
    fs.chmod(dir, 0700);
    stub.real.system(sprintf("ucode '%s' '%s' '%s' >/dev/null 2>&1 &", repo.path("tests/lib/controller_server.uc"), dir, common.own_pid()));
    for (let i = 0; i < 250 && !fs.access(dir + "/port"); i++)
        sleep(20);
    let port = trim(fs.readfile(dir + "/port") ?? "");
    if (port == "")
        die("the stand-in controller did not start");

    return {
        endpoint: "/tmp/loki/controller.sock",
        path: dir + "/controller.sock",
        // { status, body, delay_ms } or { raw } for every request until the next call.
        reply: function(value) {
            fs.writefile(dir + "/reply", sprintf("%J", value));
        },
        requests: function() {
            return map(sort(fs.glob(dir + "/request.*")), (path) => fs.readfile(path));
        }
    };
}

// Keep native Unix and peer-credential coverage while redirecting only the fixed production path.
function redirect(path) {
    let socket = require("socket");
    let storage = require("core.cache_path");
    let fixed = require("singbox.constants").CLASH_API_CONTROLLER_SOCKET;
    let original = { connect: socket.connect, lstat: fs.lstat, validate: storage.validate };
    let state = { unavailable: false };
    fs.lstat = (name) => original.lstat(name == fixed ? path + (state.unavailable ? ".absent" : "") : name);
    storage.validate = (settings) => original.validate(settings.cache_path == fixed + ".owner" ? { cache_path: path + ".owner" } : settings);
    socket.connect = (host, port, options, timeout) => {
        if (host?.path != fixed || port != null)
            die("unexpected controller transport destination");
        return original.connect({ path }, port, options, timeout);
    };
    return state;
}

return { start, redirect };
