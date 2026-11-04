// Modified for LoKi on 2026-11-03: product labels in user-facing messages.
let exec = require("core.exec");
let constants = require("core.constants");
let library = require("core.library");

// Only the init script's start registers the procd triggers Apply and WAN-up depend on.
function init_script(verb) {
    return function(args) {
        return exec.run([ constants.LOKI_SERVICE_INIT, verb, ...args ]);
    };
}

// A command the page reads as { success, ... } or { success: false, message }.
function reply(fn) {
    return function(args) {
        try {
            print(sprintf("%J\n", { success: true, ...fn(...args) }));
            return 0;
        }
        catch (e) {
            print(sprintf("%J\n", { success: false, message: e.message }));
            return 1;
        }
    };
}

function json(fn) {
    return function(args) {
        print(sprintf("%J\n", fn(...args)));
        return 0;
    };
}

// An action the page started or acknowledged, answered as { success, job_id, message }.
function action_reply(fn) {
    return function(args) {
        let result = fn(...args);
        print(sprintf("%J\n", result));
        return result.success ? 0 : 1;
    };
}

// A Clash API answer as { status, body }, or the reason it could not be had.
function clash(fn) {
    return function(args) {
        try {
            print(sprintf("%J\n", fn(require("singbox.clash_api"), ...args)));
            return 0;
        }
        catch (e) {
            warn(e.message, "\n");
            return 1;
        }
    };
}

function diagnostics() {
    return require("diagnostics.runtime");
}

function checks() {
    return require("diagnostics.checks");
}

function text(fn) {
    return function(args) {
        let result = fn(...args);
        if (result == null) {
            warn("Configuration file not found\n");
            return 1;
        }
        print(result);
        return 0;
    };
}

function lifecycle() {
    return require("service.lifecycle");
}

function autostart(enabled) {
    if ((enabled ? lifecycle().enable() : lifecycle().disable()) != 0)
        die(enabled ? "Could not enable autostart" : "Could not disable autostart");
    return {};
}

function initd() {
    return require("service.initd");
}

function ui() {
    return require("service.ui");
}

function installer() {
    return require("service.installer");
}

// The state service hands over the page's LuCI session in the environment, which rpcd lets no
// page set itself.
function config_import(step) {
    return action_reply((path) => require("config.import")[step](path, getenv("LOKI_RPC_SESSION")));
}

function installer_log() {
    let log = installer().log_text();
    if (log == null) {
        warn("install.sh has left no log\n");
        return 1;
    }
    print(log);
    return 0;
}

const COMMANDS = {
    start: { help: "Start LoKi service", run: init_script("start") },
    stop: { help: "Stop LoKi service", run: init_script("stop") },
    reload: { args: 1, help: "Reload LoKi configuration", run: init_script("reload") },
    restart: { help: "Restart LoKi service", run: init_script("restart") },
    enable: { help: "Enable LoKi autostart", run: reply(() => autostart(true)) },
    disable: { help: "Disable LoKi autostart", run: reply(() => autostart(false)) },
    uninstall: { help: "Remove LoKi files installed outside opkg/apk", run: () => lifecycle().uninstall() },
    check_service: { help: "Check the service, memory, clock and conflicting interceptors in JSON format", run: json(() => checks().service()) },
    check_dns: { help: "Check the DNS servers loki-core resolves with in JSON format", run: json(() => checks().dns()) },
    check_traffic: { help: "Check that the router's own traffic goes through LoKi in JSON format", run: json(() => checks().traffic()) },
    check_logs: { help: "Show LoKi logs from system journal", run: () => {
        print(diagnostics().logs());
        return 0;
    } },
    report: { args: 2, usage: "[masked|raw] [checks]", help: "Collect the log and configurations of a diagnostic report in JSON format", run: json((visibility, checks) => require("diagnostics.report").report(visibility || "masked", checks)) },
    clash_api: { args: 3, usage: "<method> <path> [body]", help: "Allowlisted Clash API transport fallback", run: clash((api, method, path, body) => api.request(method, path, body)) },
    clash_summary: { help: "Summarize the Clash API state in JSON format", run: clash((api) => api.summary()) },
    show_config: { args: 1, help: "Display current LoKi configuration", run: text((visibility) => diagnostics().show_config(visibility || "masked")) },
    show_version: { help: "Show LoKi version", run: () => { print(constants.LOKI_VERSION, "\n"); return 0; } },
    show_sing_box_config: { args: 1, help: "Show loki-core configuration", run: text((visibility) => diagnostics().show_sing_box_config(visibility || "masked")) },
    import_config_check: { args: 1, usage: "<path>", help: "Tell in JSON format what loading a LoKi backup file on the page would change", run: config_import("check") },
    import_config: { args: 1, usage: "<path>", help: "Stage a LoKi backup file as unsaved changes of the LuCI session in LOKI_RPC_SESSION", run: config_import("stage") },
    get_status: { help: "Get LoKi service status", run: json(() => diagnostics().status()) },
    get_system_info: { help: "Get system information in JSON format", run: json(() => diagnostics().system_info()) },
    get_subscription_default_headers: { help: "Get default subscription request headers in JSON format", run: json(() => ui().default_headers()) },
    get_ui_state: { help: "Get lightweight UI service/action state in JSON format", run: json(() => ui().current_state()) },
    get_core_features: { help: "Get what the installed loki-core can do, from the tags it was built with, in JSON format", run: json(() => require("singbox.features").report()) },
    service_action_async: { args: 1, usage: "<action>", help: "Start a service action in the background", run: action_reply((action) => ui().start_action(action)) },
    ui_action_ack: { args: 1, usage: "<job>", help: "Acknowledge a finished service action state", run: action_reply((job) => ui().acknowledge(job)) },
    installer_start: { args: 4, usage: "<check|update|variant|uninstall> <variant> <purge> <lang>", help: "Run install.sh in the background for the Components tab", run: reply((action, variant, purge, lang) => installer().start(action, variant, purge, lang)) },
    installer_status: { args: 1, usage: "[offset]", help: "Show the Components tab's run of install.sh in JSON format", run: json((offset) => installer().status(offset)) },
    installer_run: { args: 1, run: (args) => installer().run(args[0]) },
    installer_log: { help: "Print the log of install.sh's last run", run: installer_log },
    package_prerm: { args: 1, run: (args) => require("service.package").prerm(args[0]) },
    package_postinst: { run: () => require("service.package").postinst() },
    luci_postinst: { run: () => require("service.package").luci_postinst() },
    luci_prerm: { run: () => require("service.package").luci_prerm() },
    sing_box_crash_cleanup: { args: 1, run: (args) => lifecycle().crash_cleanup(args[0]) },
    sing_box_crash_pause: { args: 1, run: (args) => lifecycle().crash_pause(args[0]) },
    sing_box_crash_resume: { run: () => lifecycle().crash_resume() },
    service_action_worker: { args: 3, run: (args) => { ui().worker(args[0], args[1], args[2]); return 0; } },
    initd_start: { args: 1, run: (args) => initd().start(args[0]) },
    initd_stop: { run: () => initd().stop() },
    initd_restart: { run: () => initd().restart() },
    initd_reload: { args: 1, run: (args) => {
        let result = initd().reload(args[0]);
        if (result.sync)
            print("sync\n");
        return result.status;
    } },
    initd_status: { run: () => initd().status() },
    initd_triggers: { run: () => { print(initd().triggers()); return 0; } },
    initd_wan_up: { run: () => initd().wan_up() },
    initd_retry_start: { run: () => initd().retry_start() },
    initd_retry_token: { run: () => { print(initd().retry_token()); return 0; } },
    initd_retry_monitor: { args: 1, run: (args) => initd().retry_monitor(args[0]) },
    sing_box_watch: { run: () => require("service.singbox_watch").monitor() },
    sync_rule_sets: { run: () => require("nft.ruleset_sync").worker() }
};

function help() {
    print("Usage: ", constants.LOKI_BIN, " COMMAND\n\nAvailable commands:\n");
    for (let name, command in COMMANDS) {
        if (command.help == null)
            continue;
        let usage = command.usage == null ? name : name + " " + command.usage;
        print(length(usage) < 28 ? sprintf("    %-28s%s\n", usage, command.help) : sprintf("    %s\n    %28s%s\n", usage, "", command.help));
    }
}

function dispatch(argv, lib) {
    library.set_dir(lib);
    let command = COMMANDS[argv[0] ?? ""];
    if (command == null) {
        help();
        return 1;
    }

    let args = [];
    for (let i = 1; i <= (command.args ?? 0); i++)
        push(args, argv[i] ?? "");
    return command.run(args) ?? 0;
}

// The RPC broker validates before spawning, and the child rechecks before dispatch.
function read_allowed(argv) {
    for (let arg in argv)
        if (type(arg) != "string" || length(arg) > 65536 || index(arg, chr(0)) >= 0 || match(arg, /[[:cntrl:]]/))
            return false;
    let name = argv[0];
    if (length(argv) == 1 && index([ "check_service", "check_dns", "check_traffic", "check_logs", "clash_summary",
        "get_status", "get_system_info", "get_ui_state", "get_core_features", "show_version" ], name) >= 0)
        return true;
    if (name == "show_config" || name == "show_sing_box_config")
        return length(argv) == 2 && argv[1] == "masked";
    if (name == "report")
        return length(argv) == 3 && argv[1] == "masked";
    if (name == "installer_status")
        return length(argv) == 2 && match(argv[1], /^[0-9]{1,9}$/) != null;
    if (name == "installer_log")
        return length(argv) == 1;
    if (name == "installer_start")
        return length(argv) == 5 && argv[1] == "check" && argv[2] == "" && argv[3] == "0" &&
            index([ "ru", "en" ], argv[4]) >= 0;
    if (name == "clash_api")
        return length(argv) == 4 && argv[1] == "GET" && argv[3] == "" &&
            index([ "/proxies", "/providers/proxies", "/connections" ], argv[2]) >= 0;
    return false;
}

function write_allowed(argv) {
    if (read_allowed(argv))
        return true;
    let name = argv[0];
    if (length(argv) == 1)
        return index([ "enable", "disable", "get_subscription_default_headers" ], name) >= 0;
    if (length(argv) == 2 && name == "service_action_async")
        return index([ "start", "stop", "restart", "reload" ], argv[1]) >= 0;
    if (length(argv) == 2 && name == "ui_action_ack")
        return length(argv[1]) <= 128 && match(argv[1], /^[0-9]+-[0-9]+$/) != null;
    if (length(argv) == 2 && (name == "show_config" || name == "show_sing_box_config"))
        return argv[1] == "raw";
    if (length(argv) == 3 && name == "report")
        return argv[1] == "raw";
    if (length(argv) == 5 && name == "installer_start")
        return index([ "update", "variant", "uninstall" ], argv[1]) >= 0 &&
            index([ "", "base", "full", "tiny" ], argv[2]) >= 0 && index([ "0", "1" ], argv[3]) >= 0 &&
            index([ "ru", "en" ], argv[4]) >= 0;
    return name == "clash_api" && length(argv) == 4 && require("singbox.clash_api").allowed(argv[1], argv[2], argv[3]);
}

function main(argv, lib) {
    return argv[0] == "rpc_dispatch" ? require("service.rpc").run(slice(argv, 2), lib, argv[1]) : dispatch(argv, lib);
}

return { main, dispatch, read_allowed, write_allowed, COMMANDS };
