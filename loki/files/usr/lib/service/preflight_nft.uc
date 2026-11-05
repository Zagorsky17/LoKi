let fs = require("fs");

const BYTE_LIMIT = 65536;
const TABLE_LIMIT = 512;
const QUERY = "exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C timeout -s KILL 1 /usr/sbin/nft -j list tables 2>/dev/null";
const FAMILIES = [ "ip", "ip6", "inet", "arp", "bridge", "netdev" ];

function compact(data) {
    return replace(data, /"([^"\\]|\\.)*"|[ \t\r\n]+/g,
        (token) => substr(token, 0, 1) == '"' ? token : "");
}

function parse(data) {
    if (type(data) != "string" || length(data) > BYTE_LIMIT || index(data, "\u0000") >= 0)
        return { error: "nft-table-json-invalid" };
    let value;
    try {
        value = json(data);
        if (compact(data) != compact(sprintf("%J", value)))
            return { error: "nft-table-json-invalid" };
    }
    catch (e) { return { error: "nft-table-json-invalid" }; }
    if (type(value) != "object" || length(keys(value)) != 1 || type(value.nftables) != "array" ||
        length(value.nftables) < 1 || length(value.nftables) > TABLE_LIMIT + 1)
        return { error: "nft-table-shape-invalid" };
    let header = value.nftables[0];
    if (type(header) != "object" || length(keys(header)) != 1 ||
        type(header.metainfo) != "object" || type(header.metainfo.json_schema_version) != "int" ||
        header.metainfo.json_schema_version != 1)
        return { error: "nft-table-schema-unverified" };
    let seen = {};
    let own = false;
    let legacy = false;
    for (let i = 1; i < length(value.nftables); i++) {
        let row = value.nftables[i];
        if (type(row) != "object" || length(keys(row)) != 1 || type(row.table) != "object")
            return { error: "nft-table-shape-invalid" };
        let table = row.table;
        if (type(table.family) != "string" || index(FAMILIES, table.family) < 0 ||
            type(table.name) != "string" || length(table.name) < 1 || length(table.name) > 128 ||
            index(table.name, "\u0000") >= 0)
            return { error: "nft-table-shape-invalid" };
        let key = table.family + ":" + table.name;
        if (exists(seen, key)) return { error: "nft-table-duplicate" };
        seen[key] = true;
        own = own || (table.family == "inet" && table.name == "loki");
        legacy = legacy || table.name == "forkop" || table.name == "podkop";
    }
    return { snapshot: compact(data), own, legacy };
}

function probe() {
    let pipe;
    try { pipe = fs.popen(QUERY, "r"); }
    catch (e) { return { error: "nft-table-query-failed" }; }
    if (pipe == null) return { error: "nft-table-query-failed" };
    let data;
    let status;
    let failed = false;
    try { data = pipe.read(BYTE_LIMIT + 1); }
    catch (e) { failed = true; }
    try { status = pipe.close(); }
    catch (e) { failed = true; }
    if (type(data) == "string" && length(data) > BYTE_LIMIT)
        return { error: "nft-table-response-size-limit" };
    if (failed || type(status) != "int" || status != 0 || type(data) != "string")
        return { error: "nft-table-query-failed" };
    return parse(data);
}

function collect() {
    let result = [];
    let first = probe();
    let second = first.error == null ? probe() : first;
    let error = second.error;
    if (error == null && first.snapshot != second.snapshot)
        error = "nft-table-list-changed-during-read";
    if (error != null)
        push(result, { kind: "nft-loaded", object: "table-list", state: "incomplete", reason: error });
    else {
        push(result, { kind: "nft-loaded", object: "table-list", state: "checked", reason: "nft-table-list-read-complete" });
        if (second.own)
            push(result, { kind: "nft-loaded", object: "loki-table", state: "incomplete", reason: "candidate-nft-table-origin-unverified" });
        if (second.legacy)
            push(result, { kind: "nft-loaded", object: "legacy-table", state: "incomplete", reason: "legacy-nft-table-content-unverified" });
    }
    push(result, { kind: "nft-loaded", object: "rules-and-namespace", state: "incomplete", reason: "nft-rules-and-namespace-unverified" });
    return result;
}

return { collect, parse };
