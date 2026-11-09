let fs = require("fs");
let files = require("service.preflight_files");
let constants = require("singbox.constants");

const TABLES = { tcp: 4, tcp6: 6, udp: 4, udp6: 6 };
const BYTE_LIMIT = 262144;
const ROW_LIMIT = 2048;

function parse(data, name) {
    if (type(name) != "string" || !exists(TABLES, name))
        return { error: "listener-table-kind-invalid" };
    if (type(data) != "string" || data == "" || index(data, "\u0000") >= 0 || substr(data, -1) != "\n")
        return { error: "listener-table-data-invalid" };
    if (length(data) > BYTE_LIMIT)
        return { error: "listener-table-size-limit" };
    let lines = split(data, "\n");
    pop(lines);
    let udp = substr(name, 0, 3) == "udp";
    let header = "sl local_address " + (TABLES[name] == 6 ? "remote_address" : "rem_address") +
        " st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode" + (udp ? " ref pointer drops" : "");
    if (length(lines[0]) > 1024 || join(" ", split(trim(shift(lines)), /[ \t]+/)) != header)
        return { error: "listener-table-header-invalid" };
    if (length(lines) > ROW_LIMIT)
        return { error: "listener-table-row-limit" };
    let bindings = [];
    let seen = {};
    for (let line in lines) {
        if (length(line) > 1024 || !match(line, /^[\t -~]+$/))
            return { error: "listener-table-row-invalid" };
        let row = split(trim(line), /[ \t]+/);
        let endpoint = TABLES[name] == 6 ? /^([0-9A-F]{32}):([0-9A-F]{4})$/ : /^([0-9A-F]{8}):([0-9A-F]{4})$/;
        let local = match(row[1] || "", endpoint);
        let remote = match(row[2] || "", endpoint);
        if (length(row) < 10 || length(row) > 24 || !match(row[0], /^[0-9]{1,10}:$/) ||
            local == null || remote == null || !match(row[3], /^[0-9A-F]{2}$/) ||
            !match(row[4], /^[0-9A-F]{8}:[0-9A-F]{8}$/) ||
            !match(row[5], /^[0-9A-F]{2}:[0-9A-F]{8,16}$/) || !match(row[6], /^[0-9A-F]{8}$/) ||
            !match(row[7], /^(0|[1-9][0-9]{0,9})$/) || int(row[7]) > 4294967295 ||
            !match(row[8], /^-?[0-9]{1,20}$/) || !match(row[9], /^(0|[1-9][0-9]{0,19})$/))
            return { error: "listener-table-row-invalid" };
        for (let i = 10; i < length(row); i++)
            if (!match(row[i], /^-?[0-9A-Fa-f]{1,32}$/))
                return { error: "listener-table-row-invalid" };
        let state = hex(row[3]);
        if ((udp && state != 1 && state != 7) || (!udp && (state < 1 || state > 12)))
            return { error: "listener-table-state-invalid" };
        if (!udp && state != 10)
            continue;
        let port = hex(local[2]);
        if (port == 0 || (!udp && (hex(remote[2]) != 0 || match(remote[1], /^0+$/) == null)))
            return { error: "listener-table-row-invalid" };
        let item = { address: local[1], port, remote_address: remote[1], remote_port: hex(remote[2]),
            state, uid: row[7], inode: row[9] };
        let identity = sprintf("%J", item);
        // UDP bucket numbers repeat; separate reuse-port sockets have separate inodes.
        if (seen[identity])
            return { error: "listener-table-duplicate-binding" };
        seen[identity] = true;
        push(bindings, item);
    }
    return { bindings, rows: length(lines) };
}

function read_table(root, name) {
    let path = root + "/proc/self/net/" + name;
    if (root != "") {
        let target = {};
        target["/proc/self/net/" + name] = "file";
        if (files.collect(root, target)[0].reason != "candidate-existing-file-origin-unverified")
            return { error: "listener-table-path-unavailable" };
    }
    let node = fs.lstat(path);
    let owner = root == "" ? 0 : fs.lstat(root)?.uid;
    if (node?.type != "file" || node.uid != owner || node.nlink != 1 || (node.mode & 0022) != 0)
        return { error: "listener-table-path-unavailable" };
    let file = fs.open(path, "re");
    if (file == null)
        return { error: "listener-table-open-failed" };
    let result;
    try {
        let descriptor = "/proc/self/fd/" + file.fileno();
        if (!files.same_node(node, fs.stat(descriptor)))
            result = { error: "listener-table-changed-during-read" };
        else {
            // procfs tables have st_size zero; never use it as the read bound or EOF proof.
            fs.error();
            let data = file.read(BYTE_LIMIT + 1);
            let error = file.error();
            if (error != null || type(data) != "string")
                result = { error: "listener-table-read-failed" };
            else if (length(data) > BYTE_LIMIT)
                result = { error: "listener-table-size-limit" };
            else if (!files.same_node(node, fs.stat(descriptor)) || !files.same_node(node, fs.lstat(path)))
                result = { error: "listener-table-changed-during-read" };
            else
                result = parse(data, name);
        }
    }
    catch (e) { result = { error: "listener-table-read-failed" }; }
    try { if (file.close() !== true) result = { error: "listener-table-read-failed" }; }
    catch (e) { result = { error: "listener-table-read-failed" }; }
    return result;
}

function fingerprint(bindings) {
    return join("\n", sort(map(bindings, (item) => sprintf("%J", item))));
}

function dns_overlap(address, family) {
    if (!require("core.ip").valid_ipv4(constants.DNS_INBOUND_ADDRESS)) return true;
    let encoder = require("core.netstat").proc_address_hex;
    let expected = encoder(constants.DNS_INBOUND_ADDRESS);
    if (family == 6) expected = substr(encoder("::ffff:0:0"), 0, 24) + expected;
    if (length(expected) != (family == 4 ? 8 : 32)) return true;
    // The shared readiness encoder uses little endian words; retain possible matches on either CPU byte order.
    let swapped = "";
    for (let offset = 0; offset < length(expected); offset += 8)
        swapped += substr(expected, offset + 6, 2) + substr(expected, offset + 4, 2) +
            substr(expected, offset + 2, 2) + substr(expected, offset, 2);
    return index([ expected, swapped, encoder(family == 4 ? "0.0.0.0" : "::") ], address) >= 0;
}

function collect(root, scope) {
    root = root == "/" ? "" : root;
    let ports = {};
    ports[constants.DNS_INBOUND_PORT] = "dns";
    ports[constants.TPROXY_INBOUND_PORT] = "tproxy";
    ports[constants.SOURCE_DNS_INBOUND_PORT] = "source-dns";
    ports[constants.SYSTEM_TPROXY_INBOUND_PORT] = "system-tproxy";
    ports[constants.SYSTEM_DNS_INBOUND_PORT] = "system-dns";
    let result = [], clear = true;
    for (let name in sort(keys(TABLES))) {
        let label = "ipv" + TABLES[name] + "-" + (substr(name, 0, 3) == "udp" ? "udp" : "tcp");
        let first = read_table(root, name);
        let second = first.error == null ? read_table(root, name) : first;
        let error = second.error;
        if (error == null && fingerprint(first.bindings) != fingerprint(second.bindings))
            error = "listener-bindings-changed";
        if (error != null) {
            clear = false;
            push(result, { kind: "listeners", object: label, state: "incomplete", reason: error });
            continue;
        }
        let occupied = {};
        for (let binding in second.bindings) {
            let role = ports[binding.port];
            if (role == "dns" && !dns_overlap(binding.address, TABLES[name])) role = null;
            if (binding.port == constants.HTTPS_GATEWAY_PORT && substr(name, 0, 3) == "tcp")
                role = "gateway";
            if (role != null) occupied[role] = true;
        }
        for (let role in sort(keys(occupied)))
            push(result, { kind: "listeners", object: label + "-" + role, state: "incomplete",
                reason: "listener-candidate-port-occupied-unverified" });
        if (length(keys(occupied)) != 0) clear = false;
        push(result, { kind: "listeners", object: label, state: "checked", reason: "listener-table-read-complete" });
    }
    // Empty candidate bindings need no process owner; the caller rechecks its PID1-relative scope.
    let verified = clear && scope?.error == null && type(scope?.identities) == "object";
    push(result, { kind: "listeners", object: "socket-owners", state: verified ? "checked" : "incomplete",
        reason: verified ? "listener-candidate-ports-clear" : "listener-process-ownership-unverified" });
    push(result, { kind: "listeners", object: "namespace-and-configuration", state: verified ? "checked" : "incomplete",
        reason: verified ? "listener-pid1-scope-bindings-checked" : "listener-namespace-and-bind-configuration-unverified" });
    return result;
}

return { collect, parse, read_table };
