// Prepare only LoKi's boot state; shared HTTPS files and network configuration stay read-only.
let fs = require("fs");
let ubus = require("ubus");
let uci = require("core.uci");
let ip = require("core.ip");
let common = require("core.common");
let storage = require("core.cache_path");
let secret = require("service.gateway_secret");
let constants = require("singbox.constants");

const GATEWAY_PATH = "/tmp/loki/gateway.json";
const FORMAT = "loki-gateway-1";

function refuse(reason) {
    die("LoKi HTTPS gateway: " + reason);
}

function hostname(value) {
    if (type(value) != "string" || value == "" || length(value) > 253)
        return false;
    for (let label in split(value, "."))
        if (length(label) > 63 || match(label, /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) == null)
            return false;
    return match(value, /^[0-9.]+$/) == null;
}

function file_path(value) {
    if (type(value) != "string" || substr(value, 0, 1) != "/" || match(value, /[[:cntrl:]]/) || index(value, chr(0)) >= 0)
        return false;
    for (let part in split(substr(value, 1), "/"))
        if (part == "" || part == "." || part == "..")
            return false;
    return true;
}

function lan_status() {
    let connection;
    let status;
    try {
        connection = ubus.connect(null, 2);
        if (connection != null)
            status = connection.call("network.interface.lan", "status", {});
    }
    catch (e) {}
    if (connection != null) {
        try { connection.disconnect(); }
        catch (e) { status = null; }
    }
    if (type(status) != "object" || status.up !== true)
        refuse("LAN status is unavailable or incomplete");
    let addresses = [];
    let ipv4 = status["ipv4-address"] ?? [];
    let ipv6 = status["ipv6-address"] ?? [];
    let assignments = status["ipv6-prefix-assignment"] ?? [];
    if (type(ipv4) != "array" || type(ipv6) != "array" || type(assignments) != "array" ||
        length(ipv4) > 16 || length(ipv6) > 16 || length(assignments) > 16)
        refuse("LAN address status is invalid or excessive");
    ipv6 = [ ...ipv6 ];
    for (let entry in ipv4) {
        let address = entry?.address;
        if (!ip.valid_ipv4(address) || match(address, /^(0|127|22[4-9]|23[0-9]|24[0-9]|25[0-5])\./))
            refuse("LAN address is unusable");
        if (index(addresses, address) < 0)
            push(addresses, address);
    }
    for (let entry in assignments) {
        if (type(entry) != "object")
            refuse("LAN IPv6 assignment is invalid");
        if (entry["local-address"] != null)
            push(ipv6, entry["local-address"]);
    }
    for (let entry in ipv6) {
        let address = entry?.address;
        if (type(entry) != "object" || !ip.valid_ipv6(address) || index(address, ".") >= 0)
            refuse("LAN IPv6 address is invalid");
        let bytes = iptoarr(address);
        address = arrtoip(bytes);
        if (address == "::" || address == "::1" || bytes[0] == 255 ||
            (join(".", slice(bytes, 0, 12)) == "0.0.0.0.0.0.0.0.0.0.255.255"))
            refuse("LAN IPv6 address is unusable");
        // Link-local addresses need an interface scope and cannot identify a browser origin here.
        if (bytes[0] == 254 && (bytes[1] & 0xc0) == 0x80)
            continue;
        if (index(addresses, address) < 0)
            push(addresses, address);
    }
    if (length(addresses) == 0)
        refuse("LAN has no usable address");
    if (length(addresses) > 16)
        refuse("too many active LAN addresses");
    return addresses;
}

function configuration() {
    let addresses = lan_status();
    let settings = uci.get_all("loki", "settings") ?? {};
    let address = common.option(settings, "service_listen_address", "");
    if (address != "") {
        if (ip.valid_ipv6(address))
            address = arrtoip(iptoarr(address));
        if (index(addresses, address) < 0)
            refuse("the configured service address is not an active LAN address");
    }
    let listen = map(address == "" ? addresses : [ address ], (value) =>
        (index(value, ":") >= 0 ? "[" + value + "]" : value) + ":" + constants.HTTPS_GATEWAY_PORT);
    let http = uci.get_all("uhttpd", "main");
    if (type(http) != "object" || !file_path(http.cert) || !file_path(http.key))
        refuse("existing uhttpd HTTPS certificate and key paths are required");
    let listeners = http.listen_https;
    if (type(listeners) == "string")
        listeners = [ listeners ];
    if (type(listeners) != "array" || length(listeners) == 0 || length(listeners) > 16)
        refuse("uhttpd HTTPS listener configuration is incomplete");
    let ports = [];
    for (let listener in listeners) {
        let matched = type(listener) == "string" ? match(listener, /^(\[[0-9a-fA-F:]+\]|[0-9.]+):([1-9][0-9]{0,4})$/) : null;
        if (matched == null || int(matched[2]) > 65535 ||
            (substr(matched[1], 0, 1) == "[" ? !ip.valid_ipv6(substr(matched[1], 1, length(matched[1]) - 2)) : !ip.valid_ipv4(matched[1])))
            refuse("uhttpd HTTPS listener configuration is invalid");
        let port = int(matched[2]);
        if (index(ports, port) < 0)
            push(ports, port);
    }
    if (length(ports) > 8)
        refuse("too many uhttpd HTTPS ports");
    let hosts = [ ...addresses ];
    let name = lc(common.as_string(uci.get("system.@system[0].hostname")));
    let domain = lc(common.as_string(uci.get("dhcp.@dnsmasq[0].domain")));
    if (name != "") {
        if (!hostname(name))
            refuse("the system hostname is invalid");
        if (index(hosts, name) < 0)
            push(hosts, name);
        if (domain != "") {
            if (!hostname(domain) || !hostname(name + "." + domain))
                refuse("the local DNS domain is invalid");
            if (index(hosts, name + "." + domain) < 0)
                push(hosts, name + "." + domain);
        }
    }
    if (length(hosts) > 16)
        refuse("too many trusted LAN aliases");
    return { format: FORMAT, listen, hosts, luci_https_ports: ports, certificate: http.cert, key: http.key };
}

function previous(path) {
    let stat = fs.lstat(path);
    if (stat == null)
        return;
    if (stat.type != "file" || stat.uid != fs.stat("/proc/self").uid || stat.nlink != 1 ||
        (stat.mode & 0777) != 0600 || stat.size <= 0 || stat.size > 16384)
        refuse("existing private configuration is unsafe");
    let file = fs.open(path, "re");
    if (file == null)
        refuse("existing private configuration cannot be read");
    let data;
    try { data = file.read(16385); }
    catch (e) { file.close(); refuse("existing private configuration cannot be read"); }
    file.close();
    let after = fs.lstat(path);
    if (after == null || after.inode != stat.inode || after.dev?.major != stat.dev?.major || after.dev?.minor != stat.dev?.minor ||
        after.uid != stat.uid || after.nlink != stat.nlink || after.mode != stat.mode || after.size != stat.size ||
        after.mtime != stat.mtime || after.ctime != stat.ctime || type(data) != "string" || length(data) != stat.size ||
        common.parse_json(data)?.format != FORMAT)
        refuse("existing private configuration is unrecognized or changed");
}

function prepare() {
    let config = configuration();
    // The routing core and this separate process reuse one private credential for the current boot.
    secret.load();
    let path = storage.ensure({ cache_path: GATEWAY_PATH });
    previous(path);
    let data = sprintf("%J", config);
    if (length(data) > 16384 || !common.write_file_atomic(path, data))
        refuse("cannot publish its private configuration");
    return config;
}

return { configuration, prepare };
