// Other programs intercepting what Loki intercepts, read from the loaded nft rule set: a
// transparent proxy of their own, or a DNS redirect hooked before Loki's.

let constants = require("core.constants");

// The priorities nft prints by name for the inet, ip and ip6 families.
const NAMED_PRIORITIES = { raw: -300, mangle: -150, dstnat: -100, filter: 0, security: 50, srcnat: 100 };

// Blocks a table holds besides its chains, whose lines are no rules.
const OTHER_BLOCK = /^[ \t]*(set|map|flowtable|counter|quota|limit|secmark|synproxy|ct[ \t]+[a-z]+)[ \t]+[^ \t]+[ \t]*\{/;

function priority_value(text) {
    text = trim(text);
    let named = match(text, /^([a-z]+)[ \t]*(([+-])[ \t]*([0-9]+))?$/);
    if (named != null) {
        let base = NAMED_PRIORITIES[named[1]];
        if (base == null)
            return null;
        return named[2] == null ? base : named[3] == "+" ? base + int(named[4]) : base - int(named[4]);
    }
    return match(text, /^-?[0-9]+$/) != null ? int(text) : null;
}

function parse(listing) {
    let tables = [];
    let table = null;
    let chain = null;
    for (let line in split(listing ?? "", "\n")) {
        let opened = match(line, /^table[ \t]+([a-z0-9]+)[ \t]+([^ \t{]+)/);
        if (opened != null) {
            table = { family: opened[1], name: opened[2], chains: {} };
            push(tables, table);
            chain = null;
            continue;
        }
        if (table == null)
            continue;
        let named = match(line, /^[ \t]*chain[ \t]+([^ \t{]+)/);
        if (named != null) {
            chain = { hook: null, priority: null, rules: [] };
            table.chains[named[1]] = chain;
            continue;
        }
        if (match(line, OTHER_BLOCK) != null) {
            chain = null;
            continue;
        }
        if (chain == null)
            continue;
        let base = match(line, /^[ \t]*type[ \t]+[a-z]+[ \t]+hook[ \t]+([a-z]+).*priority[ \t]+([^;]+);/);
        if (base != null) {
            chain.hook = base[1];
            chain.priority = priority_value(base[2]);
            continue;
        }
        line = trim(line);
        if (line != "" && line != "}")
            push(chain.rules, line);
    }
    return tables;
}

function reached_rules(table) {
    let result = [];
    for (let name, chain in table.chains) {
        if (chain.hook == null)
            continue;
        let pending = [ name ];
        let seen = {};
        while (length(pending) > 0) {
            let current = pop(pending);
            if (seen[current] || table.chains[current] == null)
                continue;
            seen[current] = true;
            for (let rule in table.chains[current].rules) {
                push(result, { hook: chain.hook, priority: chain.priority, rule });
                for (let target in match(rule, /(jump|goto)[ \t]+([^ \t;]+)/g) ?? [])
                    push(pending, target[2]);
            }
        }
    }
    return result;
}

function port_listed(value, port) {
    for (let token in split(replace(value, /[{}]/g, ""), /[, \t]+/)) {
        let range = match(token, /^([0-9]+)-([0-9]+)$/);
        if (token == "" + port || (range != null && int(range[1]) <= port && port <= int(range[2])))
            return true;
    }
    return false;
}

function redirects_dns(rule) {
    let ports = match(rule, /dport[ \t]+(\{[^}]*\}|[0-9-]+)/);
    return ports != null && port_listed(ports[1], 53) && match(rule, /(^|[ \t])(redirect|dnat)([ \t]|$)/) != null;
}

// Of two nat chains at one priority the one loaded last runs first, so a redirect at Loki's
// priority wins whenever its table is loaded after Loki's.
function dns_redirect_first(entry) {
    if (entry.priority == null)
        return false;
    if (entry.hook == "prerouting")
        return entry.priority <= constants.NFT_DNS_REDIRECT_PRIORITY;
    if (entry.hook == "output")
        return entry.priority <= constants.NFT_SYSTEM_DNS_REDIRECT_PRIORITY;
    return false;
}

// [ { table, kind } ]: kind "tproxy" for a transparent proxy, "dns" for a DNS
// redirect that runs before Loki's. One entry per table and kind.
function find(listing) {
    let result = [];
    for (let table in parse(listing)) {
        if (table.name == constants.NFT_TABLE_NAME)
            continue;
        let kinds = {};
        for (let entry in reached_rules(table)) {
            if (match(entry.rule, /(^|[ \t])tproxy[ \t]/) != null)
                kinds.tproxy = true;
            if (table.family != "bridge" && redirects_dns(entry.rule) && dns_redirect_first(entry))
                kinds.dns = true;
        }
        for (let kind in [ "tproxy", "dns" ])
            if (kinds[kind])
                push(result, { table: table.family + " " + table.name, kind });
    }
    return result;
}

return { priority_value, parse, find };
