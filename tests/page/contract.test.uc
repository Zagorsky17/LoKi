// The page carries its own copy of a few backend tables; tests/fixtures/page_contract.json holds
// both copies: this file checks the backend, fe-app-loki/tests/pageContract.test.js the page.

let t = require("t");
let fs = require("fs");
let repo = require("repo");
let fixture = require("fixture");
let constants = require("singbox.constants");
let rulesets = require("singbox.rulesets");
let connections = require("config.connections");
let mask = require("diagnostics.mask");
let state_service = require("service.state_service");
let features = require("singbox.features");
let installer = require("service.installer");
let ubus = require("ubus");
let uloop = require("uloop");
let stub = require("stub");

let contract = json(fs.readfile(repo.path("tests/fixtures/page_contract.json")));

t.test("the reserved ports include the HTTPS gateway and routing inbounds, without a TCP controller", () => {
    let ports = [ constants.HTTPS_GATEWAY_PORT ];
    for (let name in keys(constants))
        if (match(name, /_INBOUND_PORT$/))
            push(ports, constants[name]);
    t.eq(sort(uniq(ports), (a, b) => a - b), contract.reserved_ports);
});

t.test("the reserved tags are the ones Loki gives its own listeners", () => {
    t.eq(sort(keys(constants.RESERVED_TAGS)), contract.reserved_tags);
});

t.test("the community rule sets are the ones the generator can download, each from its own URL", () => {
    t.eq(sort(keys(rulesets.COMMUNITY_SERVICES)), contract.community_rule_sets);
    let urls = map(contract.community_rule_sets, rulesets.community_url);
    t.eq(length(uniq(urls)), length(urls));
});

t.test("the filterable server types are the ones the validator accepts", () => {
    t.eq(constants.FILTERABLE_PROVIDER_TYPES, contract.provider_types);
    t.eq(constants.FILTERABLE_GROUP_TYPES, contract.group_types);
    t.eq(constants.REMOVED_VPN_TYPES, contract.removed_vpn_types);
});

t.test("the reserved override paths are the ones the validator refuses", () => {
    t.eq(constants.RESERVED_OVERRIDE_PATCH_PATHS, contract.reserved_override_patch_paths);
});

t.test("the page checks the domain the generated configuration answers with FakeIP", () => {
    t.eq(constants.FAKEIP_TEST_DOMAIN, contract.check_domains.fakeip);
});

t.test("an unset group option means what the dashboard says it means", () => {
    fixture.seed({
        section: [ { ".name": "proxy", action: "connection" } ],
        urltest: [ { ".name": "fast", section: "proxy", name: "Fast" } ],
        fallback_group: [ { ".name": "safe", section: "proxy", name: "Safe" } ]
    });
    connections.load();
    let section = { ".name": "proxy" };

    let urltest = contract.urltest_defaults;
    t.eq(connections.urltest_testing_url(section, "fast"), urltest.testing_url);
    t.eq(connections.urltest_expected_status(section, "fast"), urltest.expected_status);
    t.eq(connections.urltest_check_interval(section, "fast"), urltest.check_interval);
    t.eq(int(connections.urltest_tolerance(section, "fast")), urltest.tolerance);
    t.eq(connections.urltest_idle_timeout(section, "fast"), "", "left to loki-core");
    t.eq(constants.URLTEST_DEFAULT_IDLE_TIMEOUT, urltest.idle_timeout, "what loki-core applies");
    t.eq(connections.urltest_interrupt_exist_connections(section, "fast"), urltest.interrupt_exist_connections);

    let fallback = contract.fallback_defaults;
    t.eq(connections.fallback_group_health_check_url(section, "safe"), fallback.health_check_url);
    t.eq(connections.fallback_group_health_check_interval(section, "safe"), fallback.health_check_interval);
    t.eq(connections.fallback_group_health_check_timeout(section, "safe"), fallback.health_check_timeout);
    t.eq(connections.fallback_group_attempt_timeout(section, "safe"), fallback.attempt_timeout);
    t.eq(connections.fallback_group_expected_status(section, "safe"), fallback.expected_status);
    t.eq(connections.fallback_group_idle_timeout(section, "safe"), fallback.idle_timeout);
    t.eq(connections.fallback_group_interrupt_exist_connections(section, "safe"), fallback.interrupt_exist_connections);
});

t.test("the state service parks a request as long as the page expects", () => {
    t.eq(state_service.MAX_WAIT_MS, contract.state_wait_ms);
});

// The read snapshot and controlled commands cannot share the private writer grant.
t.test("the page may call every method the state service publishes", () => {
    let acl = json(fs.readfile(repo.path("luci-app-loki/root/usr/share/rpcd/acl.d/luci-app-loki.json")))["luci-app-loki"];
    t.eq(sort([ ...acl.read.ubus.loki, ...acl.write.ubus.loki ]), sort(keys(state_service.object_methods())));
    t.eq(acl.write.ubus.loki, [ "rpc_write", "rpc_write_prepare", "rpc_write_result", "config_private", "import_config" ]);
});

t.test("the option every password field is stored in is masked in diagnostics", () => {
    for (let field, stored in { ...contract.password_fields, ...contract.retired_password_fields }) {
        let masked = mask.loki_config("config tunnel 'probe'\n\toption " + stored + " 'secret-value'\n");
        t.excludes(masked, "secret-value", field);
    }
});

t.test("a link needs what the core needs to dial it", () => {
    for (let entry in contract.link_features)
        t.eq(features.link_features(entry[0]), entry[1], entry[0]);
});

t.test("the core report the page is built against is the backend's for the base build", () => {
    let base = contract.core_report_base;
    t.eq(features.report(base.tags), base);
});

t.test("the page follows a run of install.sh through the object and methods its runner publishes", () => {
    t.eq(installer.OBJECT_NAME, contract.installer.object);
    t.eq(installer.ACTIONS, contract.installer.actions);
    let dir = stub.tmpdir();
    installer.paths.state = dir + "/state.json";
    installer.paths.output = dir + "/output";
    installer.paths.package_databases = [];
    fs.writefile(installer.paths.state, sprintf("%J", { schema: 1, id: "run-1", action: "check", lang: "en", interactive: false, finished_at: null }));
    ubus.__reset();
    uloop.__reset();
    let methods = null;
    uloop.__on_run(() => {
        methods = sort(keys(ubus.__published(contract.installer.object)));
        uloop.__fire("timer");
    });
    installer.run("run-1");
    t.eq(methods, contract.installer.methods);
});

t.done();
