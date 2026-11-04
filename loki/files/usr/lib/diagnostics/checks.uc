// Modified for LoKi on 2026-11-01: report bounded core logs and known list overlaps.
// The Status tab checks return facts; the page judges them and words the verdict.

let fs = require("fs");
let resolv = require("resolv");
let common = require("core.common");
let exec = require("core.exec");
let constants = require("core.constants");
let core_ip = require("core.ip");
let core_url = require("core.url");
let uci = require("core.uci");
let netstat = require("core.netstat");
let packages = require("core.packages");
let core_version = require("core.version");
let runtime_dns = require("singbox.dns");
let runtime_rulesets = require("singbox.rulesets");
let singbox_constants = require("singbox.constants");
let features = require("singbox.features");
let config_status = require("singbox.config_status");
let connections = require("config.connections");
let health = require("service.health");
let mask = require("diagnostics.mask");
let conflicts = require("diagnostics.conflicts");

const CONFIG_NAME = constants.LOKI_CONFIG_NAME;
const STABLE_MIN_AGE = 2;
const DNS_INBOUND = singbox_constants.DNS_INBOUND_ADDRESS;
const FAKEIP_DOMAIN = singbox_constants.FAKEIP_TEST_DOMAIN;
const IP_DOMAIN = singbox_constants.CHECK_PROXY_IP_DOMAIN;
// A name no cache can answer, so a reply proves the upstream server was reached.
const UNCACHED_ZONE = "example.com";
const CGNAT_RANGE = "100.64.0.0/10";
const CORE_LOG_PATTERN = /^.{24} \[([0-9]+)\.[0-9]{3}\] [a-z0-9]+\.[a-z]+ loki-core(\[[0-9]+\])?: (.*)$/;

let paths = {
    proc: "/proc",
    meminfo: "/proc/meminfo",
    uptime: "/proc/uptime"
};

function settings() {
    return uci.get_all(CONFIG_NAME, "settings") ?? {};
}

function runtime_config() {
    return common.read_json_file(common.option(settings(), "config_path", ""));
}

function output(argv) {
    return exec.output(argv) ?? "";
}

function uptime_seconds() {
    return int(split(trim(fs.readfile(paths.uptime) ?? "0"), " ")[0]);
}

// The first error since Loki's last info line: every action opens and closes with one, and
// the later errors are mostly the cleanup's. Without an error, the last warning is the reason.
function last_error(log) {
    let error = null;
    let warning = null;
    for (let line in split(log ?? "", "\n")) {
        let entry = match(line, /loki(\[[0-9]+\])?: \[([a-z]+)\] (.*)$/);
        if (entry == null)
            continue;
        if (entry[2] == "info") {
            error = null;
            warning = null;
        }
        else if (entry[2] == "error" && error == null)
            error = entry[3];
        else if (entry[2] == "warn")
            warning = entry[3];
    }
    return error ?? warning ?? "";
}

// Keep this on demand: no resident reader, history or temporary log file.
const CORE_LOG_BYTES = 65536;
const CORE_LOG_LINES = 1000;

function core_log() {
    let unavailable = { available: false, count: 0, limited: false };
    let pipe = fs.popen(exec.command_line([ "logread", "-t", "-l", CORE_LOG_LINES, "-e", "^loki-core" ]) + " 2>/dev/null", "r");
    if (pipe == null)
        return unavailable;
    let text = pipe.read(CORE_LOG_BYTES + 1);
    let status = pipe.close();
    if (text == null)
        return unavailable;
    let limited = length(text) > CORE_LOG_BYTES;
    // Closing a full pipe can stop logread with SIGPIPE; other failures are not a zero count.
    if (status != 0 && !(limited && (status == -13 || status == 141)))
        return unavailable;
    if (limited)
        text = substr(text, 0, CORE_LOG_BYTES);
    let now = time();
    let count = 0;
    let lines = 0;
    // Parse one line at a time so many tiny lines cannot allocate a large split array.
    while (text != "" && lines < CORE_LOG_LINES) {
        let end = index(text, "\n");
        if (end < 0) {
            limited = true;
            break;
        }
        let line = substr(text, 0, end);
        text = substr(text, end + 1);
        lines++;
        let entry = match(line, CORE_LOG_PATTERN);
        if (entry == null) {
            limited = true;
            continue;
        }
        let stamp = int(entry[1]);
        if (stamp > now) {
            limited = true;
            continue;
        }
        let message = replace(entry[3], /\x1b\[[0-9;]*m/g, "");
        if (stamp > now - 60 && match(message, /^(ERROR|FATAL)([ \t]|\[)/) != null)
            count++;
    }
    return { available: true, count, limited: limited || lines >= CORE_LOG_LINES };
}

function meminfo() {
    let text = fs.readfile(paths.meminfo) ?? "";
    let value = (key) => int(match(text, regexp("(^|\n)" + key + ":[ \t]*([0-9]+)"))?.[2] ?? 0);
    return { total_kb: value("MemTotal"), available_kb: value("MemAvailable") };
}

// Loki itself runs `loki-core check` and `sing-box version` briefly; those hold no port.
function sing_box_cores() {
    let result = [];
    for (let dir in fs.glob(paths.proc + "/[0-9]*")) {
        let pid = fs.basename(dir);
        if (health.pid_is_sing_box(pid) && index(split(fs.readfile(dir + "/cmdline") ?? "", "\u0000"), "run") >= 0)
            push(result, int(pid));
    }
    return sort(result, (a, b) => a - b);
}

// The core that runs, as the binary reports itself: a package's files outlive a binary copied
// over them. The variant is the package's while the binary is of its build, which a +K suffix
// does not change.
function core() {
    let installed = fs.stat(features.paths.binary) != null;
    let binary = features.version();
    let version = packages.loki_core_version(binary);
    let build = (value) => split(value, "+")[0];
    return {
        installed,
        binary,
        version,
        variant: version != "" && build(version) == build(packages.sing_box_version()) ? packages.sing_box_variant() : "",
        outdated: version != "" && !core_version.version_at_least(version, constants.SB_REQUIRED_VERSION),
        required: constants.SB_REQUIRED_VERSION,
        problem: installed ? features.core_problem() : ""
    };
}

function list_overlaps() {
    let result = [];
    for (let section in uci.section_objects(CONFIG_NAME, "section")) {
        if (!common.bool_option(section, "enabled", true))
            continue;
        for (let overlap in runtime_rulesets.overlaps(connections.community_lists(section),
            [ ...connections.rule_sets(section), ...connections.rule_sets_with_subnets(section) ]))
            push(result, { section: connections.section_display_name(section), ...overlap });
    }
    return result;
}

function service() {
    let running = health.loki_stably_running(constants.RT_TABLE_NAME, constants.NFT_TABLE_NAME, constants.NFT_FAKEIP_MARK, STABLE_MIN_AGE);
    let pid = health.sing_box_service_pid_runtime();
    let own = pid > 0 && health.pid_is_sing_box(pid) ? pid : 0;
    return {
        running,
        uptime: own > 0 ? (health.process_age_seconds(own) ?? -1) : -1,
        last_error: running ? "" : last_error(output([ "logread", "-e", "^loki" ])),
        core: core(),
        foreign_sing_box: filter(sing_box_cores(), (found) => found != own),
        conflicts: conflicts.find(output([ "nft", "-t", "list", "ruleset" ])),
        core_log: core_log(),
        list_overlaps: list_overlaps(),
        memory: meminfo(),
        router_uptime: uptime_seconds()
    };
}

// One attempt within timeout ms: resolv counts attempts, and the version OpenWrt ships dies on 0.
// NXDOMAIN counts as an answer; SERVFAIL or REFUSED is the server failing.
function lookup(name, servers, timeout) {
    let start = common.monotonic_ms();
    let reply = resolv.query([ name ], { type: [ "A" ], nameserver: servers, timeout, retries: 1 });
    let ms = common.monotonic_ms() - start;
    let status = reply == null ? "" : reply[name]?.rcode ?? "NOERROR";
    if (status == "TIMEOUT")
        status = "";
    return { answered: status == "NOERROR" || status == "NXDOMAIN", status, ms: status == "" ? -1 : ms };
}

// A CNAME's target holds the records under its own name.
function addresses(reply, types) {
    let found = {};
    for (let name, records in reply ?? {})
        for (let kind in types)
            for (let address in records?.[kind] ?? [])
                found[address] = true;
    return keys(found);
}

function uncached_name() {
    let now = clock();
    return sprintf("loki-%x%x.%s", now[0], now[1], UNCACHED_ZONE);
}

// resolv speaks plain DNS only, and takes the port after a "#".
function plain_server(uri) {
    let parsed = runtime_dns.parse_server_uri(uri, false);
    return parsed.unsupported || parsed.type != "udp" ? null : parsed.server + "#" + parsed.server_port;
}

function bootstrap_host(values, servers, config) {
    for (let server in servers) {
        let host = core_url.host(server) || server;
        if (host != "" && !core_ip.valid_ip(host))
            return host;
    }
    if (!common.bool_option(values, "dns_detour_enabled", false))
        return "";
    for (let outbound in config?.outbounds ?? []) {
        let host = common.as_string(outbound?.server);
        if (host != "" && !core_ip.valid_ip(host))
            return host;
    }
    return "";
}

function dns() {
    let values = settings();
    let servers = runtime_dns.server_list(values, "dns_server", "77.88.8.8");
    let bootstraps = runtime_dns.server_list(values, "bootstrap_dns_server", "77.88.8.8");
    let host = bootstrap_host(values, servers, runtime_config());
    let testable = host == "" ? [] : filter(bootstraps, (server) => plain_server(server) != null);

    let main = lookup(uncached_name(), [ DNS_INBOUND + "#53" ], 4000);
    let local = lookup("localhost", [ "127.0.0.1#53" ], 3000);
    let bootstrap = null;
    if (length(testable) > 0) {
        bootstrap = { servers: join(", ", testable), host, answered: false, ms: -1 };
        for (let server in testable) {
            let result = lookup(host, [ plain_server(server) ], 3000);
            if (result.answered) {
                bootstrap.answered = true;
                bootstrap.ms = result.ms;
                break;
            }
        }
    }

    return {
        main: { servers: join(", ", map(servers, (server) => mask.dns_server(server))), ...main },
        bootstrap,
        local
    };
}

// A single domain is generated as a plain string, so both shapes are read.
function rule_names_domain(rule, domain) {
    return type(rule?.domain) == "array" ? index(rule.domain, domain) >= 0 : rule?.domain == domain;
}

function check_section(config) {
    for (let rule in config?.route?.rules ?? [])
        if (rule_names_domain(rule, IP_DOMAIN) && common.as_string(rule.outbound) != "")
            return common.as_string(rule.outbound);
    return "";
}

function check_answer(text) {
    let value = common.parse_json(text);
    return type(value) == "object" ? { fakeip: value.fakeip === true, ip: common.as_string(value.IP) } : null;
}

function in_fakeip_range(address) {
    return core_ip.prefix_contains(singbox_constants.FAKEIP_INET4_RANGE, address) ||
        core_ip.prefix_contains(singbox_constants.FAKEIP_INET6_RANGE, address);
}

// The router looks the check domain up through its resolver, which must hand out a FakeIP
// address, and fetches it; the endpoint reports whether the connection came through Loki.
// An excluded router reaches neither the capture nor a section, so nothing here can be seen.
function traffic() {
    if (connections.excluded_devices(settings()).router)
        return { router: { excluded: true, dns_fakeip: false, answered: false, fakeip: false, ip: "" }, exit: null };

    let section = check_section(runtime_config());
    let reply = resolv.query([ FAKEIP_DOMAIN ], { type: [ "A" ], timeout: 3000, retries: 1 });
    let commands = [ [ "uclient-fetch", "-q", "-O", "-", "--timeout=6", "https://" + FAKEIP_DOMAIN + "/check" ] ];
    if (section != "")
        push(commands, [ "uclient-fetch", "-q", "-O", "-", "--timeout=8", "https://" + IP_DOMAIN + "/check" ]);
    let results = exec.capture_parallel(commands);
    let router = check_answer(results[0].stdout);
    let exit = section == "" ? null : check_answer(results[1].stdout);

    return {
        router: {
            excluded: false,
            dns_fakeip: in_fakeip_range(addresses(reply, [ "A" ])[0] ?? ""),
            answered: router != null,
            fakeip: router?.fakeip ?? false,
            ip: router?.ip ?? ""
        },
        exit: section == "" ? null : { section, answered: exit != null, ip: exit?.ip ?? "" }
    };
}

return { paths, last_error, core_log, list_overlaps, core, service, dns, traffic };
