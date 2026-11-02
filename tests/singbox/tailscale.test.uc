let t = require("t");
let stub = require("stub");
let fixture = require("fixture");
let fs = require("fs");
let core_uci = require("core.uci");
let tailscale = require("singbox.tailscale");

function states(names) {
    let root = stub.tmpdir() + "/tailscale";
    fs.mkdir(root);
    for (let name in names)
        fs.mkdir(root + "/" + name);
    fs.writefile(root + "/stray-file", "");
    tailscale.paths.state_root = root;
    return root;
}

function removed_by(data) {
    let removed = [];
    fixture.seed(data);
    stub.commands([
        [ "rm -rf", (argv) => { push(removed, replace(argv[2], tailscale.paths.state_root + "/", "")); return {}; } ],
        [ "logger", {} ]
    ]);
    tailscale.remove_orphaned_states();
    stub.restore();
    core_uci.reset();
    return sort(removed);
}

t.test("a tunnel keeps its state under the name the generator gives it", () => {
    let root = states([]);
    t.eq(tailscale.tunnel_state_directory("vpn", "tunnel_2"), root + "/vpn-tunnel_2");
});

t.test("the identity of a removed tunnel goes, a disabled one keeps its own", () => {
    states([ "vpn-tun_1", "vpn-off", "vpn-gone", "custom" ]);
    t.eq(removed_by({
        settings: {},
        tunnel: [
            { ".name": "tun_1", section: "vpn", kind: "tailscale" },
            { ".name": "off", section: "vpn", kind: "tailscale", enabled: "0" },
            { ".name": "tun_json", section: "vpn", kind: "json",
                endpoint_json: sprintf("{\"type\":\"tailscale\",\"state_directory\":\"%s/custom/\"}", tailscale.paths.state_root) }
        ]
    }), [ "vpn-gone" ]);
});

t.test("a configuration without its settings section is not read as one without Tailscale", () => {
    states([ "vpn-tun_1" ]);
    t.eq(removed_by({ tunnel: [] }), []);
});

t.done();
