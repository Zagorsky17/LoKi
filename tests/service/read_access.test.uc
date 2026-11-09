let t = require("t");
let fs = require("fs");
let repo = require("repo");
let stub = require("stub");
let cli = require("service.cli");
let rpc = require("service.rpc");

t.test("RPC ACL grants explicit operations without an executable or raw UCI grant", () => {
    let acl = json(fs.readfile(repo.path("luci-app-loki/root/usr/share/rpcd/acl.d/luci-app-loki.json")))["luci-app-loki"];
    t.eq(acl.read.file, null);
    t.eq(acl.write.file["/usr/bin/loki"], null);
    t.contains(acl.read.ubus.loki, "rpc_read");
    t.excludes(acl.read.ubus.loki, "rpc_write");
    t.excludes(acl.read.ubus.loki, "config_private");
    t.contains(acl.write.ubus.loki, "rpc_write");
    t.contains(acl.write.ubus.loki, "config_private");
    t.excludes(acl.read.uci, "loki");
    t.eq(acl.write.uci.loki, [ "read", "write" ]);
    t.eq(acl.read.ubus["loki.installer"], [ "read" ]);
    t.eq(acl.write.ubus["loki.installer"], [ "input", "stop" ]);
});

t.test("the reader refuses writes, raw exports and malformed argument forms before dispatch", () => {
    let commands = [];
    stub.commands([ [ /.*/, (argv) => { push(commands, argv); return { stdout: "{}" }; } ] ]);
    for (let args in [ [ "start" ], [ "installer_run", "id" ], [ "installer_start", "update", "", "0", "ru" ],
        [ "installer_start", "check", "", "1", "en" ], [ "installer_start", "check", "", "0", "en", "extra" ],
        [ "get_system_info", "extra" ], [ "report", "raw", "{}" ], [ "show_config", "raw" ], [ "show_config", "masked", "extra" ],
        [ "clash_api", "PUT", "/proxies/Node", "{}" ], [ "clash_api", "DELETE", "/connections", "" ],
        [ "clash_api", "DELETE", "/connections/connection-1", "" ],
        [ "clash_api", "GET", "/proxies/Node/link", "" ], [ "clash_api", "GET", "/proxies\r\nPUT /", "" ],
        [ "clash_api", "GET", "/proxies", "{}" ], [ "clash_api", "GET", "/proxies" + chr(0), "" ],
        [ "installer_status", "-1" ], [ "installer_status", "0; touch synthetic" ] ]) {
        let result = stub.capture(() => rpc.run(args, "/lib", "rpc_read"));
        t.ok(result.result != 0, sprintf("%J", args));
    }
    t.eq(filter(commands, (argv) => argv[0] != "logger"), []);
    t.ok(length(commands) > 0, "refused requests leave syslog evidence");
    stub.restore();
});

t.test("read snapshots preserve diagnostics while active probes require write", () => {
    for (let args in [ [ "get_system_info" ], [ "get_ui_state" ], [ "check_service" ], [ "clash_summary" ],
        [ "report", "masked", "{}" ], [ "show_config", "masked" ], [ "installer_status", "0" ],
        [ "installer_start", "check", "", "0", "en" ], [ "clash_api", "GET", "/proxies", "" ],
        [ "clash_api", "GET", "/providers/proxies", "" ], [ "clash_api", "GET", "/connections", "" ] ])
        t.eq(cli.read_allowed(args), true, sprintf("%J", args));
    for (let path in [ "/config", "/providers/rules", "/proxies/Node/link", "/proxies/Node/delay?timeout=1", "/proxies/Node/exit?timeout=1&method=PUT", "/proxies/../link", "/proxies\tGET/" ])
        t.eq(cli.read_allowed([ "clash_api", "GET", path, "" ]), false, path);
    for (let path in [ "/proxies/Node/delay?url=https%3A%2F%2Fexample.invalid&timeout=1000", "/proxies/Node/exit?timeout=1000" ]) {
        t.eq(cli.read_allowed([ "clash_api", "GET", path, "" ]), false, path);
        t.eq(cli.write_allowed([ "clash_api", "GET", path, "" ]), true, path);
    }
});

t.test("Monitoring close-one and close-all require write while Logs remains readable", () => {
    for (let path in [ "/connections", "/connections/connection-1" ]) {
        t.eq(cli.read_allowed([ "clash_api", "DELETE", path, "" ]), false);
        t.eq(cli.write_allowed([ "clash_api", "DELETE", path, "" ]), true);
    }
    t.eq(cli.read_allowed([ "check_logs" ]), true);
});

t.done();
