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

t.done();
