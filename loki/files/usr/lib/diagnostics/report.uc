// Modified for LoKi on 2026-11-01: identify report visibility and mask every attachment consistently.
let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let constants = require("core.constants");
let core_ip = require("core.ip");
let core_url = require("core.url");
let uci = require("core.uci");
let mask = require("diagnostics.mask");

const LOG_LINES = 50;

// logread's line: ctime, facility.level, then the message with its tag.
const CORE_LINE = /^.{24} [a-z]+\.[a-z]+ loki-core\[/;

let paths = {
    loki_config: "/etc/config/loki"
};

function output(argv) {
    return exec.output(argv) ?? "";
}

function log_tail(text) {
    let lines = filter(split(text ?? "", "\n"), (line) => line != "");
    let left = { core: LOG_LINES, loki: LOG_LINES };
    let kept = [];
    for (let i = length(lines) - 1; i >= 0 && (left.core > 0 || left.loki > 0); i--)
        if (left[match(lines[i], CORE_LINE) ? "core" : "loki"]-- > 0)
            unshift(kept, lines[i]);
    return length(kept) == 0 ? "" : join("\n", kept) + "\n";
}

function chains(table) {
    return replace(table, /\tset [^\n]*\{\n(\t\t[^\n]*\n)*\t\}\n\n/g, "");
}

function server_hosts() {
    let result = [];
    for (let section in uci.section_objects(constants.LOKI_CONFIG_NAME, "server"))
        for (let key in [ "public_host", "tls_server_name" ]) {
            let host = lc(trim(common.option(section, key, "")));
            if (host != "" && match(host, /[a-z]/) != null && index(host, ":") < 0)
                push(result, host);
        }
    return result;
}

// Public resolvers stay readable: which one the router asks matters to any DNS question.
function resolver_addresses(settings) {
    let result = [];
    for (let key in [ "dns_server", "bootstrap_dns_server" ])
        for (let server in common.list_option(settings, key)) {
            let host = core_url.host(server) || server;
            if (core_ip.valid_ip(host))
                push(result, host);
        }
    return result;
}

function report(visibility, checks) {
    let masked = visibility != "raw";
    let settings = uci.get_all(constants.LOKI_CONFIG_NAME, "settings") ?? {};
    let sing_box = masked ? common.read_json_file(common.option(settings, "config_path", "")) : null;
    let hosts = masked ? sort(uniq([ ...mask.hosts(sing_box), ...server_hosts() ]), (a, b) => length(b) - length(a)) : [];
    let resolvers = resolver_addresses(settings);
    let secrets = masked ? mask.credentials([ sing_box, uci.section_objects(constants.LOKI_CONFIG_NAME) ]) : [];
    let text = (value) => masked ? mask.text(value, hosts, resolvers, secrets) : value;
    let loki = fs.readfile(paths.loki_config) ?? "";

    return {
        visibility: masked ? "masked" : "raw",
        notice: masked ? "MASKED REPORT: review before sharing." : "UNMASKED REPORT: contains keys and passwords. Do not share.",
        checks: text(checks ?? ""),
        log: text(log_tail(output([ "logread", "-e", constants.LOKI_LOG_PATTERN ]))),
        loki_config: text(masked ? mask.loki_config(loki) : loki),
        nftables: text(chains(output([ "nft", "-t", "list", "table", "inet", constants.NFT_TABLE_NAME ]))),
        ip_rules: text(output([ "ip", "-4", "rule" ]) + output([ "ip", "-6", "rule" ]))
    };
}

return { paths, report };
