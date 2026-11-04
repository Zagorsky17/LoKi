// Modified for LoKi on 2026-11-01: report known list overlaps without changing routing.
let t = require("t");
let stub = require("stub");
let fs = require("fs");
let fixture = require("fixture");
let uci = require("uci");
let exec = require("core.exec");
let clash_api = require("singbox.clash_api");
let resolv = require("resolv");
let health = require("service.health");
let checks = require("diagnostics.checks");

let dir = stub.tmpdir();
let real_parallel = exec.capture_parallel;

// What each command a check runs at once answers, by its argv; a command the
// table does not know fails the test.
function parallel(answers) {
    let asked = [];
    exec.capture_parallel = function(commands) {
        return map(commands, (argv) => {
            let line = join(" ", argv);
            push(asked, line);
            for (let answer in answers)
                if (match(line, answer[0]) != null)
                    return { status: 0, stdout: answer[1] };
            die("unexpected command: " + line);
        });
    };
    return asked;
}

// What each DNS query answers, by a regexp over "name@nameservers", with the milliseconds the
// reply takes on a clock that moves only then; a query the table does not know fails the test.
let ticks = 0;
function dns_replies(table) {
    global.clock = () => [ 1000, ticks++ ];
    return resolv.__answer((names, options) => {
        let line = names[0] + "@" + join(",", options.nameserver ?? [ "resolv.conf" ]);
        for (let entry in table)
            if (match(line, entry[0]) != null) {
                ticks += (entry[2] ?? 0) * 1000000;
                return entry[1](names[0]);
            }
        die("unexpected DNS query: " + line);
    });
}

// The core's answer about its Tailscale endpoints, or its failure for null; the returned
// function puts the real request back.
function tailscale(reply) {
    let real = clash_api.request;
    clash_api.request = (method, path) => {
        if (reply == null)
            die("Clash API request failed: " + method + " " + path);
        return { status: 200, body: sprintf("%J", reply) };
    };
    return () => { clash_api.request = real; };
}

function rcode(status) {
    return (name) => {
        let reply = {};
        if (status != "NOERROR")
            reply[name] = { rcode: status };
        return reply;
    };
}

function records(kind, ...values) {
    return (name) => {
        let reply = {};
        reply[name] = {};
        reply[name][kind] = values;
        return reply;
    };
}

function write_config(config) {
    fs.writefile(dir + "/config.json", sprintf("%J", config));
}

t.test("the reason Loki is down is the first error of the last action, not what its cleanup ran into", () => {
    let line = (level, message) => "Mon Oct 19 16:51:18 2026 user." + level + " loki: [" + level + "] " + message;
    t.eq(checks.last_error(join("\n", [ line("info", "Starting LoKi"), line("error", "Another loki-core process is running outside LoKi"),
        line("error", "loki-core is still running after it was stopped"), line("warn", "LoKi did not start") ])),
        "Another loki-core process is running outside LoKi");
    t.eq(checks.last_error(join("\n", [ line("error", "An old failure"), line("info", "LoKi started"), line("info", "Stopping LoKi"),
        line("info", "LoKi stopped") ])), "", "a stop the user asked for left no error");
    t.eq(checks.last_error(join("\n", [ line("info", "Starting LoKi"), line("error", "first try"), line("info", "Starting LoKi"),
        line("error", "second try") ])), "second try", "the last attempt, not an earlier one");
    t.eq(checks.last_error("Mon Oct 19 16:51:18 2026 daemon.err loki-core[1]: FATAL[0000] start service"), "", "the core's own lines are not LoKi's");
    t.eq(checks.last_error(join("\n", [ line("info", "Starting LoKi"), line("error", "an earlier failure"), line("info", "Starting LoKi"),
        line("warn", "LoKi has nothing to run") ])), "LoKi has nothing to run", "an action that did not fail, by its last warning");
});

t.test("list overlap facts include only enabled sections and fixed list identifiers", () => {
    fixture.seed({ section: [
        { ".name": "MAIN", enabled: "1", action: "bypass", community_lists: [ "telegram" ], rule_set: [ "telegram", "https://other.test/telegram.srs?token=TEST_SECRET" ] },
        { ".name": "OFF", enabled: "0", action: "bypass", community_lists: [ "telegram" ], rule_set: [ "telegram" ] }
    ] });
    t.eq(checks.list_overlaps(), [ { section: "MAIN", builtin: "telegram", external: "forkop-lists/telegram.srs", relation: "same_source" } ]);
    fixture.seed({});
});

t.test("the service check finds running cores other than Loki's, and nothing Loki runs for a moment", () => {
    let proc = dir + "/proc";
    for (let process in [ [ "100", [ "/usr/bin/loki-core", "run", "-c", "/etc/loki-core/config.json" ] ],
        [ "200", [ "/usr/bin/loki-core", "run", "-c", "/tmp/probe.json" ] ], [ "300", [ "loki-core", "check", "-c", "x" ] ], [ "400", [ "/sbin/procd" ] ] ]) {
        fs.mkdir(proc);
        fs.mkdir(proc + "/" + process[0]);
        fs.writefile(proc + "/" + process[0] + "/cmdline", join("\u0000", process[1]) + "\u0000");
    }
    checks.paths.proc = proc;
    checks.paths.meminfo = dir + "/meminfo";
    checks.paths.uptime = dir + "/uptime";
    fs.writefile(checks.paths.meminfo, "MemTotal:         239540 kB\nMemFree:           26652 kB\nMemAvailable:      45536 kB\n");
    fs.writefile(checks.paths.uptime, "100700.12 300000.00\n");
    health.loki_stably_running = () => false;
    health.sing_box_service_pid_runtime = () => 100;
    health.pid_is_sing_box = (pid) => index([ "100", "200", "300" ], "" + pid) >= 0;
    health.process_age_seconds = () => 42;
    stub.commands([
        [ /'logread'/, { stdout: "Mon Oct 19 16:51:18 2026 user.info loki: [info] Starting LoKi\nMon Oct 19 16:51:18 2026 user.err loki: [error] Clash API address 192.168.1.1:9090 is already in use by another process\n" } ],
        [ /'nft' '-t' 'list' 'ruleset'/, { stdout: "table inet other {\n\tchain c {\n\t\ttype filter hook prerouting priority mangle; policy accept;\n\t\tmeta l4proto tcp tproxy ip to :7893\n\t}\n}\n" } ]
    ]);
    let packages = require("core.packages");
    packages.paths.sing_box_version = dir + "/no-such-version";
    packages.paths.sing_box_variant = dir + "/no-such-variant";
    require("singbox.features").paths.binary = dir + "/no-such-loki-core";
    let value = checks.service();
    stub.restore();
    t.eq([ value.running, value.uptime, value.foreign_sing_box ], [ false, 42, [ 200 ] ]);
    t.eq(value.core, { installed: false, binary: "", version: "", variant: "", outdated: false,
        required: require("core.constants").SB_REQUIRED_VERSION, problem: "" }, "no core at all");
    t.eq(value.last_error, "Clash API address 192.168.1.1:9090 is already in use by another process");
    t.eq(value.conflicts, [ { table: "inet other", kind: "tproxy" } ]);
    t.eq(value.list_overlaps, []);
    t.eq([ value.memory, value.router_uptime ], [ { total_kb: 239540, available_kb: 45536 }, 100700 ]);
});

t.test("the core check names the version the binary reports, and the package's variant while it is that build", () => {
    let packages = require("core.packages");
    let features = require("singbox.features");
    packages.paths.sing_box_version = dir + "/version";
    packages.paths.sing_box_variant = dir + "/variant";
    features.paths.binary = dir + "/loki-core";
    let required = require("core.constants").SB_REQUIRED_VERSION;
    fs.writefile(packages.paths.sing_box_version, required + "
");
    fs.writefile(packages.paths.sing_box_variant, "tiny
");
    let core_of = (version, tags) => {
        fs.writefile(features.paths.binary, "#!/bin/sh
# " + version + " " + tags + "
");
        stub.commands([ [ features.paths.binary + " version",
            { status: 0, stdout: "sing-box version " + version + "

Tags: " + tags + "
CGO: disabled
" } ] ]);
        let value = checks.core();
        stub.restore();
        return value;
    };
    let tags = "with_clash_api,with_utls,with_quic";
    t.eq(core_of(required, tags), { installed: true, binary: required, version: required, variant: "tiny",
        outdated: false, required, problem: "" });
    t.eq(core_of(required + "+72", tags).variant, "tiny", "a build between releases of the package's release");
    t.ok(core_of("1.14.4-r1", tags).outdated, "the core before the bootstrap fix is outdated");
    t.ok(core_of("1.14.4-r2", tags).outdated, "the core before error repeat suppression is outdated");
    t.eq(core_of("1.14.5-r1", tags).variant, "", "a binary of another build copied over the package's");

    let foreign = core_of("1.12.22", tags);
    t.eq([ foreign.binary, foreign.version, foreign.variant, foreign.outdated ], [ "1.12.22", "", "", false ], "not loki-core");
    let old = core_of("1.13.18-extended-2.6.5-f165", tags);
    t.eq([ old.version, old.outdated ], [ "", false ], "an unrelated fork is not classified as an outdated own build");
    t.eq(old.binary, "1.13.18-extended-2.6.5-f165", "diagnostics retain the actual unsupported binary version");

    t.contains(core_of("1.14.4-r1", "with_utls,with_quic").problem, "loki-core was built without with_clash_api");
    t.eq(core_of("1.14.4-r1", "with_clash_api,with_wireguard,with_openvpn").problem, "");
});

t.test("a DNS reply counts when the server resolved the name, whatever the name turned out to be", () => {
    fixture.seed({ settings: { dns_server: [ "77.88.8.8" ], config_path: dir + "/config.json" } });
    let main = (reply, ms) => {
        dns_replies([ [ /@127\.0\.0\.42#53$/, reply, ms ], [ /^localhost@/, rcode("NOERROR") ] ]);
        let value = checks.dns().main;
        stub.restore();
        return [ value.answered, value.status, value.ms ];
    };
    t.eq(main(rcode("NXDOMAIN"), 23), [ true, "NXDOMAIN", 23 ]);
    t.eq(main(records("A", "203.0.113.1"), 12), [ true, "NOERROR", 12 ]);
    t.eq(main(rcode("SERVFAIL"), 4), [ false, "SERVFAIL", 4 ]);
    t.eq(main(rcode("TIMEOUT"), 4000), [ false, "", -1 ], "a server that never answered has no status");
    t.eq(main(() => null, 0), [ false, "", -1 ], "nor has a query resolv refused");
});

t.test("the main DNS is asked through the core for a name no cache holds; bootstrap is skipped when nothing needs it", () => {
    fixture.seed({ settings: { dns_server: [ "77.88.8.8" ], bootstrap_dns_server: [ "77.88.8.8" ], config_path: dir + "/config.json" } });
    write_config({ outbounds: [ { type: "vless", tag: "a", server: "proxy.example" } ] });
    let asked = dns_replies([ [ /@127\.0\.0\.42#53$/, rcode("NOERROR"), 12 ], [ /^localhost@127\.0\.0\.1#53$/, records("A", "127.0.0.1") ] ]);
    let value = checks.dns();
    stub.restore();
    t.eq(value.main, { servers: "77.88.8.8", answered: true, status: "NOERROR", ms: 12 });
    t.eq([ value.bootstrap, value.local.answered ], [ null, true ]);
    t.matches(asked[0].names[0], /^loki-[0-9a-f]+\.example\.com$/);
    t.eq([ asked[0].options.type, asked[0].options.timeout, asked[0].options.retries ], [ [ "A" ], 4000, 1 ], "one attempt, as a page waits for it");
});

t.test("each run asks a name of its own", () => {
    fixture.seed({ settings: { config_path: dir + "/config.json" } });
    let asked = dns_replies([ [ /@127\.0\.0\.42#53$/, rcode("NOERROR") ], [ /^localhost@/, rcode("NOERROR") ] ]);
    checks.dns();
    checks.dns();
    stub.restore();
    t.ok(asked[0].names[0] != asked[2].names[0], asked[0].names[0] + " and " + asked[2].names[0]);
});

t.test("bootstrap is asked directly for the main server it exists to find, where it speaks plain DNS", () => {
    fixture.seed({ settings: { dns_server: [ "https://dns.example/dns-query" ], bootstrap_dns_server: [ "1.1.1.1",
        "udp://[2606:4700::1111]:5353", "https://9.9.9.9/dns-query", "quic://8.8.8.8", "8.8.4.4" ], config_path: dir + "/config.json" } });
    let asked = dns_replies([
        [ /@127\.0\.0\.42#53$/, rcode("TIMEOUT"), 4000 ],
        [ /^localhost@/, rcode("NOERROR") ],
        [ /^dns\.example@1\.1\.1\.1#53$/, rcode("TIMEOUT"), 3000 ],
        [ /^dns\.example@2606:4700::1111#5353$/, records("A", "203.0.113.7"), 31 ]
    ]);
    let value = checks.dns();
    stub.restore();
    t.eq(value.bootstrap, { servers: "1.1.1.1, udp://[2606:4700::1111]:5353, 8.8.4.4", host: "dns.example", answered: true, ms: 31 },
        "resolv speaks neither DoH nor QUIC, and the first server that answers is enough");
    t.eq(value.main.answered, false);
    t.eq(length(asked), 4, "8.8.4.4 is not asked once a server answered");
});

t.test("with DNS sent through a section, bootstrap finds the proxy servers", () => {
    fixture.seed({ settings: { dns_server: [ "8.8.8.8" ], bootstrap_dns_server: [ "77.88.8.8" ], dns_detour_enabled: "1",
        dns_detour_section: "s1", config_path: dir + "/config.json" }, section: [ { ".name": "s1", label: "Proxy" } ] });
    write_config({ outbounds: [ { type: "direct", tag: "direct-out" }, { type: "vless", tag: "a", server: "proxy.example" } ] });
    dns_replies([ [ /@127\.0\.0\.42#53$/, rcode("NOERROR") ], [ /^localhost@/, rcode("NOERROR") ], [ /^proxy\.example@77\.88\.8\.8#53$/, rcode("NOERROR"), 5 ] ]);
    let value = checks.dns();
    stub.restore();
    t.eq([ value.bootstrap?.host, value.bootstrap?.ms ], [ "proxy.example", 5 ]);
});

t.test("the router's own traffic is checked the way a client's goes, and the exit through the first section", () => {
    fixture.seed({ settings: { config_path: dir + "/config.json" } });
    write_config({ route: { rules: [ { action: "sniff" }, { action: "route", inbound: [ "tproxy-in" ], outbound: "Main", domain: "ip.podkop.fyi" } ] } });
    let lookups = dns_replies([ [ /^fakeip\.podkop\.fyi@resolv\.conf$/, records("A", "198.18.0.7") ] ]);
    let asked = parallel([
        [ /^uclient-fetch -q -O - --timeout=6 https:\/\/fakeip\.podkop\.fyi\/check$/, "{\"fakeip\": true, \"IP\": \"203.0.113.5\"}" ],
        [ /^uclient-fetch -q -O - --timeout=8 https:\/\/ip\.podkop\.fyi\/check$/, "{\"fakeip\": false, \"IP\": \"198.51.100.9\"}" ]
    ]);
    t.eq(checks.traffic(), {
        router: { excluded: false, dns_fakeip: true, answered: true, fakeip: true, ip: "203.0.113.5" },
        exit: { section: "Main", answered: true, ip: "198.51.100.9" }
    });
    t.eq([ length(lookups), length(asked) ], [ 1, 2 ]);

    write_config({ route: { rules: [] } });
    dns_replies([ [ /^fakeip\.podkop\.fyi@/, records("A", "93.184.215.14") ] ]);
    asked = parallel([ [ /fakeip\.podkop\.fyi\/check/, "<html>blocked</html>" ] ]);
    t.eq(checks.traffic(), { router: { excluded: false, dns_fakeip: false, answered: false, fakeip: false, ip: "" }, exit: null });
    t.eq(length(asked), 1, "no section, no exit to check");

    dns_replies([ [ /^fakeip\.podkop\.fyi@/, (name) => ({ "fakeip.podkop.fyi": { CNAME: [ "fake.example.net" ] }, "fake.example.net": { A: [ "198.18.0.9" ] } }) ] ]);
    parallel([ [ /fakeip\.podkop\.fyi\/check/, "" ] ]);
    t.eq(checks.traffic().router.dns_fakeip, true, "the address a CNAME leads to is the answer");
    stub.restore();
});

t.test("a router excluded from routing is not checked, nor is the exit it would take", () => {
    fixture.seed({ settings: { config_path: dir + "/config.json", routing_excluded_ips: [ "192.168.1.50", "@system" ] } });
    write_config({ route: { rules: [ { action: "route", inbound: [ "tproxy-in" ], outbound: "Main", domain: "ip.podkop.fyi" } ] } });
    let lookups = dns_replies([]);
    let asked = parallel([]);
    t.eq(checks.traffic(), { router: { excluded: true, dns_fakeip: false, answered: false, fakeip: false, ip: "" }, exit: null });
    stub.restore();
    t.eq([ asked, lookups ], [ [], [] ]);
});

exec.capture_parallel = real_parallel;
t.done();
