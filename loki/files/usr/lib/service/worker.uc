// A long-lived process procd supervises and respawns. Its recorded pid is checked against the
// command line, so a pid the kernel reused is never signalled.
//
// worker: { name, command, pid_file, env, data }

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");

function recorded_pid(worker) {
    return trim(fs.readfile(worker.pid_file) ?? "");
}

function is_worker(worker, pid) {
    return common.pid_alive(pid) &&
        index(fs.readfile("/proc/" + pid + "/cmdline") ?? "", "\0" + join("\0", worker.command) + "\0") >= 0;
}

function payload(worker) {
    let instance = {
        command: worker.command,
        env: worker.env ?? {},
        respawn: [ "3600", "5", "0" ],
        stderr: true
    };
    if (worker.data != null)
        instance.data = worker.data;
    return { name: worker.name, instances: { [worker.instance ?? "worker"]: instance } };
}

function running(worker) {
    return is_worker(worker, recorded_pid(worker));
}

// procd keeps an instance's data but does not restart it when later data differs, so the
// caller compares it.
function current(worker) {
    if (!running(worker))
        return false;
    let services = common.parse_json(exec.output([ "ubus", "call", "service", "list", sprintf("%J", { name: worker.name, verbose: true }) ]));
    let instance = services?.[worker.name]?.instances?.[worker.instance ?? "worker"];
    return type(instance) == "object" && sprintf("%J", instance.data) == sprintf("%J", worker.data);
}

function unregistered(worker) {
    if (exec.ok([ "ubus", "call", "service", "delete", sprintf("%J", { name: worker.name }) ]))
        return true;
    let services = common.parse_json(exec.output([ "ubus", "call", "service", "list", sprintf("%J", { name: worker.name }) ]));
    return type(services) == "object" && services[worker.name] == null;
}

// procd signals the process when the service goes; one that outlives that is
// terminated, and killed if it still does not go.
function stop(worker) {
    if (!unregistered(worker))
        return false;

    let pid = recorded_pid(worker);
    if (common.pid_alive(pid) && is_worker(worker, pid)) {
        for (let i = 0; i < 3 && is_worker(worker, pid); i++)
            sleep(1000);
        if (is_worker(worker, pid)) {
            exec.ok([ "kill", pid ]);
            sleep(1000);
            if (is_worker(worker, pid))
                exec.ok([ "kill", "-KILL", pid ]);
        }
    }
    fs.unlink(worker.pid_file);
    return true;
}

function start(worker) {
    if (!stop(worker) || !common.ensure_dir(common.parent_dir(worker.pid_file)))
        return false;
    if (!exec.ok([ "ubus", "call", "service", "add", sprintf("%J", payload(worker)) ]))
        return false;

    for (let i = 0; i < 5; i++) {
        if (is_worker(worker, recorded_pid(worker)))
            return true;
        sleep(1000);
    }
    stop(worker);
    return false;
}

// Called by the worker process itself once it is up, and on its way out.
function announce(worker) {
    return common.ensure_dir(common.parent_dir(worker.pid_file)) &&
        common.write_file(worker.pid_file, common.own_pid() + "\n");
}

function retire(worker) {
    if (recorded_pid(worker) == common.own_pid())
        fs.unlink(worker.pid_file);
}

return { start, stop, announce, retire, payload, is_worker, running, current };
