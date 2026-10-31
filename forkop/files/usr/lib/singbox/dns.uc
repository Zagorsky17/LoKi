#!/usr/bin/env ucode
// Modified for LoKi on 2026-10-31: independent bootstrap and explicit main DNS encryption.

let common = require("core.common");
let core_ip = require("core.ip");
let runtime_constants = require("singbox.constants");
let runtime_url = require("core.url");
let domain_config = require("config.domain");
let connections = require("config.connections");

let as_string = common.as_string;
let bool_option = common.bool_option;
let list_option = common.list_option;
let option = common.option;

const DNS_URI_TYPES = {
    udp: "udp",
    tcp: "tcp",
    tls: "tls",
    https: "https",
    quic: "quic",
    h3: "h3"
};

const DNS_URI_DEFAULT_PORTS = {
    udp: 53,
    tcp: 53,
    tls: 853,
    https: 443,
    quic: 853,
    h3: 443
};

function server_list(settings, key, fallback) {
    let result = [];
    for (let value in list_option(settings, key)) {
        value = trim(as_string(value));
        if (value != "")
            push(result, value);
    }
    if (length(result) == 0)
        push(result, fallback);
    return result;
}

function detour_tag(settings) {
    if (!bool_option(settings, "dns_detour_enabled", false))
        return "";
    let section_name = option(settings, "dns_detour_section", "");
    return section_name == "" ? "" : runtime_constants.outbound_tag(connections.section_display_name(section_name));
}

function dns_domain_valid(value) {
    value = lc(as_string(value));
    if (value == "" || length(value) > 253 || index(value, ".") < 1 ||
        substr(value, 0, 1) == "." || substr(value, length(value) - 1, 1) == ".")
        return false;

    let labels = split(value, ".");
    for (let label in labels)
        if (label == "" || length(label) > 63 ||
            match(label, /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) == null)
            return false;

    let tld = labels[length(labels) - 1];
    return match(tld, /^[a-z]{2,}$/) != null || match(tld, /^xn--[a-z0-9-]{2,59}$/) != null;
}

function static_host_domain(value) {
    value = lc(trim(as_string(value)));
    if (value == "" || length(value) > 253 ||
        substr(value, 0, 1) == "." || substr(value, length(value) - 1, 1) == ".")
        return null;

    let ascii = domain_config.suffix_to_ascii(value);
    if (ascii == null)
        return null;

    for (let label in split(ascii, ".")) {
        if (label == "" || length(label) > 63 ||
            match(label, /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/) == null)
            return null;
    }

    return ascii;
}

function static_hosts(settings) {
    let domains = [];
    let predefined = {};

    for (let raw_line in split(as_string(option(settings, "static_hosts_text", "")), "\n")) {
        let line = replace(as_string(raw_line), /\r/g, "");
        line = replace(line, /[[:space:]]*\/\/.*$/, "");
        line = trim(replace(line, /[[:space:]]*#.*$/, ""));
        if (line == "")
            continue;

        let fields = [];
        for (let field in split(line, /[[:space:]]+/))
            if (field != "")
                push(fields, field);
        if (length(fields) < 2)
            return { unsupported: "static DNS record '" + line + "' must contain an address followed by at least one domain" };

        let address = fields[0];
        if (!core_ip.valid_ip(address))
            return { unsupported: "invalid address '" + address + "' in static DNS records" };

        for (let i = 1; i < length(fields); i++) {
            let domain = static_host_domain(fields[i]);
            if (domain == null)
                return { unsupported: "invalid domain '" + fields[i] + "' in static DNS records" };
            if (predefined[domain] == null) {
                predefined[domain] = [];
                push(domains, domain);
            }
            let known = false;
            for (let value in predefined[domain])
                if (value == address)
                    known = true;
            if (!known)
                push(predefined[domain], address);
        }
    }

    return { domains, predefined };
}

function parse_server_uri(value, ip_only) {
    value = trim(as_string(value));
    if (value == "")
        return { unsupported: "DNS server address is empty" };
    if (match(value, /[ \t\r\n@?#]/) != null)
        return { unsupported: "DNS server URI must not contain whitespace, credentials, query parameters, or fragments" };

    let scheme = runtime_url.scheme(value);
    if (scheme == "")
        scheme = "udp";
    if (DNS_URI_TYPES[scheme] == null)
        return { unsupported: "unsupported DNS server URI scheme '" + scheme + "'" };

    let server = runtime_url.host(value);
    if (!core_ip.valid_ip(server)) {
        let ascii_server = domain_config.suffix_to_ascii(server);
        if (ascii_server == null || !dns_domain_valid(ascii_server))
            return { unsupported: "invalid DNS server host '" + server + "'" };
        server = ascii_server;
    }
    if (ip_only && !core_ip.valid_ip(server))
        return { unsupported: "Bootstrap DNS server must use an IP address" };

    let port = runtime_url.port(value);
    if (port != "" && (match(port, /^[0-9]+$/) == null || int(port) < 1 || int(port) > 65535))
        return { unsupported: "invalid DNS server port '" + port + "'" };

    let path = runtime_url.path(value);
    if (path != "" && scheme != "https" && scheme != "h3")
        return { unsupported: "DNS server paths are supported only for https:// and h3://" };

    return {
        type: DNS_URI_TYPES[scheme],
        server,
        server_port: port != "" ? int(port, 10) : DNS_URI_DEFAULT_PORTS[scheme],
        path
    };
}

function server_from_uri(tag_name, value, detour, ip_only) {
    let parsed = parse_server_uri(value, ip_only);
    if (parsed.unsupported)
        return parsed;

    let result = {
        type: parsed.type,
        tag: tag_name,
        server: parsed.server,
        server_port: parsed.server_port
    };
    if (parsed.path != "")
        result.path = parsed.path;
    if (!core_ip.valid_ip(parsed.server))
        result.domain_resolver = runtime_constants.BOOTSTRAP_DNS_SERVER_TAG;
    if (as_string(detour) != "")
        result.detour = as_string(detour);
    return result;
}

function add_server_group(result, values, canonical_tag, strategy, create_server) {
    if (length(values) == 1) {
        let server = create_server(canonical_tag, values[0]);
        if (server.unsupported)
            return server.unsupported;
        push(result, server);
        return "";
    }

    let tags = [];
    for (let i = 0; i < length(values); i++) {
        let tag_name = canonical_tag + "-" + as_string(i + 1);
        let server = create_server(tag_name, values[i]);
        if (server.unsupported)
            return server.unsupported;
        push(result, server);
        push(tags, tag_name);
    }
    push(result, {
        type: "fallback",
        tag: canonical_tag,
        servers: tags,
        strategy
    });
    return "";
}

function add_uri_server_group(result, values, canonical_tag, strategy, detour, ip_only) {
    return add_server_group(result, values, canonical_tag, strategy, function(tag_name, value) {
        return server_from_uri(tag_name, value, detour, ip_only);
    });
}

function encryption_error(settings) {
    let enabled = option(settings, "dns_encryption", "");
    // Existing URIs remain authoritative until the user explicitly selects a mode.
    if (settings?.dns_encryption == null)
        return "";
    if (enabled != "0" && enabled != "1")
        return "DNS encryption must be explicitly enabled or disabled";

    let protocol = enabled == "0" ? "udp" : option(settings, "dns_encrypted_protocol", "");
    if (enabled == "1" && protocol != "https" && protocol != "tls")
        return "Choose DoH (https) or DoT (tls)";

    for (let value in server_list(settings, "dns_server", "77.88.8.8")) {
        let parsed = parse_server_uri(value, false);
        if (parsed.unsupported)
            return parsed.unsupported;
        if (parsed.type != protocol)
            return "Main DNS protocol must match the explicit encryption setting (" + protocol + ")";
    }
    for (let value in server_list(settings, "bootstrap_dns_server", "77.88.8.8")) {
        let parsed = parse_server_uri(value, true);
        if (parsed.unsupported)
            return parsed.unsupported;
        if (parsed.type != "udp")
            return "Bootstrap DNS must use UDP";
    }
    return "";
}

function config(settings) {
    let unsupported = encryption_error(settings);
    if (unsupported != "")
        return { unsupported };
    let servers = [];
    let main_strategy = option(settings, "dns_main_fallback_strategy", "parallel");
    let bootstrap_strategy = option(settings, "dns_bootstrap_fallback_strategy", "parallel");
    let bootstrap_values = server_list(settings, "bootstrap_dns_server", "77.88.8.8");
    let main_values = server_list(settings, "dns_server", "77.88.8.8");
    let detour = detour_tag(settings);

    unsupported = add_uri_server_group(
        servers,
        bootstrap_values,
        runtime_constants.BOOTSTRAP_DNS_SERVER_TAG,
        bootstrap_strategy,
        "",
        true
    );
    if (unsupported != "")
        return { unsupported };

    unsupported = add_uri_server_group(
        servers,
        main_values,
        runtime_constants.DNS_SERVER_TAG,
        main_strategy,
        detour,
        false
    );
    if (unsupported != "")
        return { unsupported };

    return { servers };
}

return {
    add_uri_server_group,
    config,
    encryption_error,
    parse_server_uri,
    static_hosts,
    server_list
};
