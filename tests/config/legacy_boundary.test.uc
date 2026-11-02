let t = require("t");
let fs = require("fs");
let uci = require("uci");
let stub = require("stub");
let migration = require("config.migration");

t.test("a Forkop 2.0.0 configuration cannot become a LoKi configuration by its version", () => {
    let decision = migration.decide({ sections: [
        { ".name": "settings", ".type": "settings", config_version: "2.0.0" }
    ] });
    t.eq(decision.result, "reject");
    t.eq(decision.reason, "foreign");
});

t.test("installing the current LoKi schema never cleans another application's state", () => {
    let dir = stub.tmpdir();
    migration.paths.config = dir + "/forkop";
    migration.paths.internal_change = dir + "/internal-change";
    fs.writefile(migration.paths.config, "current LoKi configuration");
    uci.__reset();
    uci.__seed("forkop", [
        { ".name": "settings", ".type": "settings", config_format: "loki", config_version: "2.0.0" }
    ]);
    let commands = [];
    stub.commands([ [ () => true, (argv) => { push(commands, argv); return {}; } ] ]);
    let run = stub.capture(() => migration.main([ "migrate" ]));
    stub.restore();
    t.eq(run.result, 0, run.stderr);
    t.eq(commands, [], "no crontab, dnsmasq, cleanup or network commands");
    t.eq(uci.__commits(), []);
    t.eq(fs.readfile(migration.paths.config), "current LoKi configuration");
    t.eq(fs.stat(migration.paths.internal_change), null);
});

t.test("the retired fixture conversion command is unavailable and performs no operations", () => {
    stub.commands([]);
    let run = stub.capture(() => migration.main([ "migrate-fixture", "/tmp/synthetic-secret" ]));
    t.eq(stub.command_lines(), []);
    stub.restore();
    t.eq(run.result, 2);
    t.excludes(run.stderr, "synthetic-secret");
});

t.done();
