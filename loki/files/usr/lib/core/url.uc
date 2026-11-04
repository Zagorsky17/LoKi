#!/usr/bin/env ucode

let common = require("core.common");

let as_string = common.as_string;

function first_index_any(value, needles, start) {
    value = as_string(value);
    start = int(start || 0);

    for (let i = start; i < length(value); i++) {
        let c = substr(value, i, 1);
        for (let needle in needles)
            if (c == needle)
                return i;
    }

    return -1;
}

function hex_digit_value(value) {
    value = ord(lc(as_string(value)));
    if (value >= 48 && value <= 57)
        return value - 48;
    if (value >= 97 && value <= 102)
        return value - 87;
    return -1;
}

function percent_decode(value) {
    value = as_string(value);
    let result = "";

    for (let i = 0; i < length(value); i++) {
        let c = substr(value, i, 1);
        if (c == "%") {
            let high = i + 1 < length(value) ? hex_digit_value(substr(value, i + 1, 1)) : -1;
            let low = i + 2 < length(value) ? hex_digit_value(substr(value, i + 2, 1)) : -1;
            if (high >= 0 && low >= 0) {
                result += chr(high * 16 + low);
                i += 2;
                continue;
            }
        }
        result += c;
    }
    return result;
}

function scheme(value) {
    value = as_string(value);
    let marker = index(value, "://");
    return marker >= 0 ? lc(substr(value, 0, marker)) : "";
}

function fragment(value) {
    value = as_string(value);
    let marker = index(value, "#");
    return marker >= 0 ? percent_decode(substr(value, marker + 1)) : "";
}

function strip_anchored_scheme(value) {
    value = as_string(value);
    let marker = index(value, "://");
    if (marker < 0)
        return value;

    let prefix = substr(value, 0, marker);
    if (index(prefix, "/") >= 0 || index(prefix, "?") >= 0)
        return value;

    return substr(value, marker + 3);
}

function strip_first_scheme_marker(value) {
    value = as_string(value);
    let marker = index(value, "://");
    return marker >= 0 ? substr(value, marker + 3) : value;
}

function authority(value) {
    value = strip_first_scheme_marker(value);
    let at = rindex(value, "@");
    if (at >= 0)
        value = substr(value, at + 1);

    let end = first_index_any(value, ["/", "?", "#"], 0);
    return end >= 0 ? substr(value, 0, end) : value;
}

function host(value) {
    let value_authority = authority(value);
    if (substr(value_authority, 0, 1) == "[") {
        let end = index(value_authority, "]");
        return end > 0 ? substr(value_authority, 1, end - 1) : value_authority;
    }

    let colon = index(value_authority, ":");
    if (colon < 0)
        return value_authority;

    return rindex(value_authority, ":") == colon ? substr(value_authority, 0, colon) : value_authority;
}

function port(value) {
    let value_authority = authority(value);
    if (substr(value_authority, 0, 1) == "[") {
        let end = index(value_authority, "]");
        if (end > 0 && substr(value_authority, end + 1, 1) == ":")
            return substr(value_authority, end + 2);
        return "";
    }

    let colon = index(value_authority, ":");
    if (colon < 0 || rindex(value_authority, ":") != colon)
        return "";

    return substr(value_authority, colon + 1);
}

function path(value) {
    value = strip_anchored_scheme(value);
    let slash = index(value, "/");
    value = slash >= 0 ? substr(value, slash) : "";

    let query = index(value, "?");
    if (query >= 0)
        value = substr(value, 0, query);

    return value;
}

function vmess_name(value) {
    let payload = substr(as_string(value), length("vmess://"));
    if (substr(payload, 0, 1) != "{") {
        let boundary = first_index_any(payload, [ "@", "?", "#" ], 0);
        if (boundary >= 0)
            payload = substr(payload, 0, boundary);
        payload = replace(replace(payload, /-/g, "+"), /_/g, "/");
        while (length(payload) % 4 != 0)
            payload += "=";
        try {
            payload = b64dec(payload);
        }
        catch (e) {
            payload = "";
        }
    }
    try {
        let parsed = json(payload);
        return type(parsed) == "object" ? as_string(parsed.ps || "") : "";
    }
    catch (e) {
        return "";
    }
}

// A VMess link's "ps", otherwise the fragment; getProxyUrlName() on the page reads it alike.
function link_name(value) {
    return scheme(value) == "vmess"
        ? (vmess_name(value) || fragment(value))
        : fragment(value);
}

return {
    percent_decode,
    scheme,
    fragment,
    link_name,
    host,
    port,
    path
};
