// Modified for LoKi on 2026-11-03: bound headers and buffered controller responses.
// The Clash API transport the pages fall back to when the browser cannot reach the controller.
// It is called every couple of seconds, so it loads nothing beyond core, the constants and socket.

let socket = require("socket");
let common = require("core.common");
let singbox_constants = require("singbox.constants");
let fs = require("fs");
let storage = require("core.cache_path");

const CONTROLLER_SOCKET = singbox_constants.CLASH_API_CONTROLLER_SOCKET;
const MAX_HEADER_BYTES = 65536;
const MAX_BUFFERED_BODY_BYTES = 4 * 1024 * 1024;

// Browser-controlled settings never choose the RPC transport destination or its credential.
function controller() {
    return { endpoint: CONTROLLER_SOCKET, secret: require("service.gateway_secret").load() };
}

function private_connection(seconds) {
    storage.validate({ cache_path: CONTROLLER_SOCKET + ".owner" });
    let uid = fs.stat("/proc/self")?.uid;
    let before = fs.lstat(CONTROLLER_SOCKET);
    if (uid == null || before?.type != "socket" || before.uid != uid || before.nlink != 1 || (before.mode & 0777) != 0600)
        return null;
    let conn = socket.connect({ path: CONTROLLER_SOCKET }, null, { socktype: socket.SOCK_STREAM }, seconds * 1000);
    if (conn == null)
        return null;
    let valid = false;
    try {
        let peer = conn.getopt(socket.SOL_SOCKET, socket.SO_PEERCRED);
        let after = fs.lstat(CONTROLLER_SOCKET);
        storage.validate({ cache_path: CONTROLLER_SOCKET + ".owner" });
        valid = type(peer?.uid) == "int" && peer.uid == uid && type(peer.pid) == "int" && peer.pid > 0 &&
            after != null && after.inode == before.inode && after.dev?.major == before.dev?.major &&
            after.dev?.minor == before.dev?.minor && after.uid == before.uid && after.mode == before.mode &&
            after.nlink == before.nlink;
    }
    catch (e) {}
    if (!valid) {
        conn.close();
        return null;
    }
    return conn;
}

function segments(path, prefix) {
    if (substr(path, 0, length(prefix)) != prefix)
        return null;
    let rest = substr(path, length(prefix));
    let result = rest == "" ? [] : split(rest, "/");
    for (let segment in result)
        if (segment == "" || segment == "." || segment == ".." || match(segment, /[\/?#]/))
            return null;
    return result;
}

// Only what the dashboard and monitoring drive, so the transport is no general control-plane client.
function allowed(method, path, body) {
    if (path == "" || length(path) > 4096 || index(path, chr(0)) >= 0 || match(path, /[[:cntrl:] ]/))
        return false;

    if (method == "GET") {
        if (body != "")
            return false;
        if (path == "/proxies" || path == "/providers/proxies" || path == "/connections")
            return true;
        let query = index(path, "?");
        if (query < 0) {
            let link = segments(path, "/proxies/");
            return length(link) == 2 && link[1] == "link";
        }
        let target = segments(substr(path, 0, query), "/");
        if (length(target) != 3)
            return false;
        if (target[0] == "proxies" && target[2] == "exit")
            return match(substr(path, query), /^\?timeout=[0-9]+$/) != null;
        return target[2] == "delay" && (target[0] == "proxies" || target[0] == "group") &&
            match(substr(path, query), /^\?url=[^&]+&timeout=[0-9]+$/) != null;
    }

    if (method == "DELETE")
        return body == "" && (path == "/connections" || length(segments(path, "/connections/")) == 1);

    if (method == "PUT") {
        // A refresh of every rule provider, and of one proxy provider.
        if (path == "/providers/rules" || length(segments(path, "/providers/proxies/")) == 1)
            return body == "";
        // A selector or fallback pin; an empty name unpins.
        if (length(segments(path, "/proxies/")) != 1)
            return false;
        let payload = common.parse_json(body);
        return type(payload) == "object" && length(keys(payload)) == 1 && type(payload.name) == "string";
    }

    return false;
}

// The chunks of a reply until the controller closes; "" there, and once the deadline passed or
// the connection broke, which the flags then tell apart.
function receiver(conn, deadline) {
    let state = { timed_out: false, broken: false };
    state.read = function() {
        let left = deadline - common.monotonic_ms();
        let ready = left > 0 ? socket.poll(left, conn) : null;
        if (left <= 0 || ready?.[0]?.[1] === 0) {
            state.timed_out = true;
            return "";
        }
        let chunk = ready == null ? null : conn.recv(16384);
        if (chunk == null)
            state.broken = true;
        return chunk ?? "";
    };
    return state;
}

function send_all(conn, data) {
    while (length(data) > 0) {
        let sent = conn.send(data);
        if (sent == null || sent <= 0)
            return false;
        data = substr(data, sent);
    }
    return true;
}

// One request in HTTP/1.0, which the controller answers without chunks and ends by closing.
// { status, body }, or { status, value } with decode(reader) taking the body as it arrives;
// false once options.seconds ran out, null when nothing answered in HTTP.
function exchange(api, method, path, options) {
    let deadline = common.monotonic_ms() + options.seconds * 1000;
    if (api.endpoint != CONTROLLER_SOCKET)
        return null;
    let conn = private_connection(options.connect_seconds ?? 3);
    if (conn == null)
        return null;

    let body = options.body ?? "";
    let head = method + " " + path + " HTTP/1.0\r\nHost: loki-controller\r\n";
    if (api.secret != "")
        head += "Authorization: Bearer " + api.secret + "\r\n";
    if (body != "")
        head += "Content-Type: application/json\r\nContent-Length: " + length(body) + "\r\n";
    let reader = receiver(conn, deadline);
    let reply = null;
    if (send_all(conn, head + "\r\n" + body)) {
        let parts = [];
        let received = "";
        let end = -1;
        while (end < 0) {
            let chunk = reader.read();
            if (chunk == "")
                break;
            received += chunk;
            end = index(received, "\r\n\r\n");
            if ((end < 0 ? length(received) : end + 4) > MAX_HEADER_BYTES) {
                conn.close();
                return null;
            }
        }
        let status = end < 0 ? null : match(received, /^HTTP\/1\.[01] ([1-5][0-9][0-9])[ \r]/)?.[1];
        let rest = end < 0 ? "" : substr(received, end + 4);
        if (status != null && options.decode != null) {
            let value = null;
            try {
                value = options.decode({ read: () => { let chunk = rest; rest = ""; return chunk != "" ? chunk : reader.read(); } });
            }
            catch (e) {
            }
            reply = { status: int(status), value };
        }
        else if (status != null) {
            let bytes = length(rest);
            if (bytes > MAX_BUFFERED_BODY_BYTES) {
                conn.close();
                return null;
            }
            push(parts, rest);
            for (let chunk = reader.read(); chunk != ""; chunk = reader.read()) {
                bytes += length(chunk);
                if (bytes > MAX_BUFFERED_BODY_BYTES) {
                    conn.close();
                    return null;
                }
                push(parts, chunk);
            }
            reply = { status: int(status), body: join("", parts) };
        }
    }
    conn.close();
    if (reader.timed_out)
        return false;
    return reader.broken ? null : reply;
}

// How long a request may take: a probe through an outbound runs as long as it asked for.
function budget(method, path) {
    let probe = match(path, /\/(delay\?url=[^&]+&|exit\?|ping\?address=[^&]+&)timeout=([0-9]+)$/);
    return method != "GET" ? 60 : probe ? min(60, int((int(probe[2]) + 999) / 1000) + 10) : 5;
}

// { status, body } exactly as the controller answered, or dies with the reason.
function request(method, path, body) {
    method = uc(method ?? "");
    path = path ?? "";
    body = body ?? "";
    if (!allowed(method, path, body))
        die("Clash API request is not allowlisted: " + method + " " + path);

    let reply = exchange(controller(), method, path, { body, seconds: budget(method, path) });
    if (!reply)
        die("Clash API request failed: " + method + " " + path);
    return reply;
}

// The three numbers the Dashboard reads; the full snapshot would exceed rpcd's limit of about 256 KB.
function summary() {
    let response = request("GET", "/connections", "");
    let payload = response.status >= 200 && response.status < 300 ? common.parse_json(response.body) : null;
    if (type(payload) != "object")
        return response;
    return {
        status: response.status,
        body: sprintf("%J", {
            downloadTotal: payload.downloadTotal || 0,
            uploadTotal: payload.uploadTotal || 0,
            connections: type(payload.connections) == "array" ? length(payload.connections) : 0
        })
    };
}

return { controller, allowed, exchange, budget, request, summary };
