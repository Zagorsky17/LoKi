let t = require("t");
let stub = require("stub");
let fs = require("fs");
let fixture = require("fixture");
let packages = require("core.packages");
let health = require("service.health");
let diagnostics = require("diagnostics.runtime");

let dir = stub.tmpdir();
diagnostics.paths.rc_dir = dir + "/rc.d";
diagnostics.paths.luci_view = dir + "/luci";
diagnostics.paths.loki_config = dir + "/loki";
packages.paths.opkg_status = dir + "/missing-status";
packages.paths.sing_box_version = dir + "/loki-core-version";
packages.paths.sing_box_variant = dir + "/loki-core-variant";

t.test("the status is the stable runtime the page reads, in the same words", () => {
    health.loki_stably_running = () => true;
    t.eq(diagnostics.status(), { running: 1, enabled: 0, status: "running but disabled" });
    health.loki_stably_running = () => false;
    t.eq(diagnostics.status().status, "stopped & disabled");
});

t.test("the core version comes from what the core records while the package manager is locked", () => {
    fs.writefile(packages.paths.sing_box_version, "1.14.4-r6\n");
    fs.writefile(packages.paths.sing_box_variant, "full\n");
    fs.mkdir(diagnostics.paths.luci_view);
    fs.writefile(diagnostics.paths.luci_view + "/main.js", "var LOKI_LUCI_APP_VERSION = \"runtime-test\";\n");
    stub.commands([ [ "sh -c command -v apk", { status: 1 } ], [ /command -v/, {} ], [ "opkg", { status: 1 } ] ]);
    let info = diagnostics.system_info();
    stub.restore();
    t.eq([ info.sing_box_version, info.sing_box_variant, info.luci_app_version ], [ "1.14.4-r6", "full", "runtime-test" ]);
});

t.test("system info exposes only LoKi's validated page language", () => {
    fixture.seed({ settings: { ui_language: "ru" } });
    t.eq(diagnostics.system_info().ui_language, "ru");
    fixture.seed({ settings: { ui_language: "../de" } });
    t.eq(diagnostics.system_info().ui_language, "auto");
    fixture.seed({ settings: {} });
    t.eq(diagnostics.system_info().ui_language, "auto");
});

t.test("a masked configuration loses the server addresses the generated one names, and reads line by line", () => {
    let config = { outbounds: [ { type: "parser", tag: "Main/Vless node.example", link: "vless://uuid@node.example:443?security=reality#Vless" } ] };
    fs.writefile(dir + "/config.json", sprintf("%.2J\n", config));
    fixture.seed({ settings: { config_path: dir + "/config.json" } });
    fs.writefile(diagnostics.paths.loki_config, "config connection_link 'l1'\n\toption name 'Vless node.example'\n\toption uri 'vless://uuid@node.example:443'\n");

    let loki = diagnostics.show_config("masked");
    let sing_box = diagnostics.show_sing_box_config("masked");
    for (let text in [ loki, sing_box ])
        t.excludes(text, "node.example");
    t.contains(loki, "option name 'Vless MASKED'");
    t.contains(sing_box, "\"tag\": \"Main/Vless MASKED\"");
    t.eq(diagnostics.show_sing_box_config("raw"), sprintf("%.2J\n", config), "raw is the file as written");
});

t.test("raw and masked exports never expose the internal controller credential", () => {
    let key = fixture.CONTROLLER_SECRET;
    let config = { outbounds: [ { type: "socks", server: "proxy.example", password: "synthetic-user-password" } ],
        experimental: { clash_api: { external_controller: "127.0.0.1:9092", secret: key } },
        label: "prefix" + key + "suffix" };
    let path = dir + "/controller-config.json";
    let original = sprintf("%.2J\n", config);
    fs.writefile(path, original);
    fixture.seed({ settings: { config_path: path } });
    for (let visibility in [ "raw", "masked" ]) {
        let output = diagnostics.show_sing_box_config(visibility);
        t.excludes(output, key);
        let projected = json(output);
        t.ok(projected.experimental.clash_api.secret != key);
        if (visibility == "raw") {
            t.eq(projected.experimental.clash_api.secret, "SERVER_ONLY");
            t.eq(projected.label, "prefixSERVER_ONLYsuffix");
            t.eq(projected.outbounds[0].password, "synthetic-user-password");
        }
    }
    t.eq(fs.readfile(path), original);
});

t.test("a damaged configuration cannot escape controller redaction through the raw export", () => {
    let path = dir + "/damaged-controller-config.json";
    fixture.seed({ settings: { config_path: path } });
    for (let value in [ "broken " + fixture.CONTROLLER_SECRET, "null", "[]", "false" ]) {
        fs.writefile(path, value);
        for (let visibility in [ "raw", "masked" ]) {
            let failure = t.throws(() => diagnostics.show_sing_box_config(visibility));
            t.eq(failure.message, "The loki-core configuration is not a valid JSON object");
            t.excludes(failure.message, fixture.CONTROLLER_SECRET);
        }
        t.eq(fs.readfile(path), value);
    }
});

t.test("diagnostic logs never expose the private controller credential even in otherwise raw output", () => {
    let secret = require("service.gateway_secret");
    let original = secret.redactor;
    secret.redactor = () => (value) => join("SERVER_ONLY", split(value, fixture.CONTROLLER_SECRET));
    stub.commands([ [ "logread", { stdout: "user-password " + fixture.CONTROLLER_SECRET + "\n" } ] ]);
    let value = diagnostics.logs();
    stub.restore();
    secret.redactor = original;
    t.eq(value, "user-password SERVER_ONLY\n", "private controller log projection");
});

t.done();
