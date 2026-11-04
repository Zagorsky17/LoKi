let t = require("t");
let stub = require("stub");
let fs = require("fs");
let fixture = require("fixture");
let worker = require("service.worker");
let rulesets = require("singbox.rulesets");
let clash_api = require("singbox.clash_api");
let sync = require("nft.ruleset_sync");

let dir = stub.tmpdir();
let config_path = dir + "/config.json";
fs.writefile(config_path, "{\"experimental\":{\"clash_api\":{\"external_controller\":\"[::]:9090\",\"secret\":\"test-secret\"}}}");

const ALPHA = "https://example.com/alpha.srs";
const BETA = "https://example.com/beta.txt";
let tag = (url) => rulesets.custom_reference_tag(url);

function seed(sections) {
    fixture.seed({ settings: { config_path }, section: sections });
}

function provider(revision, ip_cidr) {
    let exported = { ipv4: [], ipv6: [], scoped_ipv4: [], scoped_ipv6: [], ...ip_cidr };
    return { revision, ip_cidr: { digest: sprintf("%J", exported), ...exported } };
}

function snapshot(providers, revision) {
    let result = { revision: revision ?? 1, providers: {} };
    for (let url, value in providers)
        result.providers[tag(url)] = value;
    return result;
}

// Runs fn with nft answering `nft_status`, and returns what it was handed.
let transactions = [];
let logs = [];
function run(fn, nft_status) {
    transactions = [];
    logs = [];
    stub.commands([
        [ "nft -f", (argv) => { push(transactions, fs.readfile(argv[2])); return { status: nft_status ?? 0 }; } ],
        stub.logger(logs)
    ]);
    let result = fn();
    stub.restore();
    return result;
}

function lines(transaction) {
    return filter(split(transaction ?? "", "\n"), (line) => line != "");
}

function elements(transaction, set_name) {
    let result = [];
    for (let line in lines(transaction)) {
        let prefix = "add element inet loki " + set_name + " { ";
        if (substr(line, 0, length(prefix)) == prefix)
            push(result, ...split(substr(line, length(prefix), length(line) - length(prefix) - 2), ", "));
    }
    return result;
}

const MIXED = {
    ".name": "mixed", enabled: "1", action: "connection", destinations: "10.0.0.0/8\nfd00::/8", ports: [ "80", "443", "1000-1050" ],
    rule_set_with_subnets: [ ALPHA, BETA ]
};

let mixed_snapshot = () => snapshot({
    [ALPHA]: provider(3, {
        ipv4: [ "198.51.100.0/24" ], ipv6: [ "2001:db8:1::/48" ],
        scoped_ipv4: [ { prefixes: [ "203.0.113.1" ], port_ranges: [ { start: 70, end: 90 }, { start: 1000, end: 1100 } ] } ],
        scoped_ipv6: [ { prefixes: [ "2001:db8:2::1" ], port_ranges: [ { start: 443, end: 443 } ] } ],
        skipped: [ { path: "rules[4]", reason: "unsupported_constraints" } ]
    }),
    [BETA]: provider(4, { ipv4: [ "192.0.2.0/24", "198.51.100.0/24" ] })
}, 7);

t.test("a section's providers and its own addresses replace its sets in one transaction", () => {
    seed([ MIXED ]);
    run(() => sync.sync(mixed_snapshot(), [ MIXED ]));
    t.eq(length(transactions), 1);
    let s = "loki_rule_mixed_";
    t.eq(filter(lines(transactions[0]), (line) => substr(line, 0, 5) == "flush"),
        map([ "subnets", "subnets6", "ip_ports", "ip6_ports", "proto_ports", "proto6_ports" ], (name) => "flush set inet loki " + s + name));
    t.eq(elements(transactions[0], s + "subnets"), [ "10.0.0.0/8", "192.0.2.0/24", "198.51.100.0/24" ], "the section's ports apply by rule, and a shared prefix is written once");
    t.eq(elements(transactions[0], s + "subnets6"), [ "2001:db8:1::/48", "fd00::/8" ]);
    t.eq(elements(transactions[0], s + "ip_ports"), [ "203.0.113.1 . 1000-1050", "203.0.113.1 . 80" ], "a provider's own ports are narrowed by the section's");
    t.eq(elements(transactions[0], s + "ip6_ports"), [ "2001:db8:2::1 . 443" ]);
    t.eq(logs, [ "[info] Loaded 7 rule-set subnets into nftables" ], "one line for what the sets hold, nothing about what the core skipped");
});

t.test("overlapping provider elements under a port become disjoint ones the kernel accepts", () => {
    let section = { ".name": "nested", enabled: "1", action: "connection", rule_set_with_subnets: [ ALPHA, BETA ] };
    seed([ section ]);
    run(() => sync.sync(snapshot({
        [ALPHA]: provider(1, { scoped_ipv4: [ { prefixes: [ "10.0.0.0/8" ], port_ranges: [ { start: 443, end: 443 } ] } ] }),
        [BETA]: provider(1, { scoped_ipv4: [ { prefixes: [ "10.1.0.0/16" ], port_ranges: [ { start: 80, end: 90 }, { start: 85, end: 443 } ] } ] })
    }), [ section ]));
    t.eq(elements(transactions[0], "loki_rule_nested_ip_ports"),
        [ "10.0.0.0/16 . 443", "10.1.0.0/16 . 80-443", "10.2.0.0-10.255.255.255 . 443" ]);
});

t.test("a transport-limited group carries the transport in its key and covers every port on it", () => {
    let section = { ".name": "transport", enabled: "1", action: "connection", rule_set_with_subnets: [ ALPHA ] };
    let value = snapshot({ [ALPHA]: provider(1, {
        ipv4: [ "8.8.8.0/24" ],
        scoped_ipv4: [
            { prefixes: [ "104.16.0.0/12" ], networks: [ "udp" ], port_ranges: [ { start: 50000, end: 65535 } ] },
            { prefixes: [ "1.2.3.0/24" ], networks: [ "tcp" ], port_ranges: [] },
            { prefixes: [ "5.5.5.0/24" ], networks: [], port_ranges: [ { start: 443, end: 443 } ] }
        ],
        scoped_ipv6: [ { prefixes: [ "2001:db8:5::/48" ], networks: [ "udp" ], port_ranges: [] } ]
    }) });
    seed([ section ]);
    run(() => sync.sync(value, [ section ]));
    let s = "loki_rule_transport_";
    t.eq(elements(transactions[0], s + "proto_ports"), [ "1.2.3.0/24 . tcp . 1-65535", "104.16.0.0/12 . udp . 50000-65535" ]);
    t.eq(elements(transactions[0], s + "proto6_ports"), [ "2001:db8:5::/48 . udp . 1-65535" ]);
    t.eq(elements(transactions[0], s + "ip_ports"), [ "5.5.5.0/24 . 443" ]);
    t.eq(elements(transactions[0], s + "subnets"), [ "8.8.8.0/24" ]);

    let narrowed = { ...section, ports: [ "443" ] };
    seed([ narrowed ]);
    run(() => sync.sync(value, [ narrowed ]));
    t.eq(elements(transactions[0], s + "proto_ports"), [ "1.2.3.0/24 . tcp . 443" ], "a group the section's ports do not overlap selects nothing");
});

t.test("a section the snapshot or nft refuses is reported once and does not keep the others from loading", () => {
    let bad = { ".name": "bad", enabled: "1", action: "connection", rule_set_with_subnets: [ ALPHA ] };
    let good = { ".name": "good", enabled: "1", action: "connection", rule_set_with_subnets: [ BETA ] };
    let revision = 0;
    for (let broken in [
        { ipv4: [ "198.51.100.0/24; delete table inet loki" ] },
        { scoped_ipv4: [ { prefixes: [ "198.51.100.1" ], port_ranges: [ { start: 80, end: 70000 } ] } ] },
        { scoped_ipv4: [ { prefixes: [ "1.1.1.0/24" ], networks: [ "icmp" ], port_ranges: [] } ] },
        { scoped_ipv4: [ { prefixes: [ "1.1.1.0/24" ], networks: [], port_ranges: [] } ] },
        { scoped_ipv4: [ { prefixes: [ "1.1.1.0/33" ], port_ranges: [ { start: 80, end: 80 } ] } ] }
    ]) {
        revision++;
        let value = snapshot({ [ALPHA]: provider(revision, broken), [BETA]: provider(revision, { ipv4: [ "192.0.2." + revision + "/32" ] }) });
        seed([ bad, good ]);
        let result = run(() => sync.sync(value, [ bad, good ]));
        t.eq(result.written, 1, sprintf("%J", broken));
        t.eq(length(transactions), 1);
        t.excludes(transactions[0], "loki_rule_bad_");
        t.eq(length(filter(logs, (line) => index(line, "[error] Failed to load the rule-set subnets of section 'bad' into nftables: provider ") == 0)), 1);

        run(() => sync.sync(value, [ bad, good ]));
        t.eq([ transactions, logs ], [ [], [] ], "the same inputs are neither retried nor reported again");
    }
});

t.test("a provider the core does not have is reported, one still loading is waited for", () => {
    let section = { ".name": "waiting", label: "Streaming", enabled: "1", action: "connection", rule_set_with_subnets: [ ALPHA ] };
    seed([ section ]);
    run(() => sync.sync(snapshot({}), [ section ]));
    t.eq(logs, [ "[error] Failed to load the rule-set subnets of section 'Streaming' into nftables: missing rule-set provider: " + tag(ALPHA) ]);

    let loading = { revision: 0, ip_cidr: null };
    run(() => sync.sync(snapshot({ [ALPHA]: loading }), [ section ]));
    t.eq([ transactions, logs ], [ [], [] ], "a download in progress is not a failure");
    run(() => sync.sync(snapshot({ [ALPHA]: provider(1, { ipv4: [ "192.0.2.0/24" ] }) }), [ section ]));
    t.eq(length(transactions), 1, "the section loads once the provider has");
});

t.test("a section is rewritten only when the content of a provider it reads changed", () => {
    let section = { ".name": "keyed", enabled: "1", action: "connection", ports: [ "80" ], rule_set_with_subnets: [ ALPHA ] };
    let other = { ".name": "other", enabled: "1", action: "connection", rule_set_with_subnets: [ BETA ] };
    seed([ section, other ]);
    let value = (beta) => snapshot({ [ALPHA]: provider(4, { ipv4: [ "198.51.100.0/24" ] }), [BETA]: provider(1, { ipv4: beta }) });
    run(() => sync.sync(value([ "192.0.2.0/24" ]), [ section, other ]));
    t.eq(length(transactions), 2);
    run(() => sync.sync(value([ "192.0.2.0/24" ]), [ section, other ]));
    t.eq(transactions, []);
    run(() => sync.sync(value([ "192.0.2.0/24", "203.0.113.0/24" ]), [ section, other ]));
    t.eq(length(transactions), 1);
    t.contains(transactions[0], "loki_rule_other_subnets");
    t.eq(logs, [ "[info] Loaded 2 rule-set subnets into nftables for 1 of 2 sections" ]);
});

t.test("a reloaded core counts its providers from one again, and content already written is not written again", () => {
    let section = { ".name": "reloaded", enabled: "1", action: "connection", rule_set_with_subnets: [ ALPHA ] };
    seed([ section ]);
    let value = (revision, ipv4) => snapshot({ [ALPHA]: provider(revision, { ipv4 }) }, revision);
    run(() => sync.sync(value(5, [ "198.51.100.0/24" ]), [ section ]));
    t.eq(length(transactions), 1);
    run(() => sync.sync(value(1, [ "198.51.100.0/24" ]), [ section ]));
    t.eq([ transactions, logs ], [ [], [] ], "the same content under a revision that started over");
    run(() => sync.sync(value(1, [ "192.0.2.0/24" ]), [ section ]));
    t.eq(length(transactions), 1, "other content under a revision seen before");
});

t.test("a provider whose snapshot names no digest is reported rather than trusted", () => {
    let section = { ".name": "undigested", enabled: "1", action: "connection", rule_set_with_subnets: [ ALPHA ] };
    seed([ section ]);
    run(() => sync.sync({ revision: 1, providers: { [tag(ALPHA)]: { revision: 1, ip_cidr: { ipv4: [ "192.0.2.0/24" ], ipv6: [], scoped_ipv4: [], scoped_ipv6: [] } } } }, [ section ]));
    t.eq(transactions, []);
    t.eq(logs, [ "[error] Failed to load the rule-set subnets of section 'undigested' into nftables: provider " + tag(ALPHA) + ": ip_cidr snapshot carries no digest" ]);
});

t.test("a transaction nft is killed over says the router ran out of memory, naming the section", () => {
    let section = { ".name": "huge", enabled: "1", action: "connection", rule_set_with_subnets: [ ALPHA ] };
    seed([ section ]);
    run(() => sync.sync(snapshot({ [ALPHA]: provider(1, { ipv4: [ "192.0.2.0/24" ] }) }), [ section ]), 137);
    t.eq(length(logs), 1);
    t.contains(logs[0], "section 'huge' into nftables: nft ran out of memory");
});

t.test("a user's unusable address is dropped and the rest of the section loads", () => {
    let section = { ".name": "typed", enabled: "1", action: "connection", destinations: "203.0.113.0/24; delete table inet loki\n198.51.100.7",
        rule_set_with_subnets: [ ALPHA ] };
    seed([ section ]);
    run(() => sync.sync(snapshot({ [ALPHA]: provider(1, {}) }), [ section ]));
    t.excludes(transactions[0], "delete table");
    t.eq(elements(transactions[0], "loki_rule_typed_subnets"), [ "198.51.100.7" ]);
});

t.test("a large set goes to nft in bounded lines", () => {
    let section = { ".name": "large", enabled: "1", action: "connection", rule_set_with_subnets: [ ALPHA ] };
    let prefixes = [];
    for (let i = 0; i < 300; i++)
        push(prefixes, sprintf("10.%d.%d.1/32", i / 256, i % 256));
    seed([ section ]);
    run(() => sync.sync(snapshot({ [ALPHA]: provider(1, { ipv4: prefixes }) }), [ section ]));
    let adds = filter(lines(transactions[0]), (line) => index(line, "add element inet loki loki_rule_large_subnets ") == 0);
    t.eq(length(adds), 2);
    t.eq(length(filter(adds, (line) => length(line) > 8192)), 0);
    t.eq(length(elements(transactions[0], "loki_rule_large_subnets")), 300);
});

// The worker's loop with the controller answering from `answers` in turn: a body, false for a
// wait that ran out, null for a controller that is not there or answered nothing.
function run_worker(sections, answers) {
    seed(sections);
    let calls = [];
    let sleeps = [];
    let real_sleep = global.sleep;
    let real_exchange = clash_api.exchange;
    global.sleep = (ms) => push(sleeps, ms);
    clash_api.exchange = (api, method, path, options) => {
        push(calls, { url: "http://" + api.endpoint + path, method, secret: api.secret, seconds: options.seconds });
        let answer = shift(answers);
        if (type(answer) == "function")
            answer = answer();
        if (length(answers) == 0)
            seed([]);
        if (type(answer) != "string")
            return answer;
        return options.decode == null ? { status: 200, body: answer } : { status: 200, value: options.decode(answer) };
    };
    stub.commands([ [ "nft -f", {} ], [ "logger", {} ], [ "ubus", {} ] ]);
    sync.worker();
    stub.restore();
    clash_api.exchange = real_exchange;
    global.sleep = real_sleep;
    return { calls, sleeps };
}

const SNAPSHOT = sprintf("%J", { revision: 5, providers: {} });

t.test("the worker follows the provider events and asks a controller that is not there later and later", () => {
    let section = { ".name": "followed", enabled: "1", action: "connection", rule_set_with_subnets: [ ALPHA ] };
    let result = run_worker([ section ], [
        null,
        SNAPSHOT,
        false,
        "{\"name\":\"x\",\"revision\":6}",
        SNAPSHOT,
        null,
        null,
        null
    ]);
    t.eq(map(result.calls, (call) => call.url), [
        "http://127.0.0.1:9090/providers/rules",
        "http://127.0.0.1:9090/providers/rules",
        "http://127.0.0.1:9090/providers/rules/events?since=5",
        "http://127.0.0.1:9090/providers/rules/events?since=5",
        "http://127.0.0.1:9090/providers/rules",
        "http://127.0.0.1:9090/providers/rules/events?since=5",
        "http://127.0.0.1:9090/providers/rules",
        "http://127.0.0.1:9090/providers/rules"
    ], "a timed-out wait is waited again, an event is synced from");
    t.eq(result.sleeps, [ 3000, 3000, 6000, 12000 ], "the retry waits double while the controller does not answer, and start over once it does");
    t.eq(uniq(map(result.calls, (call) => call.secret)), [ "test-secret" ], "the secret loki-core runs with");
    t.eq(uniq(map(result.calls, (call) => call.method + " " + call.seconds)), [ "GET 10", "GET 60" ], "a snapshot within 10 s, an event within a minute");
});

t.test("a snapshot the controller refuses or sends incomplete is no snapshot", () => {
    let section = { ".name": "refused", enabled: "1", action: "connection", rule_set_with_subnets: [ ALPHA ] };
    let result = run_worker([ section ], [ { status: 401, value: { providers: {}, revision: 1 } }, { status: 200, value: null }, SNAPSHOT, null ]);
    t.eq(result.sleeps, [ 3000, 6000, 3000 ], "neither counts as an answer");
});

t.test("each reload of the core is followed by the same short wait, however soon it came after the last one", () => {
    let section = { ".name": "reloaded", enabled: "1", action: "connection", rule_set_with_subnets: [ ALPHA ] };
    let result = run_worker([ section ], [
        SNAPSHOT, null,
        SNAPSHOT, null,
        SNAPSHOT, null
    ]);
    t.eq(result.sleeps, [ 3000, 3000, 3000 ], "a controller that answered again is no longer one that does not answer");
});

t.test("a controller that stopped answering is looked up again before it is asked again", () => {
    let section = { ".name": "moved", enabled: "1", action: "connection", rule_set_with_subnets: [ ALPHA ] };
    let original = fs.readfile(config_path);
    let result = run_worker([ section ], [
        SNAPSHOT,
        () => {
            fs.writefile(config_path, "{\"experimental\":{\"clash_api\":{\"external_controller\":\"127.0.0.1:9191\",\"secret\":\"test-secret\"}}}");
            return null;
        },
        SNAPSHOT,
        null
    ]);
    fs.writefile(config_path, original);
    t.eq(map(result.calls, (call) => call.url), [
        "http://127.0.0.1:9090/providers/rules",
        "http://127.0.0.1:9090/providers/rules/events?since=5",
        "http://127.0.0.1:9191/providers/rules",
        "http://127.0.0.1:9191/providers/rules/events?since=5"
    ]);
});

t.test("the rule-set worker is a respawning procd service run through the command line", () => {
    let payload = worker.payload(sync.worker_spec());
    t.eq(payload.name, "loki-ruleset-sync");
    t.eq(payload.instances.sync.command, [ "/usr/bin/loki", "sync_rule_sets" ]);
    t.eq(payload.instances.sync.respawn, [ "3600", "5", "0" ]);
    t.ok(!("data" in payload.instances.sync));
    t.eq(worker.payload(sync.worker_spec({ a: [ "x" ] })).instances.sync.data, { subnet_sources: { a: [ "x" ] } },
        "procd keeps the sources the worker was started with");
});

t.test("the worker is current while it runs with the providers each section reads, or does not run without one", () => {
    let fed = { ".name": "fed", enabled: "1", action: "connection", rule_set_with_subnets: [ ALPHA, BETA ] };
    let plain = { ".name": "plain", enabled: "1", action: "connection", destinations: "10.0.0.0/8" };
    let real = { current: worker.current, running: worker.running };
    let asked = null;
    worker.current = (spec) => { asked = spec.data; return true; };

    seed([ fed, plain ]);
    t.ok(sync.worker_current());
    t.eq(asked, { subnet_sources: { fed: [ tag(ALPHA), tag(BETA) ] } }, "only a section fed by a provider, with every provider it reads");

    seed([ plain ]);
    worker.running = () => false;
    t.ok(sync.worker_current(), "no worker while no section reads a provider");
    worker.running = () => true;
    t.ok(!sync.worker_current(), "a worker left running without one");

    worker.current = real.current;
    worker.running = real.running;
});

t.test("a running worker is current only while procd holds the data it was started with", () => {
    let own = filter(split(fs.readfile("/proc/self/cmdline"), "\0"), (arg) => arg != "");
    let spec = { name: "loki-probe", instance: "sync", command: slice(own, 1), pid_file: dir + "/probe.pid", data: { subnet_sources: { a: [ "x" ] } } };
    let listed = (data) => [ [ "ubus call service list", { stdout: sprintf("%J", { "loki-probe": { instances: { sync: { running: true, data } } } }) } ] ];

    t.ok(!worker.current(spec), "no worker recorded");
    fs.writefile(spec.pid_file, require("core.common").own_pid() + "\n");
    stub.commands(listed(spec.data));
    t.ok(worker.current(spec));
    stub.commands(listed({ subnet_sources: { a: [ "x", "y" ] } }));
    t.ok(!worker.current(spec), "a section reads another provider");
    stub.commands(listed(null));
    t.ok(!worker.current(spec), "started without data");
    stub.restore();
});

t.test("without a table section fed by a provider the worker is stopped and not started", () => {
    seed([ { ".name": "empty", enabled: "1", action: "connection" },
        { ".name": "dns", enabled: "1", action: "dns", rule_set_with_subnets: [ ALPHA ] },
        { ".name": "off", enabled: "0", action: "connection", rule_set_with_subnets: [ ALPHA ] } ]);
    stub.commands([ [ "ubus call service delete", {} ] ]);
    t.ok(sync.start_worker());
    t.eq(stub.command_lines(), [ "ubus call service delete { \"name\": \"loki-ruleset-sync\" }" ]);
    stub.restore();
});

t.done();
