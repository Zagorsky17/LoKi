let fs = require("fs");
let common = require("core.common");
let files = require("service.preflight_files");
let ip = require("core.ip");
let nft_sections = require("nft.sections");
let core = require("singbox.constants");
let credential = require("service.gateway_secret");

const BYTE_LIMIT = 4194304;
const TOKEN_LIMIT = 262144;
const DEPTH_LIMIT = 8;
const ENTRY_LIMIT = 4096;
const SET_KEYS = [ "subnets", "subnets6", "ip_ports", "ip6_ports", "proto_ports", "proto6_ports" ];
let paths = { base: "/tmp/loki-runtime" };

function error(reason) { return { error: "ruleset-context-" + reason }; }
function directory() { return paths.base + "/rulesets"; }
function filename() { return directory() + "/context.json"; }
function descriptor(file) { return "/proc/self/fd/" + file.fileno(); }
function close_file(file) {
    try { return file.close() === true; }
    catch (e) { return false; }
}

function only(value, required, optional) {
    if (type(value) != "object") return false;
    for (let key in required) if (!exists(value, key)) return false;
    for (let key in keys(value))
        if (index(required, key) < 0 && index(optional ?? [], key) < 0) return false;
    return true;
}

function text(value, maximum, budget, pattern) {
    if (type(value) != "string" || length(value) > maximum || index(value, "\u0000") >= 0) return false;
    budget.bytes += length(value);
    budget.tokens++;
    return budget.bytes <= BYTE_LIMIT && budget.tokens <= TOKEN_LIMIT &&
        (pattern == null || match(value, pattern) != null);
}

function hex(value, budget) {
    return text(value, 64, budget, /^[a-f0-9]{64}$/);
}

function ports(value) {
    if (value == "") return true;
    for (let range in split(value, ",")) {
        let ends = split(range, "-");
        if (length(ends) < 1 || length(ends) > 2) return false;
        for (let end in ends)
            if (!match(end, /^(0|[1-9][0-9]{0,4})$/) || common.parse_number(end) > 65535) return false;
        if (length(ends) == 2 && common.parse_number(ends[0]) > common.parse_number(ends[1])) return false;
    }
    return true;
}

function valid_context(value, ready, budget) {
    if (!only(value, [ "generation", "sections", "controller", "config_path", "config_digest", "nft_digest" ],
        ready ? [ "pid", "start_ticks", "command" ] : [])) return false;
    if (!hex(value.generation, budget) || value.generation == sprintf("%064d", 0) ||
        !hex(value.config_digest, budget) || !hex(value.nft_digest, budget) ||
        !text(value.config_path, 4096, budget, /^\/[ -~]+$/) ||
        !only(value.controller, [ "endpoint", "secret" ]) ||
        value.controller.endpoint != core.CLASH_API_CONTROLLER_SOCKET ||
        !hex(value.controller.secret, budget) || value.controller.secret == sprintf("%064d", 0) ||
        type(value.sections) != "array" || length(value.sections) > 16384) return false;
    let seen = {};
    for (let entry in value.sections) {
        if (!only(entry, [ "section", "matchers" ]) || !only(entry.section, [ ".name" ]) ||
            !text(entry.section[".name"], 232, budget, /^[A-Za-z0-9_]{1,232}$/) ||
            exists(seen, entry.section[".name"])) return false;
        seen[entry.section[".name"]] = true;
        let m = entry.matchers;
        if (!only(m, [ "subnets", "ports", "subnet_tags", "sets" ]) ||
            !text(m.subnets, 262144, budget) || !text(m.ports, 262144, budget) || !ports(m.ports) ||
            type(m.subnet_tags) != "array" || length(m.subnet_tags) == 0 ||
            length(m.subnet_tags) > TOKEN_LIMIT || !only(m.sets, SET_KEYS)) return false;
        if (m.subnets != "")
            for (let subnet in split(m.subnets, ",")) if (ip.ip_family(subnet) == 0) return false;
        let expected = nft_sections.set_names(entry.section);
        for (let key in SET_KEYS)
            if (!text(m.sets[key], 255, budget) || m.sets[key] != expected[key]) return false;
        let tags = {};
        for (let tag in m.subnet_tags) {
            if (!text(tag, 512, budget, /^[A-Za-z0-9_.-]+$/) || exists(tags, tag)) return false;
            tags[tag] = true;
        }
    }
    if (!ready) return true;
    if (!text(value.pid, 10, budget, /^[1-9][0-9]{0,9}$/) || common.parse_number(value.pid) > 2147483647 ||
        !text(value.start_ticks, 20, budget, /^[1-9][0-9]{0,19}$/) ||
        type(value.command) != "array" || length(value.command) < 4 || length(value.command) > 16 ||
        value.command[0] != "/usr/bin/loki-core" || value.command[1] != "run" ||
        value.command[2] != "-c" || value.command[3] != value.config_path) return false;
    for (let argument in value.command)
        if (!text(argument, 4096, budget, /^[ -~]+$/)) return false;
    return true;
}

function valid_model(value, stored) {
    let budget = { bytes: 0, tokens: 0 };
    if (!only(value, [ "schema", "phase", "active", "candidate" ], [ "write_id" ]) ||
        type(value.schema) != "int" || value.schema != 1 ||
        (stored && !hex(value.write_id, budget)) ||
        !text(value.phase, 16, budget) || index([ "ready", "applying", "stopped" ], value.phase) < 0) return false;
    if (value.phase == "stopped") return value.active == null && value.candidate == null;
    if (value.phase == "ready")
        return value.candidate == null && valid_context(value.active, true, budget);
    return (value.active == null || valid_context(value.active, true, budget)) &&
        valid_context(value.candidate, false, budget);
}

function shallow(data) {
    let depth = 0, tokens = 0;
    let quoted = false, escaped = false, word = false;
    for (let i = 0; i < length(data); i++) {
        let c = substr(data, i, 1);
        if (quoted) {
            if (escaped) escaped = false;
            else if (c == "\\") escaped = true;
            else if (c == '"') quoted = false;
            continue;
        }
        if (c == '"') { quoted = true; word = false; tokens++; }
        else if (c == "{" || c == "[") { depth++; tokens++; word = false; }
        else if (c == "}" || c == "]") { depth--; word = false; }
        else if (index(" \t\r\n,:", c) >= 0) word = false;
        else if (!word) { tokens++; word = true; }
        if (depth < 0 || depth > DEPTH_LIMIT || tokens > TOKEN_LIMIT) return false;
    }
    return depth == 0 && !quoted;
}

function prefix(nonce) {
    return '{"schema":1,"write_id":"' + nonce + '","phase":';
}

function encode(value, nonce) {
    return prefix(nonce) + sprintf("%J", value.phase) + ',"active":' + sprintf("%J", value.active) +
        ',"candidate":' + sprintf("%J", value.candidate) + "}\n";
}

function parse(data) {
    if (type(data) != "string") return error("invalid");
    if (length(data) > BYTE_LIMIT) return error("size-limit");
    if (index(data, "\u0000") >= 0 || !shallow(data)) return error("invalid");
    try {
        let value = json(data);
        if (!valid_model(value, true) || data != encode(value, value.write_id)) return error("invalid");
        return { model: value };
    }
    catch (e) { return error("invalid"); }
}

function same_directory(first, second) {
    return first?.type == "directory" && second?.type == "directory" &&
        first.inode == second.inode && first.dev.major == second.dev.major &&
        first.dev.minor == second.dev.minor && first.uid == second.uid && first.mode == second.mode;
}

function location(create) {
    if (type(paths.base) != "string" || substr(paths.base, 0, 1) != "/" ||
        index(paths.base, "\u0000") >= 0 || length(paths.base) > 4096) return null;
    let owner = fs.stat("/proc/self").uid;
    let path = "";
    for (let part in split(substr(directory(), 1), "/")) {
        if (part == "" || part == "." || part == "..") return null;
        path += "/" + part;
        let node = fs.lstat(path);
        let private = path == paths.base || path == directory();
        if (node == null && private && create) {
            fs.mkdir(path, 0700);
            node = fs.lstat(path);
        }
        if (node?.type != "directory") return null;
        if (private) {
            if (node.uid != owner || (node.mode & 07777) != 0700) return null;
        }
        else if ((node.uid != owner && node.uid != 0) ||
            ((node.mode & 0022) != 0 && !(node.uid == 0 && (node.mode & 01000) != 0))) return null;
    }
    return fs.lstat(directory());
}

function ensure() {
    try { return location(true) != null; }
    catch (e) { return false; }
}

function safe_file(node) {
    return node?.type == "file" && node.uid == fs.stat("/proc/self").uid &&
        (node.mode & 07777) == 0600 && node.nlink == 1 && node.size <= BYTE_LIMIT;
}

function absent(before) {
    let handle;
    let missing = false;
    try {
        handle = fs.opendir(directory());
        if (handle == null || !same_directory(before, fs.stat(descriptor(handle)))) {
            if (handle != null) close_file(handle);
            return false;
        }
        for (let i = 0; i < ENTRY_LIMIT; i++) {
            fs.error();
            let entry = handle.read();
            let failure = fs.error();
            if (entry == null) { missing = failure == null; break; }
            if (entry == "context.json") break;
        }
    }
    catch (e) { missing = false; }
    let closed = handle != null && close_file(handle);
    return missing && closed && files.same_node(before, fs.lstat(directory()));
}

function open() {
    let file;
    try {
        let dir = location(false);
        if (dir == null) return error("unavailable");
        let node = fs.lstat(filename());
        if (node == null) return error(absent(dir) ? "missing" : "unavailable");
        if (!safe_file(node)) return error("unavailable");
        file = fs.open(filename(), "re");
        if (file == null) return error("unavailable");
        if (files.same_node(node, fs.stat(descriptor(file)))) {
            fs.error();
            let data = file.read(BYTE_LIMIT + 1);
            let failed = file.error();
            if (failed == null && files.same_node(node, fs.stat(descriptor(file))) &&
                files.same_node(node, fs.lstat(filename())) && same_directory(dir, location(false))) {
                let parsed = parse(data);
                if (parsed.error == null) return { model: parsed.model, file, stat: node };
                if (!close_file(file)) return error("unavailable");
                return parsed;
            }
        }
    }
    catch (e) {}
    if (file != null) close_file(file);
    return error("unavailable");
}

function close(snapshot) {
    let file = snapshot?.file;
    if (file == null) return false;
    snapshot.file = null;
    return close_file(file);
}

function read() {
    let snapshot = open();
    if (snapshot.error != null) return snapshot;
    let model = snapshot.model;
    return close(snapshot) ? { model } : error("unavailable");
}

function unchanged(snapshot) {
    try {
        return snapshot?.file != null && location(false) != null &&
            files.same_node(snapshot.stat, fs.stat(descriptor(snapshot.file))) &&
            files.same_node(snapshot.stat, fs.lstat(filename()));
    }
    catch (e) { return false; }
}

function data_key(value) {
    if (value == null) return null;
    return sprintf("%J", [ value.generation, value.config_path, value.config_digest, value.nft_digest,
        value.controller.endpoint, value.controller.secret, map(value.sections, (entry) =>
            [ entry.section[".name"], entry.matchers.subnets, entry.matchers.ports,
                entry.matchers.subnet_tags, map(SET_KEYS, (key) => entry.matchers.sets[key]) ]) ]);
}

function transition(previous, next) {
    if (next.phase == "stopped") return true;
    if (next.phase == "applying") {
        let active = previous?.phase == "stopped" ? null : previous?.active;
        if (data_key(active) != data_key(next.active)) return false;
        if (active != null && (active.pid != next.active.pid || active.start_ticks != next.active.start_ticks ||
            sprintf("%J", active.command) != sprintf("%J", next.active.command))) return false;
        return next.candidate.generation != active?.generation &&
            next.candidate.generation != previous?.candidate?.generation;
    }
    if (previous?.phase == "applying") return data_key(next.active) == data_key(previous.candidate);
    return previous?.phase == "ready" && data_key(next.active) == data_key(previous.active) &&
        sprintf("%J", next.active.command) == sprintf("%J", previous.active.command);
}

// Lifecycle writers hold one lock. Only a nonce and matching header identify an abandoned temporary.
function collect_temporaries(keep) {
    let handle;
    let ok = false;
    try {
        let before = location(false);
        handle = fs.opendir(directory());
        if (handle == null || !same_directory(before, fs.stat(descriptor(handle)))) {
            if (handle != null) close_file(handle);
            return false;
        }
        for (let i = 0; i < ENTRY_LIMIT; i++) {
            fs.error();
            let name = handle.read();
            let failure = fs.error();
            if (name == null) { ok = failure == null; break; }
            if (type(name) != "string" || index(name, "\u0000") >= 0 || name == keep) continue;
            let match_name = match(name, /^\.context-([a-f0-9]{64})\.tmp$/);
            if (match_name == null) continue;
            let path = directory() + "/" + name;
            let node = fs.lstat(path);
            if (!safe_file(node)) continue;
            let file = fs.open(path, "re");
            if (file == null) continue;
            let expected = prefix(match_name[1]);
            let data;
            let stable = false;
            try {
                if (files.same_node(node, fs.stat(descriptor(file)))) {
                    fs.error();
                    data = file.read(length(expected));
                    stable = file.error() == null && files.same_node(node, fs.stat(descriptor(file)));
                }
            }
            catch (e) {}
            if (!close_file(file)) break;
            if (stable && data == expected && files.same_node(node, fs.lstat(path)) && !fs.unlink(path)) break;
        }
        ok = ok && same_directory(before, location(false));
    }
    catch (e) { ok = false; }
    return handle != null && close_file(handle) && ok;
}

function write(value) {
    let temporary;
    let created;
    try {
        if (!valid_model(value, false) || !ensure()) return false;
        let previous = read();
        if (previous.error != null && previous.error != "ruleset-context-missing") return false;
        if (!transition(previous.model, value)) return false;
        let nonce = credential.generate();
        if (!hex(nonce, { bytes: 0, tokens: 0 })) return false;
        let data = encode(value, nonce);
        if (length(data) > BYTE_LIMIT || !shallow(data)) return false;
        let name = ".context-" + nonce + ".tmp";
        if (!collect_temporaries(name)) return false;
        let parent = location(false);
        temporary = directory() + "/" + name;
        if (!common.write_private_file(temporary, data)) return false;
        created = fs.lstat(temporary);
        if (safe_file(created) && same_directory(parent, location(false)) && fs.rename(temporary, filename()))
            return true;
    }
    catch (e) {}
    try {
        if (created != null && files.same_node(created, fs.lstat(temporary))) fs.unlink(temporary);
    }
    catch (e) {}
    return false;
}

return { paths, ensure, parse, open, close, read, unchanged, write };
