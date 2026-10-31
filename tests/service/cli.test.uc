let t = require("t");
let fs = require("fs");
let stub = require("stub");
let cli = require("service.cli");

function run(argv, status) {
    stub.commands([ [ () => true, { status: status ?? 0 } ] ]);
    let result = stub.capture(() => cli.main(argv, "/lib"));
    result.commands = stub.command_lines();
    stub.restore();
    return result;
}

t.test("start, stop, restart and reload go to the init script and return its status", () => {
    for (let verb in [ "start", "stop", "restart" ]) {
        let result = run([ verb ], 3);
        t.eq(result.commands, [ "/etc/init.d/forkop " + verb ]);
        t.eq(result.result, 3);
    }
    let reload = run([ "reload", "manual" ], 0);
    t.eq(reload.commands, [ "/etc/init.d/forkop reload manual" ]);
});

t.test("a command takes only the arguments it declares", () => {
    t.eq(run([ "reload", "manual", "extra" ]).commands, [ "/etc/init.d/forkop reload manual" ]);
});

t.test("a key material command answers the page with success and its fields, or with the reason", () => {
    stub.commands([ [ "sing-box generate reality-keypair", { stdout: "PrivateKey: a\nPublicKey: b\n" } ] ]);
    let good = stub.capture(() => cli.main([ "generate_reality_keypair" ], "/lib"));
    stub.commands([ [ "sing-box generate reality-keypair", { status: 1 } ] ]);
    let bad = stub.capture(() => cli.main([ "generate_reality_keypair" ], "/lib"));
    stub.restore();
    t.eq([ good.result, json(good.stdout) ], [ 0, { success: true, private_key: "a", public_key: "b" } ]);
    t.eq([ bad.result, json(bad.stdout) ], [ 1, { success: false, message: "Failed to generate Reality key pair" } ]);
});

t.test("autostart answers the page whether the switch moved or not", () => {
    let lifecycle = require("service.lifecycle");
    let dir = stub.tmpdir();
    lifecycle.paths.rc_dir = dir + "/rc.d";
    let on = stub.capture(() => cli.main([ "enable" ], "/lib"));
    let off = stub.capture(() => cli.main([ "disable" ], "/lib"));
    t.eq([ on.result, json(on.stdout) ], [ 0, { success: true } ]);
    t.eq([ off.result, json(off.stdout) ], [ 0, { success: true } ]);

    fs.writefile(dir + "/not-a-dir", "");
    lifecycle.paths.rc_dir = dir + "/not-a-dir/rc.d";
    let refused = stub.capture(() => cli.main([ "enable" ], "/lib"));
    t.eq([ refused.result, json(refused.stdout) ], [ 1, { success: false, message: "Could not enable autostart" } ]);
});

t.test("the log command answers an empty log with nothing, successfully", () => {
    stub.commands([ [ () => true, { status: 0, stdout: "" } ] ]);
    let empty = stub.capture(() => cli.main([ "check_logs" ], "/lib"));
    stub.commands([ [ () => true, { status: 0, stdout: "forkop: [info] up\n" } ] ]);
    let some = stub.capture(() => cli.main([ "check_logs" ], "/lib"));
    stub.restore();
    t.eq([ empty.result, empty.stdout ], [ 0, "" ]);
    t.eq([ some.result, some.stdout ], [ 0, "forkop: [info] up\n" ]);
});

t.test("an unknown or retired command prints the help and fails without running anything", () => {
    for (let name in [ "", "main", "get_sing_box_status", "service_action_status", "check_sing_box_logs", "check_nft",
        "generate_server_certificate", "get_tls_certificate_sha256", "generate_ssh_host_key",
        "component_action", "component_action_async", "component_action_status", "component_updates_if_due",
        "component_update_check_cache", "global_check", "check_proxy", "check_nft_rules", "check_fakeip", "check_sing_box",
        "check_dns_available", "check_inbounds", "check_inbounds_config" ]) {
        let result = run([ name ]);
        t.eq(result.result, 1, name);
        t.eq(result.commands, [], name);
        t.contains(result.stdout, "Available commands:");
    }
});

t.test("the help lists the public commands and hides the package hooks", () => {
    let help = run([ "help" ]).stdout;
    t.contains(help, "    get_ui_state");
    t.contains(help, "    ui_action_ack <job>");
    t.excludes(help, "package_postinst");
    t.excludes(help, "sing_box_crash_cleanup");
});

t.test("report defaults to masked JSON and only an explicit raw request returns secrets with a warning", () => {
    let fixture = require("fixture");
    let report = require("diagnostics.report");
    let dir = stub.tmpdir();
    report.paths.forkop_config = dir + "/report-config";
    fixture.seed({ settings: { mixed_proxy_password: "cli-report-secret" } });
    fs.writefile(report.paths.forkop_config, "config settings 'settings'\n\toption mixed_proxy_password 'cli-report-secret'\n");
    for (let args in [ [ "report" ], [ "report", "masked" ], [ "report", "typo" ], [ "report", "raw" ] ]) {
        let result = run(args);
        let value = json(result.stdout);
        let raw = args[1] == "raw";
        t.eq(result.result, 0);
        t.eq(value.visibility, raw ? "raw" : "masked");
        if (raw) {
            t.contains(value.notice, "UNMASKED REPORT");
            t.contains(value.forkop_config, "cli-report-secret");
        }
        else
            t.excludes(result.stdout, "cli-report-secret");
    }
});

t.done();
