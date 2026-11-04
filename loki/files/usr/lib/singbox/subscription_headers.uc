let fs = require("fs");
let common = require("core.common");
let packages = require("core.packages");

let as_string = common.as_string;

let paths = {
    openwrt_release: "/etc/openwrt_release"
};

function clean_header_value(value) {
    return trim(replace(as_string(value), /[\r\n]+/g, " "));
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_output(command) {
    let pipe = fs.popen(command, "r");
    if (!pipe)
        return "";

    let output = pipe.read("all");
    let status = pipe.close();
    return status == 0 && output != null ? as_string(output) : "";
}

// The OpenWrt release, not the kernel; left out when unknown, since the header is optional.
function os_version() {
    let data = fs.readfile(paths.openwrt_release);
    if (data != null) {
        let prefix = "DISTRIB_RELEASE='";
        for (let line in split(as_string(data), "\n")) {
            if (substr(line, 0, length(prefix)) != prefix)
                continue;
            let rest = substr(line, length(prefix));
            let quote = rindex(rest, "'");
            let value = clean_header_value(quote >= 0 ? substr(rest, 0, quote) : rest);
            if (value != "")
                return value;
        }
    }
    return "";
}

function device_model() {
    let model = clean_header_value(fs.readfile("/tmp/sysinfo/model"));
    return model != "" ? model : "OpenWrt Router";
}

function generated_hwid() {
    let mac = clean_header_value(fs.readfile("/sys/class/net/eth0/address"));
    if (mac == "")
        mac = clean_header_value(fs.readfile("/sys/class/net/br-lan/address"));

    let input = mac + "-" + device_model();
    let output = split(trim(command_output("printf %s " + shell_quote(input) + " | md5sum")), /[ \t]+/)[0] || "";
    let hash = substr(output, 0, 16);
    return substr(hash, 0, 4) + "-" + substr(hash, 4, 4) + "-" + substr(hash, 8, 4) + "-" + substr(hash, 12, 4);
}

function header_line(name, value) {
    return as_string(name) + ": " + clean_header_value(value);
}

// Panels pick a sing-box template by this version and cannot parse the fork's suffix.
function upstream_sing_box_version() {
    let installed = packages.sing_box_version();
    let base = split(installed, "-")[0];
    return match(base, /^[0-9]+(\.[0-9]+)*$/) != null ? base : "";
}

// The core's name first, as panels match on that token; without a core no version is claimed.
function default_user_agent() {
    let version = upstream_sing_box_version();
    return version != "" ? "sing-box/" + version : "sing-box";
}

// The set Happ defined and Remnawave standardised: X-HWID is the one a panel requires, and the
// device fields are what it shows when a key turns up on a second device.
function default_header_lines(hwid) {
    if (hwid == null)
        hwid = generated_hwid();
    else
        hwid = clean_header_value(hwid);

    let result = [
        header_line("User-Agent", default_user_agent()),
        header_line("X-Device-OS", "OpenWrt Linux"),
        header_line("X-Device-Model", device_model())
    ];
    let version = os_version();
    if (version != "")
        push(result, header_line("X-Ver-OS", version));
    if (hwid != "")
        push(result, header_line("X-HWID", hwid));
    return result;
}

function parse_header_line(value) {
    value = as_string(value);
    let separator = index(value, ":");
    if (separator <= 0)
        return { valid: false, message: "expected 'Name: Value'" };

    let name = trim(substr(value, 0, separator));
    let header_value = trim(substr(value, separator + 1));
    if (match(name, /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/) == null)
        return { valid: false, message: "header name contains invalid characters" };
    if (match(header_value, /[\r\n]/) != null)
        return { valid: false, message: "header value contains a line break" };

    return { valid: true, name, value: header_value };
}

function parse_header_lines(lines) {
    if (type(lines) != "array")
        lines = lines == null || as_string(lines) == "" ? [] : [ lines ];

    let result = {};
    let names = {};
    for (let i = 0; i < length(lines); i++) {
        let parsed = parse_header_line(lines[i]);
        if (!parsed.valid)
            return { valid: false, message: "header " + (i + 1) + ": " + parsed.message, headers: {} };

        let normalized_name = lc(parsed.name);
        let name = names[normalized_name];
        if (name == null) {
            name = parsed.name;
            names[normalized_name] = name;
            result[name] = [];
        }
        push(result[name], parsed.value);
    }

    return { valid: true, message: "", headers: result };
}

return {
    paths,
    default_user_agent,
    generated_hwid,
    default_header_lines,
    parse_header_line,
    parse_header_lines
};
