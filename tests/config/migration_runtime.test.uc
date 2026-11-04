let t = require("t");
let fs = require("fs");
let stub = require("stub");
let repo = require("repo");
let uci = require("uci");
let migration = require("config.migration");
let uci_file = require("uci_file");

function sections(extra) {
    return [ { ".name": "settings", ".type": "settings", config_format: "loki", config_version: "2.0.0", ...(extra ?? {}) } ];
}

function router(data, text) {
    let dir = stub.tmpdir();
    migration.paths.config = dir + "/loki";
    migration.paths.internal_change = dir + "/internal-change";
    if (text != null)
        fs.writefile(migration.paths.config, text);
    uci.__reset();
    if (data != null)
        uci.__seed("loki", data);
    let logs = [];
    stub.commands([ stub.logger(logs) ]);
    return { dir, logs };
}

function run(start) {
    let result = stub.capture(() => start ? migration.start() : migration.main([ "migrate" ]));
    let commands = stub.command_lines();
    stub.restore();
    return { ...result, commands };
}

t.test("the package defaults identify LoKi and need no migration or cleanup", () => {
    let data = uci_file.parse(fs.readfile(repo.path("loki/files/etc/config/loki")));
    t.eq(data.settings.config_format, "loki");
    let setup = router(sections(), "own configuration");
    let result = run();
    t.eq([ result.result, result.commands, uci.__commits(), setup.logs ], [ 0, [], [], [] ]);
    t.eq(fs.readfile(migration.paths.config), "own configuration");
    t.eq(fs.lsdir(setup.dir), [ "loki" ]);
});

t.test("foreign, unsupported and ambiguous files are refused on install and start without writes", () => {
    let cases = [
        sections({ config_format: null }), sections({ config_format: "podkop" }),
        sections({ config_version: "1.0.2" }), sections({ config_version: "1.0.5" }),
        sections({ config_version: "9.0.0" }), sections({ config_version: "synthetic-secret\ninjected" }),
        [ ...sections(), { ".name": "x", ".type": "tunnel", private_key: "synthetic-secret" } ],
        [ ...sections(), { ".name": "another", ".type": "settings" } ]
    ];
    for (let data in cases)
        for (let start in [ false, true ]) {
            let setup = router(data, "synthetic-secret: original file");
            let result = run(start);
            t.eq(result.result, start ? false : 1);
            t.eq(uci.__commits(), []);
            t.eq(fs.readfile(migration.paths.config), "synthetic-secret: original file");
            t.eq(fs.lsdir(setup.dir), [ "loki" ]);
            t.eq(length(setup.logs), 1);
            t.excludes(result.stderr, "synthetic-secret");
            t.excludes(join("\n", setup.logs), "injected");
            t.eq(length(result.commands), 1, "only the error logger is called");
        }
});

t.test("missing and unreadable runtime files never become defaults", () => {
    for (let text in [ null, "broken UCI synthetic-secret" ]) {
        let setup = router(null, text);
        let result = run();
        t.eq(result.result, 1);
        t.eq(fs.readfile(migration.paths.config), text);
        t.eq(uci.__commits(), []);
        t.excludes(result.stderr, "synthetic-secret");
    }
});

t.test("read-only checks return a failing exit status and a bounded reason for unsupported files", () => {
    for (let extra in [ { config_format: null }, { config_version: "secret\nline" }, { config_version: "1.0.5" } ]) {
        let setup = router(sections(extra), "original");
        let capture = stub.capture(() => migration.main([ "check", migration.paths.config ]));
        stub.restore();
        let result = json(capture.stdout);
        t.eq([ capture.result, result.result ], [ 1, "fail" ]);
        t.excludes(capture.stdout, "secret");
        t.eq(uci.__commits(), []);
        t.eq(fs.readfile(migration.paths.config), "original");
        t.eq(fs.lsdir(setup.dir), [ "loki" ]);
    }
});

t.test("repeated current checks and starts leave the same file and state intact", () => {
    let setup = router(sections(), "own configuration");
    for (let i = 0; i < 3; i++) {
        t.eq(migration.start(), true);
        t.eq(migration.check(migration.paths.config), { result: "current", to: "2.0.0" });
    }
    t.eq(stub.command_lines(), []);
    stub.restore();
    t.eq(uci.__commits(), []);
    t.eq(fs.lsdir(setup.dir), [ "loki" ]);
});

t.done();
