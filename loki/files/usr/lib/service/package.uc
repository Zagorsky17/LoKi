// Modified for LoKi on 2026-11-03: product labels in user-facing messages.
// The package scripts on a live router; they skip an image build themselves.

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let constants = require("core.constants");
let bytecode = require("core.bytecode");
let storage = require("core.cache_path");
let lock = require("service.lock");

const FIREWALL_INPUT_MARKER = "loki: TPROXY traffic";

let paths = {
    init: constants.LOKI_SERVICE_INIT,
    state_service_init: "/etc/init.d/loki-state",
    was_running: "/tmp/loki/package-running",
    firewall_init: "/etc/init.d/firewall",
    firewall_input_include: "/usr/share/nftables.d/chain-pre/input/loki.nft",
    rpcd_init: "/etc/init.d/rpcd",
    luci_index_cache: [ "/var/luci-indexcache*", "/tmp/luci-indexcache*" ],
    runtime: [ "/var/run/loki", "/var/run/loki.internal-config-change" ]
};

function exists(path) {
    return fs.stat(path) != null;
}

function running_mark(create) {
    try {
        if (create) storage.ensure({ cache_path: paths.was_running });
        else storage.validate({ cache_path: paths.was_running });
        let file = fs.lstat(paths.was_running);
        if (file == null && lock.unmarked(paths.was_running)) return false;
        if (file == null || (file.mode & 0777) != 0600 || file.size != 2 || fs.readfile(paths.was_running) != "1\n")
            die("invalid marker");
        return true;
    }
    catch (e) { die("Private LoKi package upgrade marker is unsafe or unavailable"); }
}

function clear_running_mark() {
    let present = running_mark(false);
    try {
        if (present && !fs.unlink(paths.was_running)) die("unlink failed");
    }
    catch (e) { die("Cannot remove the private LoKi package upgrade marker"); }
}

// fw4 reads /usr/share/nftables.d only while it builds its ruleset, so the shipped input accept
// stays out of a running firewall until something reloads it.
function load_firewall_input_include() {
    if (!exists(paths.firewall_input_include) || !exists(paths.firewall_init))
        return true;
    let chain = exec.output([ "nft", "list", "chain", "inet", "fw4", "input" ]);
    if (chain == null || trim(chain) == "" || index(chain, FIREWALL_INPUT_MARKER) >= 0)
        return true;
    if (!exec.ok([ paths.firewall_init, "reload" ])) {
        exec.log("warn", "Failed to reload the firewall; reload it by hand so that its input chain accepts LoKi's traffic");
        return false;
    }
    return true;
}

// The state service holds the library in memory, so an install restarts it.
function restart_state_service() {
    if (!exists(paths.state_service_init))
        return true;
    return exec.ok([ paths.state_service_init, "enable" ]) && exec.ok([ paths.state_service_init, "restart" ]);
}

// A removal takes autostart away first: while /etc/rc.d/S99loki exists, a WAN-up trigger can
// start the service mid-removal. The routing table name goes after the stop that needs it, and
// what the service kept in RAM, its precompiled library included, goes last.
function prerm(action) {
    let upgrade = action == "upgrade";
    clear_running_mark();
    if (upgrade && exec.ok([ paths.init, "status" ])) {
        running_mark(true);
        if (!common.write_private_file(paths.was_running, "1\n")) return 1;
    }
    if (!upgrade) {
        if (!exec.ok([ paths.init, "disable" ])) return 1;
        if (exists(paths.state_service_init)) {
            if (!exec.ok([ paths.state_service_init, "disable" ]) || !exec.ok([ paths.state_service_init, "stop" ]))
                return 1;
        }
    }
    if (!exec.ok([ paths.init, "stop" ])) return 1;
    bytecode.invalidate_validation_stamp();
    if (upgrade)
        return 0;
    let name_removed = require("nft.apply").remove_rt_table_entry();
    for (let path in paths.runtime)
        common.remove_tree(path);
    return name_removed ? 0 : 1;
}

// The firewall include lets an isolated zone reach the TPROXY inbound, so it loads before the
// service comes back. The logged version tells which release wrote the lines after it.
function postinst() {
    let resume = running_mark(false);
    exec.log("info", "Installed LoKi " + constants.LOKI_VERSION);
    bytecode.invalidate_validation_stamp();
    if (!restart_state_service() || !load_firewall_input_include()) return 1;
    if (!resume)
        return 0;
    if (!exec.ok([ paths.init, "start" ]))
        return 1;
    clear_running_mark();
    return 0;
}

// Installing the page is what starts the state service, and removing it stops it.
function luci_postinst() {
    for (let pattern in paths.luci_index_cache)
        for (let path in fs.glob(pattern))
            fs.unlink(path);
    if (!restart_state_service()) return 1;
    return exists(paths.rpcd_init) && !exec.ok([ paths.rpcd_init, "reload" ]) ? 1 : 0;
}

function luci_prerm() {
    return exists(paths.state_service_init) && !exec.ok([ paths.state_service_init, "stop" ]) ? 1 : 0;
}

return { paths, prerm, postinst, luci_postinst, luci_prerm };
