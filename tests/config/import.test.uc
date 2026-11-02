let t = require("t");
let stub = require("stub");
let uci = require("uci");
let ubus = require("ubus");
let cli = require("service.cli");
let migration = require("config.migration");
let imports = require("config.import");

const SESSION = "0123456789abcdef0123456789abcdef";
const FILE = "/tmp/forkop-import.conf";

function copy(value) {
    return json(sprintf("%J", value));
}

// rpcd's uci object for the page's session: what it stages over the committed configuration.
function rpcd(committed, unsaved) {
    let state = { staged: null, changes: [], counter: 0x40, refuse: null };
    let reset = () => {
        state.staged = copy(committed);
        state.changes = [];
    };
    reset();
    if (unsaved != null) {
        state.staged = copy(unsaved);
        push(state.changes, [ "set", "settings", "unsaved", "1" ]);
    }
    let find = (name) => filter(state.staged, (section) => section[".name"] == name)[0];
    let handle = (method, fn) => ubus.__on("uci." + method, (args) =>
        args.ubus_rpc_session != SESSION ? ubus.__failure("Permission denied") : fn(args));

    handle("revert", () => reset());
    handle("changes", () => ({ changes: state.changes }));
    handle("get", () => {
        let values = {};
        for (let i, section in state.staged)
            values[section[".name"]] = { ...section, ".index": i };
        return { values };
    });
    handle("add", (args) => {
        let name = args.name ?? sprintf("cfg%02x4e69", ++state.counter);
        let section = find(name);
        if (section != null)
            section[".type"] = args.type;
        else
            push(state.staged, { ".name": name, ".type": args.type, ".anonymous": args.name == null });
        push(state.changes, [ "add", name, args.type ]);
        return { section: name };
    });
    handle("set", (args) => {
        let section = find(args.section);
        if (section == null || state.refuse == args.section)
            return ubus.__failure("Not found");
        for (let key, value in args.values)
            section[key] = value;
        push(state.changes, [ "set", args.section ]);
    });
    handle("delete", (args) => {
        let section = find(args.section);
        if (section == null)
            return ubus.__failure("Not found");
        if (args.option != null)
            delete section[args.option];
        else
            state.staged = filter(state.staged, (item) => item[".name"] != args.section);
        push(state.changes, [ "remove", args.section ]);
    });
    handle("order", (args) => {
        let listed = filter(map(args.sections, find), (section) => section != null);
        state.staged = [ ...listed, ...filter(state.staged, (section) => !(section[".name"] in args.sections)) ];
        push(state.changes, [ "order" ]);
    });
    return state;
}

function setup(file, committed, unsaved) {
    uci.__reset();
    ubus.__reset();
    if (file != null)
        uci.__seed("forkop-import.conf", file);
    uci.__seed("forkop", committed);
    return rpcd(committed, unsaved);
}

// Sections as a page sees them: an anonymous one has no name of its own to compare.
function shape(sections) {
    return map(sections, (section) => {
        let result = {};
        for (let key, value in section)
            if (key != ".index" && !(key == ".name" && section[".anonymous"]))
                result[key] = value;
        return result;
    });
}

function current() {
    return [
        { ".name": "settings", ".type": "settings", ".anonymous": false, config_version: "2.0.0", log_level: "info" },
        { ".name": "main", ".type": "section", ".anonymous": false, action: "bypass", label: "Old" },
        { ".name": "gone", ".type": "section", ".anonymous": false, action: "connection" },
        { ".name": "cfg044e69", ".type": "connection_link", ".anonymous": true, section: "gone", uri: "socks://127.0.0.1:1#x" }
    ];
}

function released() {
    return [
        { ".name": "settings", ".type": "settings", config_version: "1.0.5", applied_migrations: [ "http_connection_urls" ] },
        { ".name": "main", ".type": "section", action: "connection", selector_proxy_links: [ "vless://u@a.example:443#A" ] },
        { ".name": "inbound", ".type": "server", label: "VLESS", protocol: "vless", server_uuid: "44444444-4444-4444-8444-444444444444" },
        { ".name": "mt", ".type": "server", label: "MT", protocol: "mtproto" }
    ];
}

t.test("a released configuration is staged as an update would migrate it, in the file's order", () => {
    let session = setup(released(), current());
    let wanted = migration.migrate(migration.read_file(FILE).model, "1.0.5");

    t.eq(imports.check(FILE, SESSION), { success: true, from: "1.0.5", to: "2.0.0",
        warnings: [ "Removed the MTProto server 'MT': Forkop no longer serves MTProto" ], changed: true, unsaved: false });
    t.eq(imports.stage(FILE, SESSION), { success: true });
    t.eq(shape(session.staged), shape(wanted.model.sections));
    t.eq(session.staged[0].config_version, "2.0.0");
    t.eq(map(filter(session.staged, (section) => section[".anonymous"]), (section) => section[".type"]),
        [ "connection_link", "server_client" ]);
    t.eq(uci.__commits(), [], "nothing is committed");
    t.eq(imports.check(FILE, SESSION).changed, false, "the same file again has nothing to change");
});

t.test("the session's unsaved changes to Forkop give way to the file", () => {
    let unsaved = current();
    unsaved[1].label = "Edited";
    let session = setup(current(), current(), unsaved);
    t.eq(imports.check(FILE, SESSION), { success: true, from: "2.0.0", to: "2.0.0", warnings: [], changed: true, unsaved: true });
    t.eq(imports.stage(FILE, SESSION), { success: true });
    t.eq(session.staged, current());
    t.eq(session.changes, []);
});

t.test("a file holding the configuration changes nothing, and one in another order changes the order", () => {
    setup(current(), current());
    t.eq(imports.check(FILE, SESSION).changed, false);

    let reordered = current();
    let link = { ...reordered[3], ".name": "cfg024e69" };
    let session = setup([ reordered[0], link, reordered[2], reordered[1] ], current());
    t.eq(imports.check(FILE, SESSION).changed, true);
    t.eq(imports.stage(FILE, SESSION), { success: true });
    t.eq(map(session.staged, (section) => section[".type"] + ":" + (section.section ?? section[".name"])),
        [ "settings:settings", "connection_link:gone", "section:gone", "section:main" ]);
    t.eq(map(session.changes, (change) => change[0]), [ "add", "set", "set", "remove", "order" ]);
});

t.test("a file this release cannot read as a released schema is refused with the reason", () => {
    let refusal = (file) => {
        setup(file, current());
        let result = imports.check(FILE, SESSION);
        t.eq(imports.stage(FILE, SESSION), result, "staging refuses for the same reason");
        t.eq(ubus.__calls(), [], "the session is left alone");
        return result;
    };
    let version = (value) => [ { ".name": "settings", ".type": "settings", config_version: value } ];

    t.eq(refusal(null), { success: false, min: "1.0.2", to: "2.0.0", reason: "unreadable",
        detail: "UCI cannot read " + FILE + ": Entry not found" });
    t.eq(refusal(version("2.1.0")), { success: false, min: "1.0.2", to: "2.0.0", reason: "newer", from: "2.1.0" });
    t.eq(refusal(version("1.0.0")).reason, "below_min");
    t.eq(refusal(version("1.0.3")).reason, "unknown");
    t.eq(refusal([ { ".type": "interface", proto: "dhcp" } ]).reason, "missing");
    let failed = refusal([ ...version("1.0.5"), { ".name": "s", ".type": "section", action: "connection",
        outbound_jsons: [ "{\"type\":\"snell\",\"tag\":\"S\",\"version\":2}" ] } ]);
    t.eq([ failed.reason, failed.from ], [ "migration", "1.0.5" ]);
    t.contains(failed.detail, "is Snell 2, which sing-box no longer speaks");
});

t.test("a write the session refuses leaves it without the file's changes", () => {
    let session = setup(released(), current());
    session.refuse = "main";
    let result = imports.stage(FILE, SESSION);
    t.eq([ result.success, result.reason ], [ false, "staging" ]);
    t.matches(result.detail, /^could not set option '[a-z_]+' of section 'main': Not found$/);
    t.eq(session.staged, current());
});

t.test("without the page's session the check reads the committed configuration and nothing is staged", () => {
    setup(current(), current());
    t.eq(imports.check(FILE, ""), { success: true, from: "2.0.0", to: "2.0.0", warnings: [], changed: false, unsaved: false });
    t.eq(imports.stage(FILE, "").reason, "session");
    t.eq(ubus.__calls(), []);

    setup(current(), current());
    t.eq(imports.stage(FILE, "ffffffffffffffffffffffffffffffff"),
        { success: false, min: "1.0.2", to: "2.0.0", reason: "session", detail: "Permission denied" });
});

t.test("the command line takes the session from the environment, never from its arguments", () => {
    let session = setup(released(), current());
    stub.env({ FORKOP_RPC_SESSION: SESSION });
    let check = stub.capture(() => cli.main([ "import_config_check", FILE ], "/lib"));
    let staged = stub.capture(() => cli.main([ "import_config", FILE ], "/lib"));
    stub.env({ FORKOP_RPC_SESSION: "" });
    let refused = stub.capture(() => cli.main([ "import_config", FILE ], "/lib"));
    stub.restore();
    t.eq([ check.result, json(check.stdout).changed ], [ 0, true ]);
    t.eq([ staged.result, json(staged.stdout) ], [ 0, { success: true } ]);
    t.eq([ refused.result, json(refused.stdout).reason ], [ 1, "session" ]);
    t.eq(session.staged[1][".name"], "main");
});

t.test("staged unsupported server and tunnel records cannot restore listeners or alter client links", () => {
    let file = [
        { ".name": "settings", ".type": "settings", config_version: "2.0.0", dns_server: [ "1.1.1.1" ], bootstrap_dns_server: [ "1.1.1.1" ] },
        { ".name": "main", ".type": "section", action: "connection", enabled: "1" },
        { ".name": "first", ".type": "connection_link", section: "main", name: "First", uri: "vless://test@127.0.0.1:443?security=reality&pbk=public-test&sid=00&sni=example.com&type=ws&path=%2Ftest#First", order: "0" },
        { ".name": "second", ".type": "connection_link", section: "main", name: "Second", uri: "socks://user:synthetic-password@127.0.0.1:1080#Second", order: "1" },
        { ".name": "sub", ".type": "subscription_url", section: "main", tag: "Provider", url: "https://example.com/sub", subscription_update_enabled: "0" },
        { ".name": "injected", ".type": "server", enabled: "1", protocol: "json_inbound", inbound_json: "{\"type\":\"mixed\",\"tag\":\"injected\",\"listen\":\"0.0.0.0\",\"listen_port\":18443}", routing_mode: "rules" },
        { ".name": "retired", ".type": "tunnel", section: "main", kind: "tailscale", tailscale_auth_key: "synthetic-auth-key" },
        { ".name": "retired-peer", ".type": "tunnel_peer", tunnel: "retired", private_key: "synthetic-private-key" }
    ];
    let session = setup(file, current());
    stub.commands([ [ () => true, {} ] ]);
    t.eq(imports.check(FILE, SESSION).success, true);
    t.eq(imports.stage(FILE, SESSION), { success: true });
    let commands = stub.command_lines();
    stub.restore();
    t.eq(commands, [], "staging cannot run server commands");
    uci.__seed("forkop", session.staged);
    require("core.uci").reset();
    let generator = require("singbox.generator");
    let config = generator.build({ service_address: "127.0.0.1" });
    t.ok(generator.runnable());
    t.excludes(map(config.inbounds, (item) => item.tag), "injected");
    t.eq(config.endpoints, null);
    let clients = filter(config.outbounds, (item) => item.type == "parser");
    t.eq(map(clients, (item) => item.link), [ file[2].uri, file[3].uri ]);
    t.eq(map(config.providers, (item) => [ item.tag, item.url ]), [ [ "main/Provider", "https://example.com/sub" ] ]);
});

t.done();
