// Exercise a synthetic future LoKi step without adding a fictional release to the product.
let t = require("t");
let fs = require("fs");
let stub = require("stub");
let repo = require("repo");
let uci = require("uci");

function future(step) {
    let source = fs.readfile(repo.path("loki/files/usr/lib/config/migration.uc"));
    source = replace(source, "const TARGET_CONFIG_VERSION", 'push(RELEASES, { version: "2.2.0", types: RELEASES[0].types, steps: [ ' + step + ' ] });\nconst TARGET_CONFIG_VERSION');
    return loadstring(source)();
}

function model() {
    return { sections: [
        { ".name": "settings", ".type": "settings", config_format: "loki", config_version: "2.0.0" },
        { ".name": "main", ".type": "section", label: "Original", secret: "synthetic-secret" }
    ] };
}

function runtime(migration, extra) {
    let dir = stub.tmpdir();
    migration.paths.config = dir + "/loki";
    migration.paths.internal_change = dir + "/internal-change";
    fs.writefile(migration.paths.config, "original synthetic-secret");
    uci.__reset();
    uci.__seed("loki", model().sections);
    let logs = [];
    stub.commands([ ...(extra ?? []), stub.logger(logs), [ /md5sum/, { stdout: "0123456789abcdef0123456789abcdef  -\n" } ] ]);
    return { dir, logs };
}

t.test("future own steps run on a copy, advance the version and reject unknown intermediate versions", () => {
    let migration = future('(model, ctx) => { model.sections[1].label = "Updated"; push(ctx.warnings, "A setting changed"); }');
    let original = model();
    t.eq(migration.decide(original), { result: "migrate", from: "2.0.0" });
    let result = migration.migrate(original, "2.0.0");
    t.eq(result.model.sections[0].config_version, "2.2.0");
    t.eq(result.model.sections[1].label, "Updated");
    t.eq(result.warnings, [ "A setting changed" ]);
    t.eq(original.sections[1].label, "Original");
    original.sections[0].config_version = "2.1.0";
    t.eq(migration.decide(original).reason, "unknown");
    original.sections[0].config_format = "loki";
    t.eq(migration.migrate(original, "2.1.0").model, null);
});

t.test("a future runtime migration keeps a private backup and stamps only its own commit", () => {
    let migration = future('(model) => { model.sections[1].label = "Updated"; }');
    let setup = runtime(migration);
    let run = stub.capture(() => migration.main([ "migrate" ]));
    stub.restore();
    t.eq(run.result, 0, run.stderr);
    t.eq(uci.__commits(), [ "loki" ]);
    let backups = filter(fs.lsdir(setup.dir), (name) => match(name, /^loki\./));
    t.eq(length(backups), 1);
    t.eq(fs.readfile(setup.dir + "/" + backups[0]), "original synthetic-secret");
    t.eq(fs.stat(setup.dir + "/" + backups[0]).mode & 0777, 0600);
    t.ok(fs.stat(migration.paths.internal_change) != null);
    t.excludes(run.stderr, "synthetic-secret");
    t.eq(uci.__sections("loki")[0].config_version, "2.2.0");
    t.eq(uci.__sections("loki")[1].label, "Updated");
    stub.commands([]);
    t.eq(migration.start(), true, "a second start is a no-op");
    t.eq(stub.command_lines(), []);
    stub.restore();
});

t.test("failed or malformed future steps preserve the source and never commit", () => {
    for (let step in [ '(model) => { model.sections[1].label = "partial"; die("synthetic-secret\\ninjected"); }',
        '(model) => { model.sections = []; }', '(model) => { model.sections[0].config_format = "other"; }' ]) {
        let migration = future(step);
        let setup = runtime(migration);
        let run = stub.capture(() => migration.main([ "migrate" ]));
        stub.restore();
        t.eq(run.result, 1);
        t.eq(uci.__commits(), []);
        t.eq(fs.readfile(migration.paths.config), "original synthetic-secret");
        t.eq(fs.stat(migration.paths.internal_change), null);
        t.excludes(run.stderr, "synthetic-secret");
        t.eq(fs.lsdir(setup.dir), [ "loki" ]);
    }
});

t.test("backup and UCI commit failures stop a future migration", () => {
    let migration = future('(model) => { model.sections[1].label = "Updated"; }');
    let real_write = fs.writefile;
    let real_cursor = uci.cursor;
    let real_chmod = fs.chmod;
    let real_rename = fs.rename;
    for (let failure in [ "backup", "chmod", "rename", "load", "set", "commit" ]) {
        let setup = runtime(migration);
        if (failure == "backup")
            fs.writefile = (path, data) => match(path, /\.new$/) ? null : real_write(path, data);
        else if (failure == "chmod")
            fs.chmod = () => false;
        else if (failure == "rename")
            fs.rename = () => false;
        else
            uci.cursor = (...args) => {
                let cursor = real_cursor(...args);
                if (failure == "load") cursor.load = () => false;
                if (failure == "set") cursor.set = () => false;
                if (failure == "commit") cursor.commit = () => false;
                return cursor;
            };
        let run = stub.capture(() => migration.main([ "migrate" ]));
        fs.writefile = real_write;
        fs.chmod = real_chmod;
        fs.rename = real_rename;
        uci.cursor = real_cursor;
        stub.restore();
        t.eq(run.result, 1);
        t.eq(uci.__commits(), []);
        t.eq(uci.__sections("loki")[1].label, "Original");
        t.eq(fs.readfile(migration.paths.config), "original synthetic-secret");
        t.eq(fs.stat(migration.paths.internal_change), null);
        for (let name in fs.lsdir(setup.dir))
            t.eq(match(name, /\.new$/), null, "no partial backup remains");
    }
});

t.test("a future step that only advances its schema keeps no redundant copy", () => {
    let migration = future('() => {}');
    let setup = runtime(migration);
    let run = stub.capture(() => migration.main([ "migrate" ]));
    stub.restore();
    t.eq(run.result, 0, run.stderr);
    t.eq(filter(fs.lsdir(setup.dir), (name) => match(name, /^loki\./)), []);
    t.eq(uci.__sections("loki")[0].config_version, "2.2.0");
});

t.done();
