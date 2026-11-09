function endpoint(value) {
    value = trim("" + (value ?? ""));
    let colon = rindex(value, ":");
    if (colon < 0)
        return null;

    let host = substr(value, 0, colon);
    let port = substr(value, colon + 1);
    if (match(port, /^[0-9]+$/) == null)
        return null;
    if (substr(host, 0, 1) == "[" && substr(host, length(host) - 1) == "]")
        host = substr(host, 1, length(host) - 2);
    if (host == "")
        host = "::";

    return { host: lc(host), port };
}

function ipv4_host(host) {
    return match(host, /^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$/) != null;
}

function endpoint_hosts_overlap(left, right) {
    if (left == right || left == "::" || right == "::")
        return true;
    if (left == "0.0.0.0")
        return ipv4_host(right);
    if (right == "0.0.0.0")
        return ipv4_host(left);
    return false;
}

function tcp_endpoint_in_use(netstat, requested_endpoint) {
    let requested = endpoint(requested_endpoint);
    if (requested == null)
        return false;

    for (let line in split(netstat == null ? "" : "" + netstat, "\n")) {
        let fields = split(trim(line), /[ \t\r\n]+/);
        if (length(fields) < 4 || substr(fields[0], 0, 3) != "tcp")
            continue;

        let listener = endpoint(fields[3]);
        if (listener != null && listener.port == requested.port && endpoint_hosts_overlap(listener.host, requested.host))
            return true;
    }

    return false;
}

function as_string(value) {
    return value == null ? "" : "" + value;
}

function fields(line) {
    line = trim(line);
    return line == "" ? [] : split(line, /[ \t\r\n]+/);
}

function starts_with(value, prefix) {
    return substr(as_string(value), 0, length(prefix)) == prefix;
}

function ends_with(value, suffix) {
    value = as_string(value);
    return length(value) >= length(suffix) && substr(value, length(value) - length(suffix)) == suffix;
}

function addr_port(addr) {
    addr = as_string(addr);
    let colon = rindex(addr, ":");
    return colon >= 0 ? substr(addr, colon + 1) : addr;
}

function addr_host(addr) {
    addr = as_string(addr);
    if (substr(addr, 0, 1) == "[") {
        let end = index(addr, "]");
        return end > 0 ? substr(addr, 1, end - 1) : addr;
    }
    let colon = rindex(addr, ":");
    return colon >= 0 ? substr(addr, 0, colon) : addr;
}

// A wildcard listener serves every address of its family, and a requested wildcard is
// satisfied by any address of that family.
function addr_matches(addr, listen, port) {
    addr = as_string(addr);
    listen = as_string(listen);
    port = as_string(port);

    if (addr_port(addr) != port)
        return false;

    let host = addr_host(addr);
    if (host == "0.0.0.0" || host == "::")
        return true;
    if (listen == "0.0.0.0")
        return ipv4_host(host);
    if (listen == "::")
        return index(host, ":") >= 0;

    return host == listen;
}

function port_listening(data, listen, port, proto) {
    proto = as_string(proto);

    for (let line in split(as_string(data), "\n")) {
        let parts = fields(line);
        if (length(parts) < 4 || !starts_with(parts[0], proto))
            continue;

        if (addr_matches(parts[3], listen, port))
            return true;
    }

    return false;
}

function sorted_unique(values) {
    let seen = {};
    let result = [];
    for (let value in values) {
        value = as_string(value);
        if (value != "" && !seen[value]) {
            seen[value] = true;
            push(result, value);
        }
    }

    sort(result, function(a, b) {
        return a < b ? -1 : (a > b ? 1 : 0);
    });
    return result;
}

// Without the PID/Program column busybox netstat reports no owner, so none is claimed then.
// loki-core itself is never a conflict.
function port_conflict_owners(data, listen, port, proto) {
    let owners = [];
    let line_number = 0;
    let owner_supported = false;

    for (let line in split(as_string(data), "\n")) {
        line_number++;
        if (line_number == 2) {
            owner_supported = index(as_string(line), "PID/Program") >= 0;
            continue;
        }

        if (!owner_supported)
            continue;

        let parts = fields(line);
        if (length(parts) < 4 || !starts_with(parts[0], proto) || !addr_matches(parts[3], listen, port))
            continue;

        let owner = as_string(parts[length(parts) - 1]);
        if (owner == "" || owner == "-" || owner == "LISTEN")
            owner = "unknown";
        if (!ends_with(owner, "/loki-core"))
            push(owners, owner);
    }

    return sorted_unique(owners);
}

// Readiness is read from /proc/net/tcp{,6} rather than netstat. The kernel prints local
// addresses as little-endian hex words; TCP_LISTEN is 0A. No regex or sprintf below: this
// runs behind every status poll, and a regex match is costly on a MIPS router.
const PROC_TCP_LISTEN = "0A";
const HEX_DIGITS = "0123456789ABCDEF";
const DECIMAL_DIGITS = "0123456789";

function hex_byte(value) {
    value = int(value) & 255;
    return substr(HEX_DIGITS, value / 16, 1) + substr(HEX_DIGITS, value % 16, 1);
}

// Host byte order, little-endian on every target OpenWrt builds for here.
function proc_hex_word(bytes, offset) {
    return hex_byte(bytes[offset + 3]) + hex_byte(bytes[offset + 2]) +
        hex_byte(bytes[offset + 1]) + hex_byte(bytes[offset]);
}

function digits_value(text, alphabet, limit) {
    text = as_string(text);
    let size = length(text);
    if (size < 1 || size > limit)
        return -1;

    let base = length(alphabet);
    let value = 0;
    for (let i = 0; i < size; i++) {
        let digit = index(alphabet, uc(substr(text, i, 1)));
        if (digit < 0)
            return -1;
        value = value * base + digit;
    }
    return value;
}

function ipv4_bytes(address) {
    let parts = split(as_string(address), ".");
    if (length(parts) != 4)
        return null;

    let bytes = [];
    for (let part in parts) {
        let value = digits_value(part, DECIMAL_DIGITS, 3);
        if (value < 0 || value > 255)
            return null;
        push(bytes, value);
    }
    return bytes;
}

function ipv6_group_bytes(group) {
    let value = digits_value(group, HEX_DIGITS, 4);
    if (value < 0)
        return null;
    return [ (value / 256) & 255, value & 255 ];
}

function ipv6_bytes(address) {
    address = as_string(address);
    if (address == "")
        return null;

    let halves = split(address, "::");
    if (length(halves) > 2)
        return null;

    let head = halves[0] == "" ? [] : split(halves[0], ":");
    let tail = length(halves) < 2 || halves[1] == "" ? [] : split(halves[1], ":");
    if (length(halves) < 2 && length(head) != 8)
        return null;

    let head_bytes = [];
    for (let group in head) {
        let bytes = ipv6_group_bytes(group);
        if (bytes == null)
            return null;
        push(head_bytes, ...bytes);
    }

    let tail_bytes = [];
    for (let group in tail) {
        let bytes = ipv6_group_bytes(group);
        if (bytes == null)
            return null;
        push(tail_bytes, ...bytes);
    }

    let filled = length(head_bytes) + length(tail_bytes);
    if (filled > 16)
        return null;

    let result = [ ...head_bytes ];
    for (let i = filled; i < 16; i++)
        push(result, 0);
    push(result, ...tail_bytes);
    return result;
}

// The addresses asked about never change within a process, and the conversion is costly.
let proc_address_hex_cache = {};

function proc_address_hex(address) {
    address = as_string(address);
    let cached = proc_address_hex_cache[address];
    if (cached != null)
        return cached;

    let bytes = index(address, ":") >= 0 ? ipv6_bytes(address) : ipv4_bytes(address);
    let hex = "";
    if (bytes != null)
        for (let offset = 0; offset < length(bytes); offset += 4)
            hex += proc_hex_word(bytes, offset);

    proc_address_hex_cache[address] = hex;
    return hex;
}

function proc_port_hex(port) {
    let value = digits_value(port, DECIMAL_DIGITS, 5);
    if (value < 0 || value > 65535)
        return "";
    return hex_byte(value / 256) + hex_byte(value % 256);
}

// tcp{4,6}_seq_show print a fixed layout ("%4d: %08X:%04X %08X:%04X %02X ..."), so a listening
// socket is an exact substring: ": " anchors the local column, an all-zero remote and state
// 0A prove it listens.
const PROC_ZERO_WORDS = "00000000000000000000000000000000";

function proc_zero_remote(width) {
    return substr(PROC_ZERO_WORDS, 0, width) + ":0000";
}

function proc_listener_token(address, port, state) {
    let hex = proc_address_hex(address);
    let port_hex = proc_port_hex(port);
    if (hex == "" || port_hex == "")
        return "";

    return ": " + hex + ":" + port_hex + " " + proc_zero_remote(length(hex)) +
        " " + (state || PROC_TCP_LISTEN);
}

// The family wildcard counts, since it serves every address of its family.
function proc_socket_listening(data, addresses, port, state) {
    data = uc(as_string(data));

    for (let address in addresses) {
        let token = proc_listener_token(address, port, state);
        if (token != "" && index(data, token) >= 0)
            return true;
    }

    return false;
}

function sing_box_standard_ports_listening_proc(tcp, tcp6, dns_address, tproxy_port, tproxy6_address) {
    dns_address = dns_address == null || dns_address == "" ? "127.0.0.42" : as_string(dns_address);
    tproxy_port = tproxy_port == null || tproxy_port == "" ? "1602" : as_string(tproxy_port);
    tproxy6_address = tproxy6_address == null || tproxy6_address == "" ? "::1" : as_string(tproxy6_address);

    tcp = uc(as_string(tcp));

    return proc_socket_listening(tcp, [ dns_address, "0.0.0.0" ], "53") &&
        proc_socket_listening(tcp, [ "0.0.0.0", "127.0.0.1" ], tproxy_port) &&
        proc_socket_listening(tcp6, [ tproxy6_address, "::" ], tproxy_port);
}

return {
    sing_box_standard_ports_listening_proc,
    proc_socket_listening,
    proc_address_hex,
    tcp_endpoint_in_use,
    port_listening,
    port_conflict_owners,
    sorted_unique
};
