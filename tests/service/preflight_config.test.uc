let t = require("t");
let fs = require("fs");
let stub = require("stub");
let uci = require("uci");
let reader = require("service.preflight_config");

function scratch() {
    let path = stub.tmpdir();
    fs.chmod(path, 0700);
    return path;
}

function has(result, state, reason) {
    return length(filter(result, (item) => item.state == state && item.reason == reason)) > 0;
}

t.test("a fixed private UCI cursor parses a staged config without host overlays or writes", () => {
    uci.__reset();
    uci.__seed("loki", [ { ".name": "settings", ".type": "settings",
        config_format: "loki", config_version: "2.0.0",
        dns_server: [ "77.88.8.8" ], bootstrap_dns_server: [ "77.88.8.8" ] } ]);
    let root = scratch();
    let real = uci.cursor;
    let paths = [];
    uci.cursor = (config, delta, override) => {
        push(paths, [ config, delta, override ]);
        t.eq(fs.readfile(config + "/loki"), "config settings 'settings'\n");
        t.eq(fs.lstat(config + "/loki").mode & 0777, 0600);
        return real();
    };
    let result = reader.check("config settings 'settings'\n", root);
    uci.cursor = real;
    t.eq(paths, [ [ root + "/config", root + "/delta", "" ] ]);
    t.ok(has(result, "checked", "uci-syntax-checked"));
    t.ok(has(result, "checked", "uci-schema-checked"));
    t.ok(has(result, "incomplete", "candidate-core-unverified"));
    t.eq(fs.lstat(root + "/config"), null);
    t.eq(fs.lstat(root + "/delta"), null);
    t.eq(uci.__commits(), []);
});

t.test("without a verified core tag set the syntax may pass but validation stays incomplete", () => {
    uci.__reset();
    uci.__seed("loki", [ { ".name": "settings", ".type": "settings",
        config_format: "loki", config_version: "2.0.0",
        dns_server: [ "77.88.8.8" ], bootstrap_dns_server: [ "77.88.8.8" ] } ]);
    let result = reader.check("config settings 'settings'\n", scratch());
    t.ok(has(result, "checked", "uci-syntax-checked"));
    t.ok(has(result, "checked", "uci-schema-checked"));
    t.ok(has(result, "checked", "uci-values-checked"));
    t.ok(has(result, "incomplete", "candidate-core-unverified"));
});

t.test("a current schema with invalid values cannot report checked candidate values", () => {
    uci.__reset();
    uci.__seed("loki", [ { ".name": "settings", ".type": "settings",
        config_format: "loki", config_version: "2.0.0", dns_timeout: "synthetic-secret",
        dns_server: [ "77.88.8.8" ], bootstrap_dns_server: [ "77.88.8.8" ] } ]);
    let root = scratch();
    let result = reader.check("config settings 'settings'\n", root);
    t.ok(has(result, "checked", "uci-schema-checked"));
    t.ok(!has(result, "checked", "uci-values-checked"));
    t.ok(has(result, "incomplete", "candidate-config-values-invalid"));
    t.excludes(sprintf("%J", result), "synthetic-secret");
    t.eq(fs.lstat(root + "/config"), null);
    t.eq(fs.lstat(root + "/delta"), null);
    t.eq(uci.__commits(), []);
});

t.test("a foreign or unsupported candidate schema is refused without logging its values", () => {
    for (let values in [
        { config_format: "forkop", config_version: "2.0.0", reason: "foreign" },
        { config_format: "loki", config_version: "2.0.1", reason: "newer" },
        { config_format: "loki", config_version: "", reason: "missing" }
    ]) {
        uci.__reset();
        uci.__seed("loki", [ { ".name": "settings", ".type": "settings",
            config_format: values.config_format, config_version: values.config_version,
            cache_path: "synthetic-secret" } ]);
        let result = reader.check("config settings 'settings'\n", scratch());
        t.ok(has(result, "checked", "uci-syntax-checked"));
        t.ok(has(result, "incomplete", "candidate-schema-" + values.reason));
        t.ok(!has(result, "checked", "uci-schema-checked"));
        t.ok(!has(result, "incomplete", "candidate-core-unverified"));
        t.excludes(sprintf("%J", result), "synthetic-secret");
        t.eq(uci.__commits(), []);
    }
});

t.test("a failed isolated section read leaves the candidate incomplete and removes its copy", () => {
    let root = scratch();
    let real = uci.cursor;
    uci.cursor = () => ({ load: () => true, foreach: () => die("synthetic-secret") });
    let result = reader.check("config settings 'settings'\n", root);
    uci.cursor = real;
    t.ok(has(result, "checked", "uci-syntax-checked"));
    t.ok(has(result, "incomplete", "candidate-schema-unavailable"));
    t.excludes(sprintf("%J", result), "synthetic-secret");
    t.eq(fs.lstat(root + "/config"), null);
    t.eq(fs.lstat(root + "/delta"), null);
});

t.test("a native section iterator error cannot accept a partial current schema", () => {
    let real = uci.cursor;
    uci.cursor = () => ({ load: () => true, foreach: (name, type_name, visit) => {
        visit({ ".name": "settings", ".type": "settings", config_format: "loki", config_version: "2.0.0" });
        return null;
    } });
    let result = reader.check("config settings 'settings'\n", scratch());
    uci.cursor = real;
    t.ok(has(result, "checked", "uci-syntax-checked"));
    t.ok(has(result, "incomplete", "candidate-schema-unavailable"));
    t.ok(!has(result, "checked", "uci-schema-checked"));
});

t.test("bounds, unsafe scratch and native load failures refuse without leaking input", () => {
    let root = scratch();
    t.ok(has(reader.check("x\u0000secret", root), "incomplete", "candidate-config-invalid"));
    t.ok(has(reader.check(sprintf("%1048577s", "x"), root), "incomplete", "candidate-config-size-limit"));
    fs.chmod(root, 0755);
    t.ok(has(reader.check("secret", root), "incomplete", "scratch-unsafe"));
    fs.chmod(root, 0700);
    let real = uci.cursor;
    uci.cursor = () => ({ load: () => false });
    let failed = reader.check("secret", root);
    uci.cursor = real;
    t.ok(has(failed, "incomplete", "uci-load-failed"));
    t.excludes(sprintf("%J", failed), "secret");
    t.eq(fs.lstat(root + "/config"), null);
    t.eq(fs.lstat(root + "/delta"), null);
});

t.test("write and native module failures clean staged secrets", () => {
    let root = scratch();
    let data = "config settings 'settings'\n option cache_path 'synthetic-secret'\n";
    let open = fs.open;
    fs.open = (path, ...args) => path == root + "/config/loki" ? null : open(path, ...args);
    let write_failed = reader.check(data, root);
    fs.open = open;
    t.ok(has(write_failed, "incomplete", "scratch-write-failed"));
    t.eq(fs.lstat(root + "/config"), null);

    let real = uci.cursor;
    uci.cursor = () => die("synthetic-secret-native-error");
    let native_failed = reader.check(data, root);
    uci.cursor = real;
    t.ok(has(native_failed, "incomplete", "uci-unavailable"));
    t.excludes(sprintf("%J", native_failed), "synthetic-secret");
    t.eq(fs.lstat(root + "/config"), null);

});

t.test("a failed close refuses a staged config even when its bytes appear complete", () => {
    let root = scratch();
    let real = fs.open;
    fs.open = (path, ...args) => {
        let file = real(path, ...args);
        return { write: (data) => file.write(data), close: () => { file.close(); return null; } };
    };
    uci.__reset();
    uci.__seed("loki", [ { ".name": "settings", ".type": "settings" } ]);
    let result = reader.check("config settings 'settings'\n", root);
    fs.open = real;
    t.ok(has(result, "incomplete", "scratch-write-failed"));
    t.eq(fs.lstat(root + "/config"), null);
});

t.test("a preexisting config symlink cannot make cleanup delete another file", () => {
    let root = scratch();
    let other = scratch();
    fs.writefile(other + "/loki", "keep-sentinel");
    fs.symlink(other, root + "/config");
    let result = reader.check("config settings 'settings'\n", root);
    t.eq(fs.readfile(other + "/loki"), "keep-sentinel");
    t.eq(fs.lstat(root + "/config").type, "link");
    t.ok(has(result, "incomplete", "scratch-write-failed"));
});

t.done();
