// Where a Tailscale tunnel keeps its node key: its identity in the tailnet, which a
// disabled one keeps and a removed one gives up.

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let uci = require("core.uci");

const CONFIG_NAME = "forkop";

let paths = {
    state_root: "/etc/forkop/tailscale"
};

function tunnel_state_directory(section_name, tunnel_name) {
    return paths.state_root + "/" + common.as_string(section_name) + "-" + common.as_string(tunnel_name);
}

// Runs once the configuration is known good. A configuration that could not be read keeps
// every identity: an empty one would read the same.
function remove_orphaned_states() {
    if (!uci.load(CONFIG_NAME) || length(uci.sections(CONFIG_NAME, "settings")) == 0)
        return;

    let kept = {};
    for (let tunnel in uci.section_objects(CONFIG_NAME, "tunnel")) {
        kept[tunnel_state_directory(common.option(tunnel, "section", ""), tunnel[".name"])] = true;
        // A JSON tunnel may keep its state in a directory of the root it names itself.
        let declared = common.parse_json(common.option(tunnel, "endpoint_json", ""))?.state_directory;
        if (type(declared) == "string")
            kept[rtrim(declared, "/")] = true;
    }

    for (let entry in fs.lsdir(paths.state_root) ?? []) {
        let path = paths.state_root + "/" + entry;
        if (kept[path] || fs.stat(path)?.type != "directory")
            continue;
        if (exec.ok([ "rm", "-rf", path ]))
            exec.log("info", "Removed the Tailscale identity '" + entry + "' of a tunnel that no longer exists");
    }
}

return { paths, tunnel_state_directory, remove_orphaned_states };
