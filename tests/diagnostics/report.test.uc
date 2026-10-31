let t = require("t");
let stub = require("stub");
let fs = require("fs");
let fixture = require("fixture");
let report = require("diagnostics.report");

let dir = stub.tmpdir();
report.paths.forkop_config = dir + "/forkop";

const TABLE = "table inet ForkopTable {\n\tset localv4 {\n\t\ttype ipv4_addr\n\t\tflags interval\n\t\tauto-merge\n\t}\n\n" +
    "\tset forkop_interfaces {\n\t\ttype ifname\n\t\tflags interval\n\t}\n\n" +
    "\tchain mangle {\n\t\ttype filter hook prerouting priority mangle + 1; policy accept;\n\t\tip daddr @localv4 return\n\t}\n}\n";

function seed() {
    fixture.seed({ settings: { config_path: dir + "/config.json", dns_server: [ "77.88.8.8", "https://dns.google/dns-query" ], bootstrap_dns_server: [ "tls://1.1.1.1" ] }, server: [ { ".name": "s", public_host: "vpn.example", tls_server_name: "2a00:1450::1" } ] });
    fs.writefile(dir + "/config.json", sprintf("%J", { outbounds: [ { type: "vless", tag: "Main", server: "node.example", uuid: "uuid-secret" } ] }));
    fs.writefile(report.paths.forkop_config, "config section 'main'\n\toption label 'Main via node.example'\n\toption proxy_string 'vless://uuid-secret@node.example:443'\n");
    let log = "";
    for (let i = 1; i <= 60; i++)
        log += sprintf("Mon Oct 19 17:05:01 2026 user.info forkop: [info] line %d\n", i);
    for (let i = 1; i <= 60; i++)
        log += sprintf("Mon Oct 19 17:05:02 2026 daemon.err sing-box[1]: ERROR dial tcp node.example:443 (185.199.108.9) %d\n", i);
    log += "Mon Oct 19 17:05:03 2026 user.info forkop: [info] line 61\n";
    stub.commands([
        [ /'logread'/, { stdout: log } ],
        [ /'nft' '-t' 'list' 'table' 'inet' 'ForkopTable'/, { stdout: TABLE } ],
        [ /'ip' '-4' 'rule'/, { stdout: "105:\tfrom all fwmark 0x4000000/0x4000000 lookup forkop\n" } ],
        [ /'ip' '-6' 'rule'/, { stdout: "" } ]
    ]);
}

t.test("a masked report hides the credentials, the configured servers and public addresses everywhere it repeats them", () => {
    seed();
    let value = report.report("masked", "Main: 443/tcp · vpn.example\nExit: 185.199.108.9, direct 192.168.1.1\nMain DNS: 77.88.8.8 · 12 ms\nBootstrap DNS: tls://1.1.1.1 · 30 ms\n");
    stub.restore();
    let text = join("\n", [ value.checks, value.log, value.forkop_config ]);
    for (let secret in [ "uuid-secret", "node.example", "vpn.example", "185.199.108.9" ])
        t.excludes(text, secret);
    t.eq(value.checks, "Main: 443/tcp · MASKED\nExit: X.X.X.9, direct 192.168.1.1\nMain DNS: 77.88.8.8 · 12 ms\nBootstrap DNS: tls://1.1.1.1 · 30 ms\n",
        "the checks the page ran are masked by the same rules, and the resolvers asked stay readable");
    t.contains(value.forkop_config, "option label 'Main via MASKED'");
    t.contains(value.log, "X.X.X.9");
    t.eq(value.ip_rules, "105:\tfrom all fwmark 0x4000000/0x4000000 lookup forkop\n");
});

t.test("the report leaves out what the Forkop configuration already determines", () => {
    seed();
    let value = report.report("raw", "");
    stub.restore();
    t.eq(sort(keys(value)), [ "checks", "forkop_config", "ip_rules", "log", "nftables", "notice", "visibility" ], "privacy metadata, no sing-box configuration");
    t.eq(value.nftables, "table inet ForkopTable {\n\tchain mangle {\n\t\ttype filter hook prerouting priority mangle + 1; policy accept;\n\t\tip daddr @localv4 return\n\t}\n}\n",
        "the chains without the declarations of the sets they use");
});

t.test("the log keeps the last lines of Forkop and of the core apart, so the core's errors never push Forkop's out", () => {
    seed();
    let value = report.report("raw", "Main: vpn.example");
    stub.restore();
    let lines = split(rtrim(value.log, "\n"), "\n");
    t.eq(length(lines), 100);
    t.matches(lines[0], /line 12$/);
    t.matches(lines[48], /line 60$/);
    t.matches(lines[49], /\(185\.199\.108\.9\) 11$/);
    t.matches(lines[98], /\(185\.199\.108\.9\) 60$/);
    t.matches(lines[99], /line 61$/, "in the order they were logged");
});

t.test("a raw report is the router as it is", () => {
    seed();
    let value = report.report("raw", "Main: vpn.example");
    stub.restore();
    t.contains(value.log, "node.example:443 (185.199.108.9)");
    t.contains(value.forkop_config, "vless://uuid-secret@node.example:443");
    t.eq(value.checks, "Main: vpn.example");
});

t.test("raw reports identify their secrets before any attachments, while other modes stay masked", () => {
    for (let visibility in [ "raw", "masked", "RAW", "" ]) {
        seed();
        let value = report.report(visibility, "Main: vpn.example");
        stub.restore();
        t.eq(value.visibility, visibility == "raw" ? "raw" : "masked");
        t.contains(value.notice, visibility == "raw" ? "UNMASKED REPORT" : "MASKED REPORT");
        if (visibility == "raw")
            t.contains(value.notice, "Do not share");
        else
            t.excludes(sprintf("%J", value), "uuid-secret");
    }
});

t.test("configured credentials repeated in any masked attachment stay private", () => {
    seed();
    fixture.seed({ settings: { config_path: dir + "/config.json", mixed_proxy_password: "report-password" } });
    fs.writefile(report.paths.forkop_config, "config settings 'settings'\n\toption mixed_proxy_password 'report-password'\n\toption label 'report-password at 185.199.108.9'\n");
    stub.commands([ [ () => true, { stdout: "report-password uuid-secret 185.199.108.9\n" } ] ]);
    let value = report.report("masked", "report-password uuid-secret 185.199.108.9\n");
    stub.restore();
    for (let key in [ "checks", "log", "forkop_config", "nftables", "ip_rules" ])
        for (let secret in [ "report-password", "uuid-secret", "185.199.108.9" ])
            t.excludes(value[key], secret, key + " must hide a repeated credential or public address");
});

t.done();
