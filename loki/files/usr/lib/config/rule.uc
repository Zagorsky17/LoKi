#!/usr/bin/env ucode

let ip = require("core.ip");
let domain_config = require("config.domain");

function as_string(value) {
    return value == null ? "" : "" + value;
}

function strip_list_comment(line) {
    line = replace(as_string(line), /[[:space:]]*\/\/.*$/, "");
    return replace(line, /[[:space:]]*#.*$/, "");
}

function text_list_values(value, separator_mode) {
    let result = [];
    separator_mode = as_string(separator_mode);

    for (let line in split(as_string(value), "\n")) {
        line = strip_list_comment(line);
        line = separator_mode == "comma-space"
            ? replace(line, /[ ,]/g, "\n")
            : replace(line, /,/g, "\n");

        for (let item in split(line, "\n")) {
            item = trim(replace(item, /\r/g, ""));
            if (item != "")
                push(result, item);
        }
    }

    return result;
}

function whitespace_fields(value) {
    let result = [];
    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function strip_repeated_domain_prefix(prefix, body) {
    let marker = prefix + ":";

    while (domain_config.ascii_lower(substr(body, 0, length(marker))) == marker)
        body = trim(substr(body, length(marker)));

    return body;
}

function prefixed_domain_kind_value(value) {
    value = trim(as_string(value));

    if (value == "")
        return null;

    let colon = index(value, ":");
    let prefix = "";
    let body = value;
    if (colon > 0) {
        let candidate = domain_config.ascii_lower(substr(value, 0, colon));
        if (candidate == "full" || candidate == "keyword" || candidate == "regex") {
            prefix = candidate;
            body = substr(value, colon + 1);
        }
        else {
            return null;
        }
    }

    body = trim(body);
    if (prefix != "")
        body = strip_repeated_domain_prefix(prefix, body);

    if (body == "")
        return null;

    if (prefix == "") {
        let normalized = domain_config.suffix_to_ascii(body);
        return normalized == null ? null : { kind: "domain_suffix", value: normalized };
    }

    if (prefix == "full") {
        let normalized = domain_config.suffix_to_ascii(body);
        return normalized == null ? null : { kind: "domain", value: normalized };
    }

    if (prefix == "keyword") {
        let normalized = domain_config.keyword_to_ascii(body);
        return normalized == null ? null : { kind: "domain_keyword", value: normalized };
    }

    let normalized = domain_config.regex_to_ascii(body);
    return normalized == null ? null : { kind: "domain_regex", value: normalized };
}

function normalize_domain_subnet_value(value, kind) {
    kind = as_string(kind);
    if (kind == "domains")
        return domain_config.suffix_to_ascii(value);
    if (kind == "subnets")
        return ip.valid_ip_or_cidr(value) ? value : null;

    die("unknown value kind '" + kind + "'");
}

const DESTINATION_KINDS = [ "domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr" ];

// A name whose last label is a number is a mistyped address, not a domain.
function destination_kind_value(value) {
    value = trim(as_string(value));
    if (ip.valid_ip_or_cidr(value))
        return { kind: "ip_cidr", value };

    let parsed = prefixed_domain_kind_value(value);
    if (parsed != null && (parsed.kind == "domain" || parsed.kind == "domain_suffix") &&
        match(parsed.value, /(^|\.)[0-9]+$/) != null)
        return null;

    return parsed;
}

// Callers ask for the same destinations several times in a row, so the last parse is kept.
let destinations_text = null;
let destinations_parsed = null;

function destination_conditions(text) {
    text = as_string(text);

    if (destinations_text != text) {
        let parsed = {};
        for (let kind in DESTINATION_KINDS)
            parsed[kind] = [];

        for (let item in text_list_values(text, "comma-space")) {
            let normalized = destination_kind_value(item);
            if (normalized != null)
                push(parsed[normalized.kind], normalized.value);
        }

        destinations_parsed = parsed;
        destinations_text = text;
    }

    let result = {};
    for (let kind in DESTINATION_KINDS)
        result[kind] = [ ...destinations_parsed[kind] ];
    return result;
}

function normalize_port_number_value(value) {
    value = trim(as_string(value));
    if (value == "" || match(value, /^[0-9]+$/) == null)
        return null;

    let number = int(value);
    return number >= 1 && number <= 65535 ? number : null;
}

function normalize_port_condition_value(value) {
    value = trim(as_string(value));
    if (value == "")
        return null;

    let dash = index(value, "-");
    if (dash < 0) {
        let number = normalize_port_number_value(value);
        return number == null ? null : as_string(number);
    }

    let start = normalize_port_number_value(substr(value, 0, dash));
    let end = normalize_port_number_value(substr(value, dash + 1));
    if (start == null || end == null || start > end)
        return null;

    return start == end ? as_string(start) : sprintf("%d-%d", start, end);
}

function append_unique_port(result, seen, item) {
    let normalized = normalize_port_condition_value(item);
    if (normalized == null || seen[normalized])
        return;

    seen[normalized] = true;
    push(result, normalized);
}

function rule_ports_csv_value(values) {
    let result = [];
    let seen = {};
    for (let item in values)
        append_unique_port(result, seen, item);
    return join(",", result);
}

return {
    text_list_values,
    normalize_port_condition_value,
    destination_kind_value,
    destination_conditions,
    normalize_domain_subnet_value,
    rule_ports_csv_value,
};
