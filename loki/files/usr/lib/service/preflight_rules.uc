let fs = require("fs");
let exec = require("core.exec");
let common = require("core.common");
let constants = require("core.constants");
let ip = require("core.ip");

const BYTE_LIMIT = 262144;
const RULE_LIMIT = 2048;
const ROUTE_LIMIT = 2048;
const QUERY = [ "/usr/bin/env", "-i", "PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C", "/sbin/ip", "-Numeric", "-j" ];
const FIELDS = [ "priority", "src", "table", "protocol", "fwmark", "fwmask", "iif", "oif" ];
const ROUTE_FIELDS = [ "dst", "type", "table", "gateway", "dev", "protocol", "scope", "prefsrc", "metric", "flags", "pref" ];

function compact(data) {
    return replace(data, /"([^"\\]|\\.)*"|[ \t\r\n]+/g,
        (token) => substr(token, 0, 1) == '"' ? token : "");
}

function number(value, maximum, allow_hex) {
    if (type(value) != "string" || !match(value, /^(0|[1-9][0-9]{0,9}|0x[0-9A-Fa-f]{1,8})$/) ||
        (!allow_hex && substr(value, 0, 2) == "0x")) return null;
    let result = common.parse_number(value);
    return result != null && result >= 0 && result <= maximum ? result : null;
}

function overlaps(first, first_mask, second, second_mask) {
    return ((first ^ second) & first_mask & second_mask) == 0;
}

function valid_interface_name(value) {
    return type(value) == "string" && index(value, "\u0000") < 0 && match(value, /^[!-~]{1,15}$/) != null &&
        value != "." && value != ".." && index(value, "/") < 0 && index(value, ":") < 0;
}

function parse(data) {
    if (type(data) != "string" || length(data) > BYTE_LIMIT || index(data, "\u0000") >= 0)
        return { error: "policy-rule-json-invalid" };
    let value;
    let snapshot;
    try {
        value = json(data);
        snapshot = compact(data);
        // Keep quoted contents intact; duplicate keys and alternate encodings cannot disappear.
        if (snapshot != compact(sprintf("%J", value))) return { error: "policy-rule-json-invalid" };
    }
    catch (e) { return { error: "policy-rule-json-invalid" }; }
    if (type(value) != "array") return { error: "policy-rule-shape-invalid" };
    if (length(value) > RULE_LIMIT) return { error: "policy-rule-count-limit" };
    let rules = [];
    for (let row in value) {
        if (type(row) != "object") return { error: "policy-rule-shape-invalid" };
        for (let key in keys(row))
            if (index(FIELDS, key) < 0) return { error: "policy-rule-selector-or-action-unverified" };
        let table = number(row.table, 4294967295, false);
        if (type(row.priority) != "int" || row.priority < 0 || row.priority > 4294967295 ||
            table == null || table == 0 || type(row.src) != "string")
            return { error: "policy-rule-shape-invalid" };
        if (row.src != "all") return { error: "policy-rule-selector-or-action-unverified" };
        if (exists(row, "protocol") && number(row.protocol, 255, false) == null)
            return { error: "policy-rule-shape-invalid" };
        for (let key in [ "iif", "oif" ])
            if (exists(row, key) && !valid_interface_name(row[key]))
                return { error: "policy-rule-shape-invalid" };
        let mark = null;
        let mask = null;
        if (exists(row, "fwmark")) {
            mark = number(row.fwmark, 4294967295, true);
            mask = exists(row, "fwmask") ? number(row.fwmask, 4294967295, true) : 4294967295;
            if (mark == null || mask == null) return { error: "policy-rule-shape-invalid" };
        }
        else if (exists(row, "fwmask")) return { error: "policy-rule-shape-invalid" };
        let rule = { priority: row.priority, table, mark, mask };
        for (let key in [ "iif", "oif" ])
            if (exists(row, key)) rule[key] = row[key];
        push(rules, rule);
    }
    return { rules, snapshot };
}

function parse_routes(data, family) {
    if (type(family) != "int" || (family != 4 && family != 6)) return { error: "policy-route-family-invalid" };
    if (type(data) != "string" || length(data) > BYTE_LIMIT || index(data, "\u0000") >= 0)
        return { error: "policy-route-json-invalid" };
    let value;
    let snapshot;
    try {
        value = json(data);
        snapshot = compact(data);
        if (snapshot != compact(sprintf("%J", value))) return { error: "policy-route-json-invalid" };
    }
    catch (e) { return { error: "policy-route-json-invalid" }; }
    if (type(value) != "array") return { error: "policy-route-shape-invalid" };
    if (length(value) > ROUTE_LIMIT) return { error: "policy-route-count-limit" };
    let routes = [];
    for (let row in value) {
        if (type(row) != "object") return { error: "policy-route-shape-invalid" };
        for (let key in keys(row))
            if (index(ROUTE_FIELDS, key) < 0) return { error: "policy-route-selector-or-action-unverified" };
        // ip omits the main table and unicast type even with numeric output.
        let table = exists(row, "table") ? number(row.table, 4294967295, false) : 254;
        let route_type = exists(row, "type") ? number(row.type, 255, false) : 1;
        if (table == null || table == 0 || route_type == null || route_type == 0 || type(row.dst) != "string" ||
            (row.dst != "default" && ip.ip_family(row.dst) != family))
            return { error: "policy-route-shape-invalid" };
        if (route_type > 9) return { error: "policy-route-selector-or-action-unverified" };
        for (let name in [ "protocol", "scope" ])
            if (exists(row, name) && number(row[name], 255, false) == null)
                return { error: "policy-route-shape-invalid" };
        for (let name in [ "gateway", "prefsrc" ])
            if (exists(row, name) && (!ip.valid_ip(row[name]) || ip.ip_family(row[name]) != family))
                return { error: "policy-route-shape-invalid" };
        if (exists(row, "dev") && !valid_interface_name(row.dev))
            return { error: "policy-route-shape-invalid" };
        if (exists(row, "metric") && (type(row.metric) != "int" || row.metric < 0 || row.metric > 4294967295))
            return { error: "policy-route-shape-invalid" };
        if (exists(row, "pref") && (type(row.pref) != "string" || index([ "low", "medium", "high" ], row.pref) < 0))
            return { error: "policy-route-shape-invalid" };
        let flags = exists(row, "flags") ? row.flags : [];
        if (type(flags) != "array" || length(flags) > 8) return { error: "policy-route-shape-invalid" };
        let seen = {};
        for (let flag in flags) {
            if (type(flag) != "string" || exists(seen, flag)) return { error: "policy-route-shape-invalid" };
            if (index([ "linkdown", "onlink", "pervasive", "dead", "offload", "trap", "notify" ], flag) < 0)
                return { error: "policy-route-selector-or-action-unverified" };
            seen[flag] = true;
        }
        push(routes, { table, type: route_type, dst: row.dst, dev: row.dev });
    }
    return { routes, snapshot };
}

function probe(family, for_routes) {
    let reason = for_routes ? "policy-route" : "policy-rule";
    let result = exec.deadline([ ...QUERY, family, ...(for_routes ? [ "route", "show", "table", "all" ] : [ "rule", "list" ]) ], 2, BYTE_LIMIT);
    if (result.output_limit) return { error: reason + "-response-size-limit" };
    if (type(result.status) != "int" || result.status != 0 || result.output == "") return { error: reason + "-query-failed" };
    return for_routes ? parse_routes(result.output, family == "-4" ? 4 : 6) : parse(result.output);
}

function route_namespace() {
    let process;
    let init;
    try {
        process = fs.readlink("/proc/self/ns/net");
        init = fs.readlink("/proc/1/ns/net");
    }
    catch (e) { return { error: "policy-route-namespace-unavailable" }; }
    for (let value in [ process, init ])
        if (type(value) != "string" || index(value, "\u0000") >= 0 || !match(value, /^net:\[[1-9][0-9]{0,19}\]$/))
            return { error: "policy-route-namespace-unavailable" };
    return { process, init };
}

function namespace_error(first, second) {
    let error = first.error ?? second.error;
    if (error == null && (first.process != second.process || first.init != second.init))
        error = "policy-route-namespace-changed-during-read";
    if (error == null && first.process != first.init) error = "policy-route-noninitial-network-namespace";
    return error;
}

function collect() {
    let result = [];
    let first_namespace = route_namespace();
    let coverage = [], complete = true;
    let add = (object, state, reason) => push(result, { kind: "policy-rules", object, state, reason });
    let marks = { fakeip: common.parse_number(constants.NFT_FAKEIP_MARK),
        outbound: common.parse_number(constants.NFT_OUTBOUND_MARK), router: common.parse_number(constants.NFT_ROUTER_MARK) };
    for (let family in [ "-4", "-6" ]) {
        let label = family == "-4" ? "ipv4" : "ipv6";
        let first = probe(family);
        let second = first.error == null ? probe(family) : first;
        let error = second.error;
        // Equal priorities are valid; changing their order can change the routing result.
        if (error == null && first.snapshot != second.snapshot) error = "policy-rules-changed-during-read";
        if (error != null) {
            add(label, "incomplete", error);
            push(coverage, { kind: label + "-routes-rules", object: "policy-rules", state: "incomplete", reason: error });
            complete = false;
            continue;
        }
        let hints = {};
        for (let rule in second.rules) {
            if (!(rule.mark == null && rule.iif == null && rule.oif == null &&
                (rule.priority == 0 && rule.table == 255 || rule.priority == 32766 && rule.table == 254 ||
                 rule.priority == 32767 && rule.table == 253))) hints["selection"] = true;
            // These numeric ids are fixed by nft/apply, not by rt_tables aliases.
            if (rule.table == 105) hints["candidate-table"] = true;
            if (rule.priority >= 104 && rule.priority <= 106) hints["candidate-priority"] = true;
            if (rule.mark == null) continue;
            for (let role in keys(marks)) {
                if ((rule.mask & marks[role]) != 0) hints[role + "-mask-bits"] = true;
                if (overlaps(rule.mark, rule.mask, marks[role], marks[role])) hints[role + "-match-space"] = true;
            }
        }
        for (let hint in sort(keys(hints))) add(label + "-" + hint, "incomplete",
            hint == "selection" ? "policy-rule-selection-unverified" : "policy-rule-candidate-overlap-unverified");
        let clear = length(keys(hints)) == 0;
        complete = complete && clear;
        push(coverage, { kind: label + "-routes-rules", object: "policy-rules", state: clear ? "checked" : "incomplete",
            reason: clear ? "policy-rule-candidate-namespace-clear" : "policy-rules-ownership-configuration-unverified" });
        add(label, "checked", "policy-rule-snapshot-read-complete");
    }
    let error = namespace_error(first_namespace, route_namespace());
    for (let item in coverage) {
        if (error != null && item.state == "checked") { item.state = "incomplete"; item.reason = error; }
        push(result, item);
    }
    complete = complete && error == null;
    add("ownership", complete ? "checked" : "incomplete",
        complete ? "policy-rule-candidate-namespace-clear" : "policy-rules-ownership-configuration-unverified");
    add("coverage", complete ? "checked" : "incomplete",
        complete ? "policy-rules-and-namespace-checked" : "policy-routes-and-namespace-unverified");
    return result;
}

function collect_routes() {
    let result = [];
    let coverage = [], complete = true;
    let add = (object, state, reason) => push(result, { kind: "policy-routes", object, state, reason });
    let first_namespace = route_namespace();
    for (let family in [ "-4", "-6" ]) {
        let label = family == "-4" ? "ipv4" : "ipv6";
        let first = probe(family, true);
        let second = first.error == null ? probe(family, true) : first;
        let error = second.error;
        if (error == null && first.snapshot != second.snapshot) error = "policy-routes-changed-during-read";
        if (error != null) {
            add(label, "incomplete", error);
            push(coverage, { kind: label + "-routes-rules", object: "policy-routes", state: "incomplete", reason: error });
            complete = false;
            continue;
        }
        let reserved = length(filter(second.routes, (route) => route.table == 105)) > 0;
        if (reserved)
            add(label + "-candidate-table", "incomplete", "policy-route-candidate-table-unverified");
        let fakeip = family == "-4" ? require("singbox.constants").FAKEIP_INET4_RANGE : require("singbox.constants").FAKEIP_INET6_RANGE;
        let overlap = false, unusual_default = false;
        for (let route in second.routes) {
            if (index([ 253, 254, 255 ], route.table) < 0) continue;
            let default_route = route.dst == "default" || match(route.dst, /\/0$/) != null;
            if (default_route) { unusual_default = unusual_default || route.type != 1; continue; }
            let subnet = index(route.dst, "/") >= 0 ? route.dst : route.dst + (family == "-4" ? "/32" : "/128");
            if (ip.prefix_contains(subnet, split(fakeip, "/")[0]) || ip.prefix_contains(fakeip, split(subnet, "/")[0]))
                overlap = true;
        }
        if (overlap) add(label + "-fakeip-range", "conflict", "policy-route-fakeip-range-overlap");
        if (unusual_default) add(label + "-default", "incomplete", "policy-route-default-type-unverified");
        let clear = !reserved && !overlap && !unusual_default;
        complete = complete && clear;
        push(coverage, { kind: label + "-routes-rules", object: "policy-routes",
            state: overlap ? "conflict" : clear ? "checked" : "incomplete",
            reason: overlap ? "policy-route-fakeip-range-overlap" : clear ? "policy-route-candidate-namespace-clear" : "policy-routes-ownership-configuration-unverified" });
        add(label, "checked", "policy-route-snapshot-read-complete");
    }
    let second_namespace = route_namespace();
    let error = namespace_error(first_namespace, second_namespace);
    for (let item in coverage) {
        if (error != null && item.state == "checked") { item.state = "incomplete"; item.reason = error; }
        push(result, item);
    }
    add("network-namespace", error == null ? "checked" : "incomplete", error ?? "policy-route-network-namespace-checked");
    complete = complete && error == null;
    add("ownership", complete ? "checked" : "incomplete",
        complete ? "policy-route-candidate-namespace-clear" : "policy-routes-ownership-configuration-unverified");
    return result;
}

return { collect, parse, overlaps, collect_routes, parse_routes };
