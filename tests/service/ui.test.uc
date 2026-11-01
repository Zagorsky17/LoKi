let t = require("t");
let stub = require("stub");
let fs = require("fs");
let common = require("core.common");
let fixture = require("fixture");
let lock = require("service.lock");
let health = require("service.health");
let ui = require("service.ui");
let installer = require("service.installer");

let me = common.own_pid();

function fresh() {
    let dir = stub.tmpdir();
    ui.paths.service_actions = dir + "/ui-state/service-actions";
    ui.paths.service_action_lock = dir + "/ui-state/service-actions.lock";
    ui.paths.reload_lock = dir + "/forkop.reload.lock";
    ui.paths.pending_reload = dir + "/reload.pending";
    ui.paths.rc_dir = dir + "/rc.d";
    installer.paths.state = dir + "/installer/state.json";
    return dir;
}

// A process whose command line names marker; the second command keeps the shell from
// replacing itself with sleep.
function live_process(marker) {
    let pipe = stub.real.popen("sh -c 'sleep 30; :' " + marker + " >/dev/null 2>&1 & echo $!", "r");
    let pid = trim(pipe.read("all"));
    pipe.close();
    return pid;
}

function job(id) {
    return common.read_json_file(ui.paths.service_actions + "/" + id + ".json");
}

t.test("an action opens one job at a time and is finished from the command's status", () => {
    fresh();
    let first = ui.begin("reload", "initd", me);
    t.eq(first.status, 0);
    t.eq([ job(first.job_id).running, job(first.job_id).action, job(first.job_id).pid ], [ true, "reload", me ]);
    t.eq(ui.begin("stop", "initd", me), { status: 2, job_id: "" }, "a second action while the first runs");
    t.eq(ui.active_action(), "reload");

    ui.finish("reload", first.job_id, 0);
    t.eq([ job(first.job_id).running, job(first.job_id).success, job(first.job_id).exit_code, job(first.job_id).message ],
        [ false, true, 0, "Service reload completed" ]);
    let second = ui.begin("stop", "ui", null);
    t.eq(second.status, 0, "the next action once the first finished");
    t.eq(job(second.job_id).pid, null, "a job opened without a pid records none");
    ui.finish("stop", second.job_id, 3);
    t.eq([ job(second.job_id).success, job(second.job_id).exit_code, job(second.job_id).message ], [ false, 3, "Service stop failed" ]);
    t.eq(ui.begin("dance", "ui", me).status, 1, "an action that is not one");
});

t.test("a job whose worker died is stale once its grace passed, and a finished one goes when acknowledged or old", () => {
    fresh();
    common.ensure_dir(ui.paths.service_actions);
    let path = (id) => ui.paths.service_actions + "/" + id + ".json";
    fs.writefile(path("dead"), sprintf("%J", { running: true, action: "start", pid: "999999", started_at: common.now_seconds() - 60 }));
    fs.writefile(path("young"), sprintf("%J", { running: true, action: "start", pid: "999999", started_at: common.now_seconds() }));
    fs.writefile(path("acked"), sprintf("%J", { running: false, action: "stop", acked_at: common.now_seconds() - 20 }));
    fs.writefile(path("fresh"), sprintf("%J", { running: false, action: "stop", acked_at: common.now_seconds() }));
    fs.writefile(path("broken"), "not json");
    fs.writefile(ui.paths.service_actions + "/acked.out", "sidecar");
    ui.refresh();
    t.eq([ job("dead").running, job("dead").success, job("dead").message ], [ false, false, "Service action worker exited unexpectedly" ]);
    t.eq(job("young").running, true, "a worker that may not have recorded itself yet");
    t.ok(job("acked") == null && fs.stat(ui.paths.service_actions + "/acked.out") == null, "an acknowledged job goes with its sidecars");
    t.ok(job("fresh") != null, "a job acknowledged a moment ago stays");
    t.ok(fs.stat(path("broken")) == null);
});

t.test("the page acknowledges a finished job, never a running one", () => {
    fresh();
    let begun = ui.begin("start", "ui", me);
    t.eq(ui.acknowledge(begun.job_id), { success: false, job_id: begun.job_id, message: "UI action is still running" });
    ui.finish("start", begun.job_id, 0);
    t.eq(ui.acknowledge(begun.job_id).message, "UI action acknowledged");
    t.ok(job(begun.job_id).acked_at > 0);
    t.eq(ui.acknowledge("gone").message, "UI action already acknowledged");
    t.eq(ui.acknowledge("../x").message, "Invalid UI action job id");
});

t.test("a page action runs the init script in a worker whose pid the job records", () => {
    fresh();
    stub.commands([ [ /service_action_worker/, { stdout: "31337\n" } ] ]);
    let started = ui.start_action("restart");
    let command = stub.calls()[0].argv;
    stub.restore();
    t.eq([ started.success, started.message ], [ true, "Service restart started" ]);
    t.eq(slice(command, -5), [ "/usr/bin/forkop", "service_action_worker", "restart", started.job_id, "" ]);
    t.eq(job(started.job_id).pid, "31337");
    t.eq(ui.start_action("restart").message, "Another service action is already running");
    t.eq(ui.start_action("dance").message, "Invalid service action");
});

t.test("the worker finishes its job from the init script and then runs a reload queued meanwhile", () => {
    fresh();
    let begun = ui.begin("start", "ui", me);
    lock.mark_request(ui.paths.pending_reload, "on_config_change");
    stub.commands([
        [ "env FORKOP_UI_ACTION_TRACKED=1 /etc/init.d/forkop start", { status: 0 } ],
        [ "logger", {} ],
        [ /service_action_worker' 'reload'/, { stdout: "4242\n" } ]
    ]);
    ui.worker("start", begun.job_id, "");
    let lines = stub.command_lines();
    stub.restore();
    t.eq(job(begun.job_id).success, true);
    t.ok(fs.stat(ui.paths.pending_reload) == null, "the queued reload is taken");
    t.ok(length(filter(lines, (l) => index(l, "service_action_worker reload") >= 0 && index(l, " pending") >= 0)) == 1, "and started as a job of its own");
    t.eq(ui.active_action(), "reload");
});

t.test("a queued reload waits while another reload holds the reload lock", () => {
    fresh();
    let begun = ui.begin("start", "ui", me);
    lock.mark_request(ui.paths.pending_reload, "on_config_change");
    lock.acquire(ui.paths.reload_lock, me);
    stub.commands([ [ "env FORKOP_UI_ACTION_TRACKED=1 /etc/init.d/forkop start", {} ] ]);
    ui.worker("start", begun.job_id, "");
    stub.restore();
    t.ok(fs.stat(ui.paths.pending_reload) != null);
    lock.release(ui.paths.reload_lock, me);
});

t.test("the state tells what the service is apart from what is being done to it", () => {
    fresh();
    fixture.seed({ server: [ { ".name": "a", enabled: "1" } ] });
    health.forkop_stably_running = () => true;
    health.sing_box_service_stable = () => true;
    common.ensure_dir(ui.paths.rc_dir);
    fs.symlink("/bin/sh", ui.paths.rc_dir + "/S99forkop");
    ui.begin("reload", "initd", me);
    let state = ui.current_state();
    t.eq(state.service.forkop, { running: 1, enabled: 1, status: "running & enabled", busy: "apply" });
    t.eq(state.service.sing_box, { running: 1, enabled: 0, status: "running but disabled" });
    t.eq(length(state.actions.service), 1);
    t.eq(keys(state.actions), [ "service" ]);
});

t.test("the state counts the servers and sections that run, as the generator decides it", () => {
    fresh();
    fixture.seed({
        server: [ { ".name": "a", enabled: "1" }, { ".name": "b", enabled: "0" }, { ".name": "never_saved" } ],
        section: [ { ".name": "s", action: "connection" }, { ".name": "t", action: "block", enabled: "1" }, { ".name": "off", enabled: "0" } ]
    });
    t.eq(ui.current_state().capabilities, { server_inbounds_enabled_count: 1, sections_enabled_count: 2 });
    fixture.seed({ server: [ { ".name": "a", enabled: "1" } ] });
    t.eq(ui.current_state().capabilities, { server_inbounds_enabled_count: 1, sections_enabled_count: 0 }, "a VPN server alone");
});

t.test("while the installer runs the service is busy with it and takes no action of the page", () => {
    fresh();
    fixture.seed({});
    health.forkop_stably_running = () => false;
    health.sing_box_service_stable = () => false;
    let runner = live_process("installer_run");
    common.ensure_dir(common.parent_dir(installer.paths.state));
    fs.writefile(installer.paths.state, sprintf("%J", { schema: 1, id: "run-1", action: "update", runner_pid: runner, finished_at: null }));
    t.eq(ui.current_state().service.forkop.busy, "install");
    t.eq(ui.begin("start", "initd", me), { status: 2, job_id: "" });
    t.eq(ui.start_action("restart"), { success: false, job_id: "", message: "The installer is running" });
    stub.real.system("kill " + runner);
    // SIGTERM is asynchronous; observe this fixture's exit before checking the service state.
    for (let tries = 0; tries < 100 && index(fs.readfile("/proc/" + runner + "/cmdline") ?? "", "installer_run") >= 0; tries++)
        sleep(10);
    t.eq(ui.current_state().service.forkop.busy, null, "a runner that died ends the run");
    t.eq(ui.begin("start", "initd", me).status, 0);
});

t.done();
