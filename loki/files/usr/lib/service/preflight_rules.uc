let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");

const BYTE_LIMIT = 262144;
const RULE_LIMIT = 2048;
const QUERY = "exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -s KILL 2 /sbin/ip -Numeric -j ";
const FIELDS = [ "priority", "src", "table", "protocol", "fwmark", "fwmask", "iif", "oif" ];

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
            if (exists(row, key) && (type(row[key]) != "string" || !match(row[key], /^[!-~]{1,15}$/) ||
                row[key] == "." || row[key] == ".." || index(row[key], "/") >= 0 || index(row[key], ":") >= 0))
                return { error: "policy-rule-shape-invalid" };
        let mark = null;
        let mask = null;
        if (exists(row, "fwmark")) {
            mark = number(row.fwmark, 4294967295, true);
            mask = exists(row, "fwmask") ? number(row.fwmask, 4294967295, true) : 4294967295;
            if (mark == null || mask == null) return { error: "policy-rule-shape-invalid" };
        }
        else if (exists(row, "fwmask")) return { error: "policy-rule-shape-invalid" };
        push(rules, { priority: row.priority, table, mark, mask });
    }
    return { rules, snapshot };
}

function probe(family) {
    let pipe;
    try { pipe = fs.popen(QUERY + family + " rule list 2>/dev/null", "r"); }
    catch (e) { return { error: "policy-rule-query-failed" }; }
    if (pipe == null) return { error: "policy-rule-query-failed" };
    let data;
    let status;
    let failed = false;
    try { data = pipe.read(BYTE_LIMIT + 1); }
    catch (e) { failed = true; }
    try { status = pipe.close(); }
    catch (e) { failed = true; }
    if (type(data) == "string" && length(data) > BYTE_LIMIT) return { error: "policy-rule-response-size-limit" };
    if (failed || type(status) != "int" || status != 0 || type(data) != "string")
        return { error: "policy-rule-query-failed" };
    return parse(data);
}

function collect() {
    let result = [];
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
        if (error != null) { add(label, "incomplete", error); continue; }
        let hints = {};
        for (let rule in second.rules) {
            // These numeric ids are fixed by nft/apply, not by rt_tables aliases.
            if (rule.table == 105) hints["candidate-table"] = true;
            if (rule.priority >= 104 && rule.priority <= 106) hints["candidate-priority"] = true;
            if (rule.mark == null) continue;
            for (let role in keys(marks)) {
                if ((rule.mask & marks[role]) != 0) hints[role + "-mask-bits"] = true;
                if (overlaps(rule.mark, rule.mask, marks[role], marks[role])) hints[role + "-match-space"] = true;
            }
        }
        for (let hint in sort(keys(hints))) add(label + "-" + hint, "incomplete", "policy-rule-candidate-overlap-unverified");
        add(label, "checked", "policy-rule-snapshot-read-complete");
    }
    add("ownership", "incomplete", "policy-rules-ownership-configuration-unverified");
    add("coverage", "incomplete", "policy-routes-and-namespace-unverified");
    return result;
}

return { collect, parse, overlaps };
