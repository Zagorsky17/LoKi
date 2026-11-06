let t = require("t");
let stub = require("stub");
let fs = require("fs");
let repo = require("repo");
let pkg = require("service.package");
let nft = require("nft.apply");
let constants = require("core.constants");

let dir = stub.tmpdir();
fs.chmod(dir, 0700);
let init = dir + "/loki-init";
let state_init = dir + "/loki-state";
let firewall_init = dir + "/firewall";
let include = dir + "/loki.nft";

pkg.paths.init = init;
pkg.paths.state_service_init = state_init;
pkg.paths.was_running = dir + "/was-running";
pkg.paths.firewall_init = firewall_init;
pkg.paths.firewall_input_include = include;
pkg.paths.rpcd_init = dir + "/rpcd";
pkg.paths.luci_index_cache = [ dir + "/luci-indexcache*" ];
pkg.paths.runtime = [ dir + "/run", dir + "/internal-change" ];
nft.paths.rt_tables = dir + "/rt_tables";
for (let path in [ state_init, firewall_init, include, pkg.paths.rpcd_init ])
    fs.writefile(path, "");

const RT_TABLES = "100 main\n105 loki\n1105 lokix\n200 custom\n";

function leave_runtime() {
    fs.mkdir(dir + "/run");
    fs.mkdir(dir + "/run/bytecode");
    fs.writefile(dir + "/run/bytecode/manifest", "4\n");
    fs.writefile(dir + "/internal-change", "1\n");
}

function runtime_left() {
    return map(pkg.paths.runtime, (path) => fs.stat(path) != null);
}

function with_cleanup(fn, cleanup) {
    let result, failure;
    try { result = fn(); }
    catch (e) { failure = e; }
    cleanup();
    if (failure != null) die(failure.message);
    return result;
}

function run(fn, handlers) {
    stub.commands([ ...(handlers ?? []), [ () => true, {} ] ]);
    return with_cleanup(() => {
        let status = fn();
        return { status, commands: stub.command_lines() };
    }, () => stub.restore());
}

t.test("a removal takes autostart away, stops the service, then drops the routing table name and what it kept in RAM", () => {
    fs.writefile(nft.paths.rt_tables, RT_TABLES);
    leave_runtime();
    let named_at_stop = null;
    let result = run(() => pkg.prerm("remove"), [
        [ init + " stop", () => { named_at_stop = index(fs.readfile(nft.paths.rt_tables), "105 loki\n") >= 0; return {}; } ]
    ]);
    t.eq(result.status, 0);
    t.eq(result.commands, [ init + " disable", state_init + " disable", state_init + " stop", init + " stop" ]);
    t.ok(named_at_stop, "the stop still finds the table name it removes routes by");
    t.eq(fs.readfile(nft.paths.rt_tables), "100 main\n1105 lokix\n200 custom\n");
    t.eq(runtime_left(), [ false, false ]);
});

t.test("an upgrade keeps autostart, the table name and the runtime files and remembers a running service", () => {
    fs.writefile(nft.paths.rt_tables, RT_TABLES);
    leave_runtime();
    let result = run(() => pkg.prerm("upgrade"), [ [ init + " status", { status: 0 } ] ]);
    t.eq(result.commands, [ init + " status", init + " stop" ]);
    t.eq(fs.readfile(pkg.paths.was_running), "1\n");
    t.eq(fs.stat(pkg.paths.was_running).mode & 0777, 0600);
    t.eq(fs.readfile(nft.paths.rt_tables), RT_TABLES);
    t.eq(runtime_left(), [ true, true ]);

    run(() => pkg.prerm("upgrade"), [ [ init + " status", { status: 3 } ] ]);
    t.eq(fs.stat(pkg.paths.was_running), null, "a stopped service is not started after the upgrade");
});

t.test("postinst starts again only what the upgrade stopped", () => {
    fs.writefile(pkg.paths.was_running, "1\n");
    fs.chmod(pkg.paths.was_running, 0600);
    let result = run(() => pkg.postinst(), [ [ "nft list chain", { status: 1 } ] ]);
    t.eq(result.status, 0);
    t.eq(result.commands, [ "logger -t loki -p user.info [info] Installed LoKi " + constants.LOKI_VERSION, state_init + " enable", state_init + " restart",
        "nft list chain inet fw4 input", init + " start" ]);
    t.eq(fs.stat(pkg.paths.was_running), null);

    t.eq(run(() => pkg.postinst(), [ [ "nft list chain", { status: 1 } ] ]).commands,
        [ "logger -t loki -p user.info [info] Installed LoKi " + constants.LOKI_VERSION, state_init + " enable", state_init + " restart", "nft list chain inet fw4 input" ]);

    fs.writefile(pkg.paths.was_running, "1\n");
    fs.chmod(pkg.paths.was_running, 0600);
    t.eq(run(() => pkg.postinst(), [ [ "nft list chain", { status: 1 } ], [ init + " start", { status: 1 } ] ]).status, 1);
    t.ok(fs.stat(pkg.paths.was_running) != null, "a failed start leaves the mark for the next attempt");
    fs.unlink(pkg.paths.was_running);
});

t.test("postinst loads the firewall include into a running firewall that lacks it, and nowhere else", () => {
    let chain_without = "chain input {\n\tiif \"lo\" accept\n}\n";
    let chain_with = "chain input {\n" + fs.readfile(repo.path("loki/files/usr/share/nftables.d/chain-pre/input/loki.nft")) + "}\n";
    function reloads(nft_reply, reload_status) {
        let result = run(() => pkg.postinst(), [ [ "nft list chain", nft_reply ], [ firewall_init + " reload", { status: reload_status ?? 0 } ] ]);
        let warning = "logger -t loki -p user.warning";
        return filter(result.commands, (line) => line == firewall_init + " reload" || substr(line, 0, length(warning)) == warning);
    }

    t.eq(reloads({ stdout: chain_without }), [ firewall_init + " reload" ]);
    t.eq(reloads({ stdout: chain_with }), [], "a firewall already carrying the accept is left alone");
    t.eq(reloads({ status: 1 }), [], "a firewall the user keeps stopped is not started");
    t.eq(reloads({ stdout: chain_without }, 1), [ firewall_init + " reload",
        "logger -t loki -p user.warning [warn] Failed to reload the firewall; reload it by hand so that its input chain accepts LoKi's traffic" ]);

    fs.unlink(include);
    t.eq(reloads({ stdout: chain_without }), [], "without the shipped include there is nothing to load");
    fs.writefile(include, "");
});

t.test("the LuCI app starts the state service on install and stops it on removal", () => {
    fs.writefile(dir + "/luci-indexcache", "");
    fs.writefile(dir + "/luci-indexcache.abc", "");
    let result = run(() => pkg.luci_postinst());
    t.eq(result.commands, [ state_init + " enable", state_init + " restart", pkg.paths.rpcd_init + " reload" ]);
    t.eq(fs.glob(dir + "/luci-indexcache*"), []);
    t.eq(run(() => pkg.luci_prerm()).commands, [ state_init + " stop" ]);
});

t.test("the command line runs the hooks and returns their status", () => {
    fs.writefile(nft.paths.rt_tables, RT_TABLES);
    let result = run(() => require("service.cli").main([ "package_prerm", "upgrade" ], "/lib"), [ [ init + " status", { status: 3 } ] ]);
    t.eq([ result.status, result.commands ], [ 0, [ init + " status", init + " stop" ] ]);
});

t.test("a failed stop prevents removal of routing names and runtime state", () => {
    for (let action in [ "remove", "upgrade" ]) {
        fs.writefile(nft.paths.rt_tables, RT_TABLES);
        leave_runtime();
        let result = run(() => pkg.prerm(action), [ [ init + " stop", { status: 1 } ] ]);
        t.eq(result.status, 1, action);
        t.eq(fs.readfile(nft.paths.rt_tables), RT_TABLES);
        t.eq(runtime_left(), [ true, true ]);
    }
});

t.test("failed state and rpcd commands reach the package manager", () => {
    for (let command in [ state_init + " enable", state_init + " restart", pkg.paths.rpcd_init + " reload" ]) {
        let result = run(() => pkg.luci_postinst(), [ [ command, { status: 1 } ] ]);
        t.eq(result.status, 1, command);
        t.eq(result.commands[length(result.commands) - 1], command, "no later step follows the failed command");
    }
    t.eq(run(() => pkg.luci_prerm(), [ [ state_init + " stop", { status: 1 } ] ]).status, 1);
    t.eq(run(() => pkg.postinst(), [ [ state_init + " restart", { status: 1 } ] ]).status, 1);
});

t.test("failed removal preparation preserves runtime data and routing names", () => {
    for (let command in [ init + " disable", state_init + " disable", state_init + " stop" ]) {
        fs.writefile(nft.paths.rt_tables, RT_TABLES);
        leave_runtime();
        let result = run(() => pkg.prerm("remove"), [ [ command, { status: 1 } ] ]);
        t.eq(result.status, 1, command);
        t.eq(result.commands[length(result.commands) - 1], command);
        t.eq(fs.readfile(nft.paths.rt_tables), RT_TABLES);
        t.eq(runtime_left(), [ true, true ]);
    }
});

t.test("a failed firewall include reload preserves the resume mark", () => {
    fs.writefile(pkg.paths.was_running, "1\n");
    fs.chmod(pkg.paths.was_running, 0600);
    let result = run(() => pkg.postinst(), [ [ "nft list chain", { stdout: "chain input {}\n" } ],
        [ firewall_init + " reload", { status: 1 } ] ]);
    t.eq(result.status, 1);
    t.excludes(result.commands, init + " start");
    t.eq(fs.readfile(pkg.paths.was_running), "1\n");
    fs.unlink(pkg.paths.was_running);
});

t.test("unsafe upgrade marks are preserved before any service operation", () => {
    let parent = dir + "/package-private";
    fs.mkdir(parent, 0700);
    let original = pkg.paths.was_running;
    pkg.paths.was_running = parent + "/running";
    let keep = dir + "/foreign-marker-target";
    fs.writefile(keep, "foreign synthetic data");
    with_cleanup(() => {
        for (let kind in [ "link", "mode", "body", "parent" ]) {
            if (kind == "link") fs.symlink(keep, pkg.paths.was_running);
            else {
                fs.writefile(pkg.paths.was_running, kind == "body" ? "unknown owned data" : "1\n");
                fs.chmod(pkg.paths.was_running, kind == "mode" ? 0644 : 0600);
            }
            if (kind == "parent") fs.chmod(parent, 0777);
            with_cleanup(() => {
                for (let action in [ "upgrade", "remove", "postinst" ]) {
                    stub.commands([ [ () => true, {} ] ]);
                    with_cleanup(() => {
                        t.throws(() => action == "postinst" ? pkg.postinst() : pkg.prerm(action));
                        t.eq(stub.command_lines(), [], kind + ": refuse before services or logs");
                        t.ok(fs.lstat(pkg.paths.was_running) != null);
                        t.eq(fs.readfile(keep), "foreign synthetic data");
                    }, () => stub.restore());
                }
            }, () => { fs.chmod(parent, 0700); fs.unlink(pkg.paths.was_running); });
        }
    }, () => { pkg.paths.was_running = original; });
});

t.test("a failed exclusive upgrade marker write does not stop the running service", () => {
    let common = require("core.common");
    let write = common.write_private_file;
    common.write_private_file = () => false;
    with_cleanup(() => {
        let result = run(() => pkg.prerm("upgrade"));
        t.eq(result.status, 1);
        t.eq(result.commands, [ init + " status" ]);
    }, () => { common.write_private_file = write; });
});

t.test("failed marker deletion preserves evidence and masks filesystem errors", () => {
    let original = fs.unlink;
    fs.writefile(pkg.paths.was_running, "1\n");
    fs.chmod(pkg.paths.was_running, 0600);
    for (let mode in [ "false", "throw" ]) {
        fs.unlink = (path) => {
            if (path != pkg.paths.was_running) return original(path);
            if (mode == "throw") die("synthetic-private-marker-value");
            return false;
        };
        stub.commands([ [ () => true, {} ] ]);
        with_cleanup(() => {
            let failure = t.throws(() => pkg.prerm("remove"));
            t.eq(index(failure.message, "synthetic-private-marker-value"), -1);
            t.eq(stub.command_lines(), []);
            t.eq(fs.readfile(pkg.paths.was_running), "1\n");
        }, () => { fs.unlink = original; stub.restore(); });
    }
    fs.unlink(pkg.paths.was_running);
});

t.done();
