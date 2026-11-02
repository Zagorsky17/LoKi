let url = require("core.url");
let ip = require("core.ip");

// POSIX regexes stop at NUL, so check it separately before the printable range.
function decoded_ascii(value) {
    if (index(replace(value, /%[0-9a-f]{2}/gi, ""), "%") >= 0)
        return null;
    let decoded = url.percent_decode(value);
    return index(decoded, chr(0)) < 0 && match(decoded, /^[ -~]*$/) != null ? decoded : null;
}

function base64_credentials(value) {
    let encoded = replace(replace(replace(value, /=+$/, ""), /-/g, "+"), /_/g, "/");
    if (match(encoded, /^[A-Za-z0-9+\/]+$/) == null || length(encoded) % 4 == 1)
        return null;
    let padded = encoded;
    while (length(padded) % 4 != 0)
        padded += "=";
    let decoded = b64dec(padded);
    if (decoded == null || index(decoded, chr(0)) >= 0 || match(decoded, /^[ -~]*$/) == null ||
        replace(b64enc(decoded), /=+$/, "") != encoded)
        return null;
    let colon = index(decoded, ":");
    return colon < 0 ? null : { username: substr(decoded, 0, colon), password: substr(decoded, colon + 1) };
}

// shortcut: complex/non-ASCII forms keep the native parser until equivalence is verified.
function outbound(uri) {
    if (length(uri) > 8192 || index(uri, chr(0)) >= 0 || match(uri, /[[:cntrl:]]/) != null)
        return null;
    let parts = match(uri, /^(https?|socks|socks4a?|socks5h?):\/\/([^?#]*)(\?[^#]*)?(#.*)?$/i);
    if (parts == null || parts[3] != null)
        return null;
    let scheme = lc(parts[1]);
    let http = scheme == "http" || scheme == "https";
    let address = match(parts[2], /^([^\/]*)(\/.*)?$/);
    if (address == null)
        return null;
    let authority = address[1];
    let path = address[2] ?? "";
    if ((!http && path != "") || match(path, /^[A-Za-z0-9._~!$&'()*+,;=:@%\/-]*$/) == null || decoded_ascii(path) == null)
        return null;

    let at = rindex(authority, "@");
    let host_port = at < 0 ? authority : substr(authority, at + 1);
    let endpoint = substr(host_port, 0, 1) == "["
        ? match(host_port, /^\[([0-9a-f:.]+)\](:([0-9]*))?$/i)
        : match(host_port, /^([a-z0-9_.-]+)(:([0-9]*))?$/i);
    if (endpoint == null || (substr(host_port, 0, 1) == "[" && !ip.valid_ip(endpoint[1])))
        return null;
    let port = endpoint[3] ?? "";
    if ((port == "" && !http) || length(port) > 5 || (port != "" && (int(port, 10) < 1 || int(port, 10) > 65535)))
        return null;
    if (http && at < 0 && port == "" && length(parts[4] ?? "") < 2)
        return null;

    let result = { type: http ? "http" : "socks", server: endpoint[1],
        server_port: port == "" ? (scheme == "https" ? 443 : 80) : int(port, 10) };
    if (at >= 0) {
        let raw = substr(authority, 0, at);
        if (match(raw, /^[A-Za-z0-9._~!$&'()*+,;=:%-]*$/) == null)
            return null;
        let colon = index(raw, ":");
        let username = decoded_ascii(colon < 0 ? raw : substr(raw, 0, colon));
        let password = decoded_ascii(colon < 0 ? "" : substr(raw, colon + 1));
        if (username == null || password == null)
            return null;
        if (scheme == "socks" && colon < 0 && username != "") {
            let credentials = base64_credentials(username);
            if (credentials == null)
                return null;
            username = credentials.username;
            password = credentials.password;
        }
        if (username != "")
            result.username = username;
        if (password != "")
            result.password = password;
    }
    if (!http)
        result.version = scheme == "socks4" ? "4" : scheme == "socks4a" ? "4a" : "5";
    else if (path != "")
        result.path = path;
    if (scheme == "https")
        result.tls = { enabled: true };
    return result;
}

return { outbound };
