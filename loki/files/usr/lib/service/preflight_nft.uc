let fs = require("fs");
let exec = require("core.exec");

const BYTE_LIMIT = 65536;
const TABLE_LIMIT = 512;
const QUERY = [ "/usr/bin/env", "-i", "PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C", "/usr/sbin/nft", "-j", "list", "tables" ];
const OWN_MARK = require("core.common").parse_number(require("core.constants").NFT_FAKEIP_MARK);
const OWN_FRAGMENT = "/usr/share/nftables.d/chain-pre/input/loki.nft";
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
    return { snapshot: compact(data), own, legacy, tables: sort(keys(seen)) };
}

function probe() {
    let result = exec.deadline(QUERY, 1, BYTE_LIMIT);
    if (result.output_limit) return { error: "nft-table-response-size-limit" };
    if (type(result.status) != "int" || result.status != 0 || result.output == "") return { error: "nft-table-query-failed" };
    return parse(result.output);
}

function identifier(value) {
    return type(value) == "string" && length(value) > 0 && length(value) <= 255 && index(value, "\u0000") < 0;
}

function verdict(value, chains, prefix) {
    if (type(value) != "object" || length(keys(value)) != 1) return false;
    let name = keys(value)[0], target = value[name];
    if (index([ "accept", "drop", "continue", "return" ], name) >= 0) return target == null;
    return index([ "jump", "goto" ], name) >= 0 && type(target) == "object" && length(keys(target)) == 1 &&
        identifier(target.target) && (chains[prefix] ?? {})[target.target] === true;
}

function own_mark_rule(entry) {
    let row = entry?.rule;
    if (type(entry) != "object" || length(keys(entry)) != 1 || type(row) != "object" ||
        row.family != "inet" || row.table != "fw4" || row.chain != "input" || row.comment != "loki: TPROXY traffic" ||
        type(row.expr) != "array" || length(row.expr) != 3 ||
        row.handle != null && (type(row.handle) != "int" || row.handle < 0)) return false;
    for (let key in keys(row)) if (index([ "family", "table", "chain", "comment", "expr", "handle" ], key) < 0) return false;
    let first = row.expr[0], counter = row.expr[1], accept = row.expr[2], match = first?.match, left = match?.left;
    if (type(first) != "object" || length(keys(first)) != 1 || type(match) != "object" || length(keys(match)) != 3 ||
        match.op != "==" || type(match.right) != "int" || match.right != OWN_MARK ||
        type(left) != "object" || length(keys(left)) != 1 || type(left["&"]) != "array" || length(left["&"]) != 2 ||
        type(left["&"][1]) != "int" || left["&"][1] != OWN_MARK) return false;
    let operand = left["&"][0];
    return type(operand) == "object" && length(keys(operand)) == 1 && type(operand.meta) == "object" &&
        length(keys(operand.meta)) == 1 && operand.meta.key == "mark" &&
        type(counter) == "object" && length(keys(counter)) == 1 && exists(counter, "counter") &&
        type(accept) == "object" && length(keys(accept)) == 1 && exists(accept, "accept") && accept.accept == null;
}

function verified_own_include(root, target, kind, own_files) {
    let own = own_files?.[target], path = (root == "/" ? "" : root) + target;
    return target == OWN_FRAGMENT && kind == "nftables" && own?.package == "loki" && own.mode == 0644 && own.type == "file" &&
        type(own.size) == "int" && own.size >= 0 && own.size <= 1048576 && type(own.sha256) == "string" && match(own.sha256, /^[a-f0-9]{64}$/) &&
        require("singbox.runtime").file_digest(path, own) == own.sha256;
}

function parse_rules(data, own_include) {
    try {
        if (type(data) != "string" || length(data) > 1048576 || index(data, "\u0000") >= 0) die("nft-rules-json-invalid");
        let value = json(data);
        if (compact(data) != compact(sprintf("%J", value)) || type(value) != "object" || length(keys(value)) != 1 ||
            type(value.nftables) != "array" || length(value.nftables) == 0 || length(value.nftables) > 8192 ||
            parse(sprintf("%J", { nftables: [ value.nftables[0] ] })).error != null) die("nft-rules-json-invalid");
        let queue = [ { value, depth: 0, own: false } ], count = 0;
        while (length(queue) > 0) {
            let item = shift(queue), node = item.value;
            if (++count > 32768 || item.depth > 32) die("nft-rules-node-limit");
            if (type(node) == "array") for (let child in node) push(queue, { value: child, depth: item.depth + 1,
                own: item.own || own_include === true && item.depth == 1 && own_mark_rule(child) });
            else if (type(node) == "object") {
                if ((node.meta?.key == "mark" || node.ct?.key == "mark") && !item.own) die("nft-mark-usage-unverified");
                for (let key in keys(node)) push(queue, { value: node[key], depth: item.depth + 1, own: item.own });
            }
        }
        let tables = {}, chains = {};
        for (let i = 1; i < length(value.nftables); i++) {
            let entry = value.nftables[i];
            if (type(entry) != "object" || length(keys(entry)) != 1) die("nft-rules-shape-invalid");
            let kind = keys(entry)[0], row = entry[kind];
            if (index([ "table", "chain", "rule", "set", "map", "element", "flowtable", "counter", "quota", "limit", "ct helper", "ct timeout", "ct expectation" ], kind) < 0 ||
                type(row) != "object" || index(FAMILIES, row.family) < 0) die("nft-rules-shape-invalid");
            if (kind == "table") {
                if (!identifier(row.name) || tables[row.family + ":" + row.name]) die("nft-rules-shape-invalid");
                tables[row.family + ":" + row.name] = true;
            }
            else {
                if (!identifier(row.table)) die("nft-rules-shape-invalid");
                if (kind == "chain") {
                    let key = row.family + ":" + row.table;
                    chains[key] ??= {};
                    if (!identifier(row.name) || chains[key][row.name] || row.policy != null && index([ "accept", "drop" ], row.policy) < 0)
                        die("nft-rules-shape-invalid");
                    chains[key][row.name] = true;
                }
            }
        }
        for (let i = 1; i < length(value.nftables); i++) {
            let entry = value.nftables[i], kind = keys(entry)[0], row = entry[kind];
            if (kind == "table") continue;
            let prefix = row.family + ":" + row.table;
            if (!tables[prefix]) die("nft-rules-shape-invalid");
            if (kind != "rule") continue;
            if (!identifier(row.chain) || !(chains[prefix] ?? {})[row.chain] || type(row.expr) != "array" || length(row.expr) > 1024)
                die("nft-rules-shape-invalid");
            for (let statement in row.expr) {
                if (type(statement) != "object" || length(keys(statement)) != 1) die("nft-rule-statement-unverified");
                let op = keys(statement)[0], body = statement[op];
                if (verdict(statement, chains, prefix)) continue;
                if (op == "match" && type(body) == "object" && length(keys(body)) == 3 && exists(body, "left") && exists(body, "right") &&
                    index([ "==", "!=", "<", ">", "<=", ">=", "in" ], body.op) >= 0) continue;
                if (op == "counter") {
                    if (body != null && type(body) != "string" && (type(body) != "object" || length(keys(body)) != 2 ||
                        type(body.packets) != "int" || body.packets < 0 || type(body.bytes) != "int" || body.bytes < 0))
                        die("nft-rule-statement-unverified");
                    if (type(body) != "string") statement.counter = null;
                    continue;
                }
                if (op == "vmap" && type(body) == "object" && length(keys(body)) == 2 && exists(body, "key") &&
                    type(body.data) == "object" && length(keys(body.data)) == 1 && type(body.data.set) == "array") {
                    for (let pair in body.data.set)
                        if (type(pair) != "array" || length(pair) != 2 || !verdict(pair[1], chains, prefix)) die("nft-rule-verdict-map-unverified");
                    continue;
                }
                if (op == "mangle" && type(body) == "object" && length(keys(body)) == 2 && type(body.key) == "object" && length(keys(body.key)) == 1 && exists(body, "value")) {
                    let target = body.key;
                    if (type(target.payload) == "object" && length(keys(target.payload)) == 2 &&
                        index([ "ip", "ip6" ], target.payload.protocol) >= 0 && target.payload.field == "dscp") continue;
                    if (type(target["tcp option"]) == "object" && length(keys(target["tcp option"])) == 2 &&
                        target["tcp option"].name == "maxseg" && target["tcp option"].field == "size") continue;
                }
                // shortcut: other packet mutations and unfamiliar statements require an explicit compatibility check.
                if (index([ "reject", "masquerade", "log" ], op) >= 0 && (body == null || type(body) == "object")) continue;
                if (index([ "limit", "ct helper" ], op) >= 0 && (type(body) == "object" || identifier(body))) continue;
                die("nft-rule-statement-unverified");
            }
        }
        return { snapshot: sprintf("%J", value), tables: sort(keys(tables)) };
    }
    catch (e) { return { error: type(e.message) == "string" && match(e.message, /^nft-[a-z-]+$/) ? e.message : "nft-rules-json-invalid" }; }
}

function rules_probe(own_include) {
    let result = exec.deadline([ "/usr/bin/env", "-i", "PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C", "/usr/sbin/nft", "-s", "-j", "list", "ruleset" ], 2, 1048576);
    if (result.output_limit) return { error: "nft-rules-response-size-limit" };
    if (type(result.status) != "int" || result.status != 0 || result.output == "") return { error: "nft-rules-query-failed" };
    return parse_rules(result.output, own_include);
}

function collect(scope, root, own_files) {
    root = root || "/";
    let own_include = verified_own_include(root, OWN_FRAGMENT, "nftables", own_files);
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
    let reason = "nft-rules-and-namespace-unverified";
    if (first.error == null && error == null && scope?.error == null && type(scope?.identities) == "object") {
        let rules = rules_probe(own_include), again = rules.error == null ? rules_probe(own_include) : rules;
        reason = again.error ?? (rules.snapshot != again.snapshot ? "nft-rules-changed-during-read" :
            sprintf("%J", first.tables) != sprintf("%J", again.tables) ? "nft-table-list-changed-during-read" : "nft-compatible-rules-checked");
        if (own_include && !verified_own_include(root, OWN_FRAGMENT, "nftables", own_files)) reason = "nft-own-include-changed-during-read";
    }
    push(result, { kind: "nft-loaded", object: "rules-and-namespace", state: reason == "nft-compatible-rules-checked" ? "checked" : "incomplete", reason });
    return result;
}

function include_plan(sections) {
    if (type(sections) != "array" || length(sections) > 1024) die("nft-persisted-config-unverified");
    let defaults = filter(sections, (section) => section[".type"] == "defaults");
    if (length(defaults) > 1) die("nft-persisted-config-unverified");
    let boolean = (value, fallback) => {
        if (value == null) return fallback;
        if (type(value) != "string") die("nft-persisted-config-unverified");
        if (index([ "1", "on", "true", "yes" ], value) >= 0) return true;
        if (index([ "0", "off", "false", "no" ], value) >= 0) return false;
        die("nft-persisted-config-unverified");
    };
    let paths = {}, directories = [ "/etc/nftables.d" ];
    if (boolean(defaults[0]?.auto_includes, true))
        for (let position in [ "ruleset-pre", "ruleset-post", "table-pre", "table-post", "chain-pre", "chain-post" ])
            push(directories, "/usr/share/nftables.d/" + position);
    for (let section in sections) {
        if (section[".type"] != "include" || !boolean(section.enabled, true)) continue;
        let kind = section.type ?? "script";
        if (index([ "script", "nftables" ], kind) < 0) die("nft-persisted-config-unverified");
        if (kind == "script" && !boolean(section.fw4_compatible, section.path != "/etc/firewall.user")) continue;
        let path = section.path;
        if (type(path) != "string" || !match(path, /^\/[A-Za-z0-9_.+@\/-]+$/) ||
            index(path, "//") >= 0 || match(path, /\/(\.\.?)(\/|$)/) || substr(path, -1) == "/")
            die("nft-persisted-config-unverified");
        // A path used as both shell and nft text must remain inert under both interpreters.
        paths[path] = paths[path] != null && paths[path] != kind ? "both" : kind;
    }
    return { paths, directories };
}

function persisted_snapshot(root, plan, budget, own_files) {
    let files = require("service.preflight_files"), paths = { ...plan.paths }, nodes = [];
    let prefix = root == "/" ? "" : root, queue = [ ...plan.directories ];
    while (length(queue) > 0) {
        let target = shift(queue), path = prefix + target;
        let safe = files.collect(root, { [target]: "directory" })[0];
        if (safe.reason == "candidate-path-absent") { push(nodes, [ target, null ]); continue; }
        if (safe.reason != "candidate-directory-safe") die("nft-persisted-directory-unverified");
        let before = fs.lstat(path), directory = fs.opendir(path), failed = false;
        if (directory == null) die("nft-persisted-directory-unverified");
        try {
            while (true) {
                fs.error(); let name = directory.read(), error = fs.error();
                if (name == null) { if (error != null) failed = true; break; }
                if (++budget.entries > 4096) die("nft-persisted-entry-limit");
                if (name == "." || name == "..") continue;
                if (type(name) != "string" || name == "" || length(name) > 255 || index(name, "/") >= 0 || index(name, "\u0000") >= 0)
                    die("nft-persisted-directory-unverified");
                let relative = target + "/" + name;
                if (target == "/usr/share/nftables.d/chain-pre" || target == "/usr/share/nftables.d/chain-post") {
                    let node = fs.lstat(prefix + relative);
                    if (node == null) die("nft-persisted-directory-unverified");
                    if (node.type != "file") push(queue, relative);
                }
                else if (substr(name, 0, 1) != "." && substr(name, -4) == ".nft")
                    paths[relative] = index([ "script", "both" ], paths[relative]) >= 0 ? "both" : "nftables";
            }
        }
        catch (e) { failed = true; }
        try { if (directory.close() !== true) failed = true; }
        catch (e) { failed = true; }
        if (failed || !files.same_node(before, fs.lstat(path))) die("nft-persisted-directory-unverified");
        delete before.atime; push(nodes, [ target, before ]);
    }
    for (let target in sort(keys(paths))) {
        if (++budget.files > 128) die("nft-persisted-file-limit");
        let safe = files.collect(root, { [target]: "file" })[0];
        if (safe.reason == "candidate-path-absent") { push(nodes, [ target, null ]); continue; }
        if (safe.reason != "candidate-existing-file-origin-unverified") die("nft-persisted-file-unverified");
        let before = fs.lstat(prefix + target);
        let read = require("service.preflight").read_metadata(prefix + target, 1048576, root);
        if (read.error != null || (budget.bytes += read.bytes) > 2097152) die("nft-persisted-file-unverified");
        let verified = verified_own_include(root, target, paths[target], own_files);
        if (!files.same_node(before, fs.lstat(prefix + target))) die("nft-persisted-changed-during-read");
        if (verified) budget.owned = true;
        // shortcut: other active includes require an explicit compatibility check.
        for (let line in verified ? [] : split(read.data, "\n")) {
            line = trim(line);
            if (line != "" && substr(line, 0, 1) != "#" &&
                !(paths[target] == "script" && match(line, /^(exit|return)[ \t]+0$/)))
                die("nft-persisted-active-include-unverified");
        }
        let node = fs.lstat(prefix + target); if (node != null) delete node.atime;
        push(nodes, [ target, node, read.data ]);
    }
    nodes = sort(nodes, (a, b) => a[0] < b[0] ? -1 : a[0] == b[0] ? 0 : 1);
    return sprintf("%J", nodes);
}

function persisted(root, sections, own_files) {
    let result = { kind: "nft-persisted", object: "firewall-includes", state: "incomplete", reason: "nft-persisted-config-unverified" };
    try {
        let plan = include_plan(sections), budget = { entries: 0, files: 0, bytes: 0 };
        let first = persisted_snapshot(root, plan, budget, own_files), second = persisted_snapshot(root, plan, budget, own_files);
        if (first != second) die("nft-persisted-changed-during-read");
        result.state = "checked"; result.reason = budget.owned ? "nft-persisted-own-and-inert-includes-checked" : "nft-persisted-inert-includes-checked";
    }
    catch (e) {
        if (type(e.message) == "string" && match(e.message, /^nft-persisted-[a-z-]+$/)) result.reason = e.message;
    }
    return result;
}

return { collect, parse, persisted, parse_rules };
