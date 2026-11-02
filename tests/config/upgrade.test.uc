// The released configurations in tests/fixtures, migrated as the package does it: each comes out
// as one 2.0.0 accepts and builds, routing, resolving and serving what the release did, and a
// second run leaves it alone. The released generators built every fixture.

let t = require("t");
let fs = require("fs");
let stub = require("stub");
let repo = require("repo");
let uci_file = require("uci_file");
let fixture = require("fixture");
let validation = require("validation");
let sb = require("sbconfig");
let generator = require("singbox.generator");
let migration = require("config.migration");
let v2 = require("config.migrations.v2_0_0");

// The files a router holds next to its configuration: the certificates the release issued and
// the user's own ones. The fixtures name them where the release put them.
let files = stub.tmpdir();
let issued = files + "/server-certs/";
fs.mkdir(issued);
fs.mkdir(files + "/acme");
v2.paths.certificates = issued;
v2.paths.subscription_cache = files + "/subscription-cache/";

function pem(label) {
    return "-----BEGIN " + label + "-----\nMIIB\n-----END " + label + "-----\n";
}

function released(name) {
    let text = fs.readfile(repo.path("tests/fixtures/" + name));
    text = replace(text, /\/etc\/forkop\/server-certs\//g, issued);
    text = replace(text, /\/etc\/ssl\/acme\//g, files + "/acme/");
    for (let path in match(text, /'([^']+\.(crt|key))'/g) ?? []) {
        let file = substr(path[0], 1, length(path[0]) - 2);
        fs.writefile(file, pem(substr(file, -4) == ".crt" ? "CERTIFICATE" : "PRIVATE KEY"));
    }
    return uci_file.parse(text);
}

function migrate(data) {
    let path = stub.tmpdir() + "/fixture.json";
    fs.writefile(path, sprintf("%J", data));
    stub.commands([ [ /\| md5sum$/, { stdout: "0123456789abcdef0123456789abcdef  -\n" } ] ]);
    let run = stub.capture(() => migration.main([ "migrate-fixture", path ]));
    stub.restore();
    t.eq(run.result, 0, run.stderr + run.stdout);
    return json(run.stdout);
}

function build(config) {
    validation.accepts(config);
    fixture.seed(config);
    return generator.build({ service_address: "192.168.1.1" });
}

function rule(config, outbound, predicate) {
    return sb.route_rule(config, (item) => item.outbound == outbound && sb.has(item.inbound, "tproxy-in") && predicate(item));
}

function headers(provider) {
    return map(keys(provider.headers), (name) => name + ": " + join(", ", provider.headers[name]));
}

function stays(upgraded) {
    let again = migrate(upgraded.config);
    t.eq([ again.decision.result, again.operations ], [ "current", null ], "a second run changes nothing");
}

/* --------------------------------------------------------------------- 1.0.5, a router */

let router105 = migrate(released("forkop-1.0.5-router.conf"));
let built105 = router105.config != null ? build(router105.config) : null;

t.test("1.0.5: the router's configuration migrates, saying what it could not keep", () => {
    t.eq([ router105.decision.result, router105.decision.from ], [ "migrate", "1.0.5" ]);
    t.eq(router105.warnings, [
        "Removed the Zapret section 'YouTube DPI': Forkop no longer runs DPI bypass",
        "Removed the ByeDPI section 'Discord DPI': Forkop no longer runs DPI bypass",
        "Removed the Zapret2 section 'Meta DPI': Forkop no longer runs DPI bypass",
        "Section 'Main proxy' no longer lists '/etc/forkop/lists/custom.txt': the file is missing or holds no entry, " +
            "which Forkop no longer starts with. Add it again once it holds the list",
        "Server 'Family SOCKS' accepts the account 'Family-SOCKS' instead of 'Family SOCKS', since an account name holds " +
            "only letters, digits, '.', '_' and '-': use it in its clients",
        "Removed the MTProto server 'Telegram': Forkop no longer serves MTProto",
        "Fallback group 'Failover' in section 'Main proxy' takes the first working server of a level in its order, not " +
            "the fastest one: add a URLTest group to a level to pick by speed there"
    ]);
    stays(router105);
});

t.test("1.0.5: each section routes what it routed, and the DPI sections route nothing", () => {
    let own = rule(built105, "Main proxy", (item) => sb.has(item.domain_suffix, "example.com"));
    t.eq([ own.domain, own.domain_keyword, own.ip_cidr, own.port, own.port_range ],
        [ [ "exact.example.org" ], [ "tracker" ], [ "203.0.113.0/24" ], [ 443 ], [ "8000:8100" ] ]);
    let lists = sb.route_rule(built105, (item) => item.type == "logical" && sb.has(item.rules[0].inbound, "tproxy-in") &&
        sb.has(item.rules[0].rule_set, "main-youtube-community-ruleset"));
    t.eq([ lists.outbound, lists.rules[0].rule_set, lists.rules[1].port ], [ "Main proxy", [
        "main-youtube-community-ruleset", "inline-custom-3d6e62992dfe-ruleset", "inline-custom-0bd84540f447-ruleset",
        "inline-custom-27c02d3e0dd3-ruleset" ], [ 443 ] ]);
    t.eq(sb.ruleset(built105, "inline-custom-27c02d3e0dd3-ruleset").url, "https://example.com/with-subnets.json");
    t.eq(sb.ruleset(built105, "inline-custom-0bd84540f447-ruleset").url,
        "https://github.com/itdoginfo/allow-domains/releases/latest/download/russia_inside.srs",
        "Russia inside stays the list 1.0.5 downloaded");
    t.eq(sb.ruleset(built105, "main-youtube-community-ruleset").url,
        "https://github.com/ushan0v/forkop-lists/releases/latest/download/youtube.srs");
    t.ok(rule(built105, "Backup", (item) => item.rule_set == "backup-telegram-community-ruleset"), "Backup keeps Telegram");
    let bypass = rule(built105, "direct-out", (item) => item.source_ip_cidr != null);
    t.eq([ bypass.ip_cidr, bypass.source_ip_cidr ], [ [ "192.168.100.0/24" ], [ "192.168.1.50", "192.168.1.51" ] ]);
    t.ok(sb.route_rule(built105, (item) => item.action == "reject" && item.rule_set == "ads-ads-community-ruleset"),
        "Ads are still refused");
    t.eq(filter(sb.tags(built105.outbounds), (tag) => index(tag, "DPI") >= 0 || index(tag, "TV") == 0), [],
        "neither the DPI sections nor the disabled one have an outbound");
    t.eq(sb.ruleset(built105, "youtube-youtube-community-ruleset"), null);
    t.eq(router105.config.settings.unmatched_dns_mode, null, "dnsmasq stays the router's resolver of last resort");
});

t.test("1.0.5: DNS asks the same servers through the same section", () => {
    let servers = map([ "dns-server-1", "dns-server-2" ], (tag) => sb.dns_server_tag(built105, tag));
    t.eq(map(servers, (server) => [ server.type, server.server, server.server_port, server.path, server.detour ]), [
        [ "https", "dns.google", 443, "/dns-query", "Main proxy" ], [ "https", "1.1.1.1", 443, "/dns-query", "Main proxy" ] ]);
    t.eq(map([ "bootstrap-dns-server-1", "bootstrap-dns-server-2" ], (tag) => sb.dns_server_tag(built105, tag).server),
        [ "77.88.8.8", "8.8.8.8" ]);
    let google = sb.dns_server_tag(built105, "google_dns-dns-server");
    t.eq([ google.type, google.server, google.server_port ], [ "tls", "8.8.8.8", 853 ]);
    t.ok(sb.dns_rule(built105, (item) => item.server == "google_dns-dns-server" && sb.has(item.domain_suffix, "googleapis.com")),
        "the DNS section answers its domains");
    let awg = sb.outbound(built105, "Main proxy/awg0");
    t.eq([ awg.bind_interface, sb.dns_server_tag(built105, awg.domain_resolver).server ], [ "awg0", "dns.adguard-dns.com" ]);
    t.eq(sb.outbound(built105, "Main proxy/Office #2").domain_resolver, { server: "bootstrap-dns-server", strategy: "ipv4_only" },
        "the JSON outbound resolves as the core of 1.0.5 did");
});

t.test("1.0.5: groups and subscriptions behave as they did", () => {
    let fastest = sb.outbound(built105, "Main proxy/Fastest");
    t.eq([ fastest.interval, fastest.tolerance, fastest.idle_timeout, fastest.interrupt_exist_connections, fastest.include ],
        [ "3m", 50, "30m", true, "(?:(?:(?:🇩🇪)|(?:🇳🇱)))" ]);
    t.eq(sb.outbound(built105, "Main proxy/Europe without Dallas").interrupt_exist_connections, false);
    let failover = sb.outbound(built105, "Main proxy/Failover");
    t.eq([ failover.type, failover.url, failover.interrupt_exist_connections, length(failover.groups), failover.groups[2].outbounds ],
        [ "fallback", "https://www.gstatic.com/generate_204", true, 3, [ "direct-out" ] ]);
    t.eq(sb.outbound(built105, "Main proxy").default, "Main proxy/Fastest");
    let own = sb.provider(built105, "Main proxy/sub1");
    t.eq([ own.url, own.update_interval, own.download_detour ], [ "https://panel.example.com/sub/abcdef", "6h", null ]);
    t.matches(own.headers["User-Agent"][0], /^sing-box/);
    t.eq([ own.headers["Accept-Language"], own.headers["X-Device-Locale"] ], [ [ "ru-RU,en,*" ], [ "EN" ] ]);
    let other = sb.provider(built105, "Main proxy/Other");
    t.eq([ other.headers["User-Agent"], other.headers["X-HWID"], other.download_detour, other.override ],
        [ [ "Happ" ], [ "MY-HWID-0001" ], "Backup", { prefix: "Other " } ]);
});

/* --------------------------------------------------------------------- 1.0.2, a router */

let router102 = migrate(released("forkop-1.0.2-router.conf"));
let built102 = router102.config != null ? build(router102.config) : null;

t.test("1.0.2: the router's configuration migrates through 1.0.5's step", () => {
    t.eq([ router102.decision.result, router102.decision.from ], [ "migrate", "1.0.2" ]);
    t.eq(router102.warnings, [
        "Removed the Zapret section 'YouTube': Forkop no longer runs DPI bypass",
        "Removed the ByeDPI section 'Discord': Forkop no longer runs DPI bypass",
        "Server 'SS 2022' gives each Shadowsocks 2022 client a key of its own now, which a link holds next to the server " +
            "key: hand its clients the new link"
    ]);
    stays(router102);
});

t.test("1.0.2: HTTP links became HTTP outbounds, and text conditions match as 1.0.5 matched them", () => {
    let office = sb.outbound(built102, "Proxy/Office HTTPS");
    t.eq([ office.type, office.server, office.server_port, office.username, office.password, office.tls ],
        [ "http", "proxy.example.com", 8443, "office", "office-pass", { enabled: true } ]);
    t.eq([ sb.outbound(built102, "Proxy/http").server, sb.outbound(built102, "Proxy/http").server_port ], [ "203.0.113.41", 3128 ]);
    let work = rule(built102, "Work", (item) => item.domain != null);
    t.eq([ work.domain, work.ip_cidr, work.port ], [ [ "corp.example.com", "jira.example.com" ], [ "10.20.0.0/16" ], [ 22, 8443 ] ]);
    let nas = require("nft.sections").matchers(filter(router102.config.section, (item) => item[".name"] == "nas")[0]);
    t.eq([ nas.action, nas.needed, nas.fully.ips ], [ "bypass", true, [ "192.168.1.5" ] ], "the device still skips Forkop");
    t.eq(router102.config.settings.unmatched_dns_mode, "router", "dont_touch_dhcp left unmatched queries with the router");
    t.eq(map([ "dns-server-1", "dns-server-2" ], (tag) => sb.dns_server_tag(built102, tag).server), [ "77.88.8.8", "77.88.8.1" ]);
});

t.test("1.0.2: groups and the subscription carry over", () => {
    let auto = sb.outbound(built102, "Proxy/Auto");
    t.eq([ auto.exclude, auto.interrupt_exist_connections, auto.providers ], [ "(?:(?:🇷🇺))", true, [ "Proxy/Sub" ] ]);
    let reserve = sb.outbound(built102, "Proxy/Reserve");
    t.eq([ reserve.interrupt_exist_connections, reserve.groups[0].include ], [ false, "(?:^(?:Finland)$)" ]);
    let subscription = sb.provider(built102, "Proxy/Sub");
    t.eq([ subscription.update_interval, subscription.override ], [ "12h", { prefix: "Sub " } ]);

});

/* --------------------------------------------------------- the forms older releases wrote */

let legacy = migrate(released("forkop-1.0.2-legacy.conf"));
let built_legacy = legacy.config != null ? build(legacy.config) : null;

t.test("the forms releases before 1.0.2 wrote mean what 1.0.5 read in them", () => {
    t.eq([ legacy.decision.result, legacy.warnings ], [ "migrate", [] ]);
    t.eq(map(legacy.config.section, (item) => item.action), [ "connection", "connection", "connection" ]);
    let vpn = rule(built_legacy, "VPN", (item) => item.domain_suffix != null);
    t.eq([ vpn.domain_suffix, vpn.port, sb.outbound(built_legacy, "VPN/wg0").bind_interface ],
        [ [ "netflix.com", "nflxvideo.net" ], [ 443 ], "wg0" ]);
    t.eq(rule(built_legacy, "Old proxy", (item) => true).domain, [ "example.org", "example.net" ]);
    t.eq(rule(built_legacy, "JSON", (item) => true).ip_cidr, [ "198.51.100.0/24" ]);
    t.eq(sb.outbound(built_legacy, "JSON/Upstream SOCKS").server, "192.0.2.80");
    let fast = sb.outbound(built_legacy, "Old proxy/Fast");
    t.eq([ fast.interval, fast.idle_timeout, fast.exclude ], [ "2m", "10m", "(?:(?:🇷🇺))" ]);
    let subscription = sb.provider(built_legacy, "Old proxy/Legacy");
    t.eq([ subscription.url, subscription.headers["User-Agent"], subscription.override ],
        [ "https://legacy.example.com/sub", [ "ClashMeta" ], { prefix: "Legacy " } ]);
    stays(legacy);
});

/* --------------------------------------------- 1.0.5's own configuration with its examples */

let examples = migrate(released("forkop-1.0.5.conf"));

t.test("legacy example records cannot restore removed server listeners", () => {
    t.eq(examples.decision.result, "migrate");
    let config = build(examples.config);
    let tags = map([ ...(config.inbounds ?? []), ...(config.endpoints ?? []) ], (item) => item.tag);
    for (let label in [ "JSON inbound", "VLESS Reality server", "Tailscale endpoint" ])
        t.excludes(tags, label);
    t.eq(filter(examples.config.server, (server) => server.protocol == "mtproto"), [], "MTProto is not served any more");
    let outbounds = sb.tags(config.outbounds);
    t.contains(outbounds, "Subscription");
    t.contains(outbounds, "JSON outbound");
    stays(examples);
});

t.done();
