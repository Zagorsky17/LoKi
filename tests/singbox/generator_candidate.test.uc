let t = require("t");
let fixture = require("fixture");
let stub = require("stub");
let generator = require("singbox.generator");
let connections = require("config.connections");
let uci_core = require("core.uci");

function model(sections) {
    return { sections: [ { ".name": "settings", ".type": "settings",
        config_format: "loki", config_version: "2.0.0", dns_server: [ "1.1.1.1" ],
        bootstrap_dns_server: [ "1.1.1.1" ] }, ...(sections ?? []) ] };
}

function platform() {
    return {
        dhcp: { sections: [ { ".name": "dns", ".type": "dnsmasq", domain: "prepared.lan" } ] },
        system: { sections: [ { ".name": "ntp", ".type": "timeserver", server: [ "time.prepared.example" ] } ] }
    };
}

function prepared(candidate, dependencies) {
    let original = [ uci_core.get_all, uci_core.section_objects ];
    uci_core.get_all = () => die("host UCI accessed");
    uci_core.section_objects = () => die("host UCI accessed");
    stub.commands([]);
    let result;
    let failure;
    try {
        result = generator.build_candidate(candidate, dependencies, {
            controller_secret: fixture.CONTROLLER_SECRET, local_prefixes: [] });
    }
    catch (e) { failure = e; }
    uci_core.get_all = original[0];
    uci_core.section_objects = original[1];
    let calls = stub.calls();
    stub.restore();
    t.eq(calls, []);
    if (failure != null) die(failure);
    return result;
}

function section(extra) {
    return { ".name": "prepared", ".type": "section", action: "bypass", destinations: "prepared.example", ...(extra ?? {}) };
}

t.test("prepared generation uses only its own sections and platform snapshots", () => {
    fixture.seed({ settings: { dns_server: "9.9.9.9" },
        section: [ { ".name": "host", action: "bypass", destinations: "host.example" } ],
        dhcp_dnsmasq: { domain: "host.lan" }, system_ntp: { server: [ "time.host.example" ] } });
    let context = { controller_secret: fixture.CONTROLLER_SECRET, local_prefixes: [] };
    let before = generator.build(context);
    let result = prepared(model([ section() ]), platform());
    let text = sprintf("%J", result);
    t.contains(text, "prepared.example");
    t.contains(text, "prepared.lan");
    t.contains(text, "time.prepared.example");
    t.excludes(text, "host.example");
    t.excludes(text, "host.lan");
    t.excludes(text, "9.9.9.9");
    t.ok(connections.section_exists("host"));
    t.eq(generator.build(context), before);
});

t.test("generation refuses absent platform data and restores its index after failure", () => {
    fixture.seed({ section: [ { ".name": "host", action: "bypass" } ] });
    connections.load();
    for (let dependencies in [ null, {}, { dhcp: { sections: [] } } ]) {
        t.throws(() => prepared(model([ section() ]), dependencies));
        t.ok(connections.section_exists("host"));
    }
    t.throws(() => prepared(model([ section({ action: "connection", outbound_jsons: [ "bad" ] }) ]), platform()));
    t.ok(connections.section_exists("host"));
});

t.test("an empty or disabled runtime does not invent a generated configuration", () => {
    for (let sections in [ [], [ section({ enabled: "0" }) ], [ section({ action: "connection" }) ] ])
        t.eq(prepared(model(sections), null), null);
});

t.test("foreign and malformed models cannot enter generation", () => {
    let foreign = model([ section() ]);
    foreign.sections[0].config_format = "forkop";
    for (let candidate in [ null, {}, foreign ])
        t.throws(() => prepared(candidate, platform()));
});

t.test("identical runtime and prepared inputs produce the same JSON without mutating snapshots", () => {
    let candidate = model([ section() ]);
    let dependencies = platform();
    let before = sprintf("%J", { candidate, dependencies });
    fixture.seed({ settings: candidate.sections[0], section: [ candidate.sections[1] ],
        dhcp_dnsmasq: dependencies.dhcp.sections[0], system_ntp: dependencies.system.sections[0] });
    let runtime = generator.build({ controller_secret: fixture.CONTROLLER_SECRET, local_prefixes: [] });
    t.eq(prepared(candidate, dependencies), runtime);
    t.eq(sprintf("%J", { candidate, dependencies }), before);
});

t.done();
