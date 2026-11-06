let t = require("t");
let fs = require("fs");
let stub = require("stub");
let context = require("service.ruleset_context");
let sync = require("nft.ruleset_sync");
let runtime = require("singbox.runtime");
let health = require("service.health");
let credential = require("service.gateway_secret");

let sequence = 100;
credential.generate = () => sprintf("%064x", ++sequence);

function fixture() {
    let root = stub.tmpdir();
    context.paths.base = root + "/runtime";
    sync.paths.planned_stop = root + "/planned-stop";
    sync.paths.lock = root + "/lifecycle.lock";
    let active = { generation: sprintf("%064x", 1), sections: [],
        config_path: "/etc/loki-core/config.json", config_digest: sprintf("%064x", 2),
        nft_digest: sprintf("%064x", 3), controller: {
            endpoint: "/tmp/loki/controller.sock", secret: sprintf("%064x", 4) } };
    t.ok(context.write({ schema: 1, phase: "applying", active: null, candidate: active }));
    active = { ...active, pid: "123", start_ticks: "456",
        command: [ "/usr/bin/loki-core", "run", "-c", active.config_path ] };
    t.ok(context.write({ schema: 1, phase: "ready", active, candidate: null }));
    runtime.identity = () => active;
    runtime.file_digest = () => active.config_digest;
    health.sing_box_runtime_ports_ready = () => true;
    return { root, active };
}

t.test("an unreadable planned-stop marker cannot be mistaken for its confirmed absence", () => {
    let state = fixture();
    t.eq(sync.ready_context(), state.active);
    let denied = state.root + "/denied";
    fs.mkdir(denied, 0000);
    let lstat = fs.lstat;
    fs.lstat = (path) => lstat(path == sync.paths.planned_stop ? denied + "/marker" : path);
    let result = stub.capture(() => sync.ready_context());
    fs.lstat = lstat;
    fs.chmod(denied, 0700);
    t.eq(result.result, null);
    t.eq(result.stdout + result.stderr, "");
    t.eq(context.read().model.active, state.active);
    t.eq(sync.ready_context(), state.active);
});

t.test("an existing marker or unavailable core proof refuses ready repair without replacing its generation", () => {
    let state = fixture();
    fs.symlink(state.root + "/missing", sync.paths.planned_stop);
    t.eq(sync.ready_context(), null);
    t.eq(fs.lstat(sync.paths.planned_stop).type, "link");
    fs.unlink(sync.paths.planned_stop);
    runtime.file_digest = () => null;
    t.eq(sync.ready_context(), null);
    t.eq(context.read().model.active, state.active);
});

t.test("ready verification reuses a pinned document and refuses its atomic replacement", () => {
    let state = fixture();
    let pinned = context.open();
    t.eq(pinned.error, null);
    let read = context.read;
    context.read = () => { die("the pinned document must not be parsed twice"); };
    let active = sync.ready_context(pinned);
    context.read = read;
    t.eq(active, state.active);
    t.ok(context.write({ schema: 1, phase: "stopped", active: null, candidate: null }));
    t.eq(sync.ready_context(pinned), null);
    t.ok(context.close(pinned));
});

t.done();
