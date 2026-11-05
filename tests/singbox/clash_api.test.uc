let t = require("t");
let stub = require("stub");
let fs = require("fs");
let fixture = require("fixture");
let repo = require("repo");
let cli = require("service.cli");
let clash = require("singbox.clash_api");
let controller = require("controller").start();
let socket = require("socket");
let gateway_secret = require("service.gateway_secret");
let private_secret = fixture.CONTROLLER_SECRET;
gateway_secret.load = () => private_secret;
let redirect = require("controller").redirect(controller.path);

let dir = stub.tmpdir();

function numbers(count) {
    let result = [];
    for (let i = 0; i < count; i++)
        push(result, i);
    return result;
}

function config(address, secret) {
    redirect.unavailable = address == "127.0.0.1:1";
    let path = dir + "/config.json";
    let clash_api = address == null ? null : { external_controller: address, secret: secret ?? "local-secret" };
    fs.writefile(path, sprintf("%J", { experimental: clash_api == null ? {} : { clash_api } }));
    fixture.seed({ settings: { config_path: path, yacd_secret_key: "stale-secret" } });
}

function call(argv) {
    let result = stub.capture(() => cli.main(argv, "/lib"));
    return { status: result.result, reply: result.stdout == "" ? null : json(result.stdout), stderr: result.stderr };
}

// The requests the controller received from here on, each as { line, headers, body }.
let seen = 0;
function received() {
    let all = controller.requests();
    let result = map(slice(all, seen), (text) => {
        let end = index(text, "\r\n\r\n");
        let lines = split(substr(text, 0, end), "\r\n");
        let headers = {};
        for (let line in slice(lines, 1))
            headers[lc(substr(line, 0, index(line, ":")))] = trim(substr(line, index(line, ":") + 1));
        return { line: lines[0], headers, body: substr(text, end + 4) };
    });
    seen = length(all);
    return result;
}

t.test("an allowlisted request reaches the controller as asked, with the secret loki-core runs with", () => {
    config(controller.endpoint);
    controller.reply({ status: 200, body: "{\"url\":\"vless://id@example.com:443\"}" });
    received();
    let result = call([ "clash_api", "GET", "/proxies/provider%2Fnode/link" ]);
    t.eq([ result.status, result.reply.status, json(result.reply.body).url ], [ 0, 200, "vless://id@example.com:443" ]);
    let request = received()[0];
    t.eq(request.line, "GET /proxies/provider%2Fnode/link HTTP/1.0", "the path goes as the page wrote it");
    t.eq([ request.headers.host, request.headers.authorization ], [ "loki-controller", "Bearer " + fixture.CONTROLLER_SECRET ]);

    config(controller.endpoint, "");
    call([ "clash_api", "GET", "/proxies" ]);
    t.eq(received()[0].headers.authorization, "Bearer " + fixture.CONTROLLER_SECRET, "stale configuration cannot disable the private credential");
});

t.test("the pages' own requests pass, with their methods and bodies", () => {
    config(controller.endpoint);
    controller.reply({ status: 204 });
    received();
    for (let request in [
        [ "GET", "/providers/proxies", "" ],
        [ "GET", "/proxies/proxy-out/delay?url=https%3A%2F%2Flatency.example%2Fgenerate_204&timeout=5000", "" ],
        [ "GET", "/proxies/main-out/exit?timeout=8000", "" ],
        [ "PUT", "/proxies/main-out", "{\"name\":\"main-1-out\"}" ],
        [ "PUT", "/proxies/fallback-out", "{\"name\":\"\"}" ],
        [ "PUT", "/providers/rules", "" ],
        [ "PUT", "/providers/proxies/main%2Fsub1", "" ],
        [ "DELETE", "/connections/abc-123", "" ]
    ]) {
        let result = call([ "clash_api", ...request ]);
        t.eq([ result.status, result.reply?.status ], [ 0, 204 ], join(" ", request));
    }
    let requests = received();
    t.eq(map(requests, (request) => request.line), [
        "GET /providers/proxies HTTP/1.0",
        "GET /proxies/proxy-out/delay?url=https%3A%2F%2Flatency.example%2Fgenerate_204&timeout=5000 HTTP/1.0",
        "GET /proxies/main-out/exit?timeout=8000 HTTP/1.0",
        "PUT /proxies/main-out HTTP/1.0", "PUT /proxies/fallback-out HTTP/1.0",
        "PUT /providers/rules HTTP/1.0", "PUT /providers/proxies/main%2Fsub1 HTTP/1.0", "DELETE /connections/abc-123 HTTP/1.0"
    ]);
    t.eq([ requests[3].body, requests[3].headers["content-type"], requests[3].headers["content-length"] ],
        [ "{\"name\":\"main-1-out\"}", "application/json", "21" ]);
    t.eq([ requests[5].body, requests[5].headers["content-length"] ], [ "", null ], "a request without a body sends none");
});

t.test("the reply is handed back as the controller sent it, its status and its body", () => {
    config(controller.endpoint);
    let large = sprintf("{\"proxies\":{%s}}", join(",", map(numbers(4000), (i) => sprintf("\"node-%d\":{\"type\":\"VLESS\",\"history\":[]}", i))));
    controller.reply({ status: 200, body: large });
    t.eq(clash.request("GET", "/proxies", ""), { status: 200, body: large }, "a body larger than one read");
    controller.reply({ status: 404, body: "{\"message\":\"Resource not found\"}" });
    t.eq(clash.request("GET", "/proxies", ""), { status: 404, body: "{\"message\":\"Resource not found\"}" }, "an error status is the controller's answer, not a failure");
    controller.reply({ raw: "HTTP/1.1 204 No Content\r\nDate: Thu, 22 Oct 2026 10:00:00 GMT\r\n\r\n" });
    t.eq(clash.request("PUT", "/proxies/main-out", "{\"name\":\"x\"}"), { status: 204, body: "" });
    received();
});

t.test("a controller that is not there, answers no HTTP or drops the reply fails the request, naming it", () => {
    for (let reply in [ { raw: "" }, { raw: "SSH-2.0-dropbear\r\n" }, { raw: "HTTP/1.0 200 OK\r\nContent-Type: application/json" } ]) {
        config(controller.endpoint);
        controller.reply(reply);
        let result = call([ "clash_api", "GET", "/proxies" ]);
        t.eq([ result.status, result.reply ], [ 1, null ], reply.raw);
        t.contains(result.stderr, "Clash API request failed: GET /proxies");
    }
    config("127.0.0.1:1");
    let result = call([ "clash_api", "GET", "/proxies" ]);
    t.contains(result.stderr, "Clash API request failed: GET /proxies");
    received();
});

t.test("a reply that does not come in time is given up at the deadline", () => {
    config(controller.endpoint);
    let api = { endpoint: controller.endpoint, secret: "" };
    controller.reply({ status: 200, body: "{}", delay_ms: 3000 });
    let start = clock(true);
    t.eq(clash.exchange(api, "GET", "/providers/rules/events?since=1", { seconds: 1 }), false);
    let waited = clock(true)[0] - start[0];
    t.ok(waited >= 0 && waited < 3, "waited " + waited + " s");
    controller.reply({ status: 200, body: "{}" });
    received();
});

t.test("a reply is decoded as it arrives when the caller asks for it", () => {
    config(controller.endpoint);
    let api = { endpoint: controller.endpoint, secret: "" };
    let body = sprintf("{\"revision\":3,\"providers\":{%s}}", join(",", map(numbers(3000), (i) => sprintf("\"p%d\":{\"revision\":%d}", i, i))));
    controller.reply({ status: 200, body });
    let reply = clash.exchange(api, "GET", "/providers/rules", { seconds: 10, decode: json });
    t.eq([ reply.status, reply.value.revision, length(keys(reply.value.providers)), reply.body ], [ 200, 3, 3000, null ]);
    controller.reply({ status: 200, body: "{\"revision\":" });
    t.eq(clash.exchange(api, "GET", "/providers/rules", { seconds: 10, decode: json }), { status: 200, value: null }, "a body cut short decodes to nothing");
    received();
});

t.test("anything else is refused before it reaches the controller", () => {
    config(controller.endpoint);
    controller.reply({ status: 204 });
    received();
    for (let request in [ [ "GET", "/configs", "" ], [ "PUT", "/configs", "{\"mode\":\"global\"}" ], [ "POST", "/proxies", "{\"name\":\"x\"}" ],
        [ "GET", "/proxies/../configs", "" ], [ "PUT", "/proxies/main-out", "{\"name\":\"x\",\"extra\":1}" ], [ "PUT", "/proxies/main-out", "not-json" ],
        [ "GET", "/proxies/main-out/delay?url=x&timeout=abc", "" ], [ "DELETE", "/connections", "{\"all\":true}" ],
        [ "GET", "/proxies/main-out/exit", "" ], [ "GET", "/proxies/main-out/exit?timeout=5000&url=https%3A%2F%2Fexample.com", "" ],
        [ "GET", "/group/main/exit?timeout=5000", "" ], [ "GET", "/tailscale?tag=x", "" ], [ "PUT", "/tailscale", "" ],
        [ "PUT", "/tailscale/tailnet/ping?address=100.64.0.2&timeout=5000", "" ],
        [ "PUT", "/providers/rules", "{\"name\":\"geosite\"}" ], [ "PUT", "/providers/rules/geosite", "" ],
        [ "GET", "/proxies HTTP/1.0\r\nX-Injected: 1", "" ] ]) {
        let result = call([ "clash_api", ...request ]);
        t.eq([ result.status, result.reply ], [ 1, null ], join(" ", request));
        t.contains(result.stderr, "not allowlisted");
    }
    t.eq(received(), []);
});

t.test("the controller always uses its private Unix socket and the boot credential, ignoring UCI and generated endpoint data", () => {
    for (let address in [ "192.168.1.1:9090", "0.0.0.0:9090", "[::]:9090", "[fd00::1]:9090", "attacker.example:443", null ]) {
        config(address, "generated-secret");
        t.eq(clash.controller(), { endpoint: "/tmp/loki/controller.sock", secret: private_secret }, "fixed private controller");
    }
    let original = gateway_secret.load;
    let failure;
    gateway_secret.load = () => die("Private LoKi controller credential is unsafe or unavailable");
    try { clash.request("GET", "/proxies", ""); }
    catch (e) { failure = e; }
    gateway_secret.load = original;
    t.contains(failure?.message, "Private LoKi controller credential");
    t.eq(received(), [], "an unavailable private credential never permits an unauthenticated request");
});

t.test("the summary carries the totals and the count, never the connection list", () => {
    config(controller.endpoint);
    controller.reply({ status: 200, body: "{\"downloadTotal\":10,\"uploadTotal\":20,\"memory\":30,\"connections\":[{\"id\":\"a\",\"metadata\":{}},{\"id\":\"b\"}]}" });
    received();
    let result = call([ "clash_summary" ]);
    t.eq(json(result.reply.body), { downloadTotal: 10, uploadTotal: 20, connections: 2 });
    t.eq(received()[0].line, "GET /connections HTTP/1.0");
});

t.test("read deadlines are short while probes through an outbound and updates retain their budget", () => {
    for (let pair in [
        [ "GET", "/proxies", 5 ],
        [ "GET", "/connections", 5 ],
        [ "GET", "/group/main/delay?url=https%3A%2F%2Fexample.com&timeout=40000", 50 ],
        [ "GET", "/proxies/main-out/exit?timeout=8000", 18 ],
        [ "PUT", "/providers/rules", 60 ]
    ])
        t.eq(clash.budget(pair[0], pair[1]), pair[2], pair[0] + " " + pair[1]);
});

t.test("the transport loads nothing beyond core, the constants and socket", () => {
    let probe = stub.tmpdir() + "/probe.uc";
    fs.writefile(probe, "require(\"singbox.clash_api\");\nprint(join(\" \", keys(global.modules)), \"\\n\");\n");
    let pipe = fs.popen("ucode -L '" + repo.path("loki/files/usr/lib") + "' '" + probe + "'", "r");
    let loaded = split(trim(pipe.read("all")), " ");
    pipe.close();
    t.contains(loaded, "singbox.clash_api");
    t.eq(filter(loaded, (name) => substr(name, 0, 5) != "core." &&
        index([ "fs", "socket", "singbox.constants", "singbox.clash_api" ], name) < 0), []);
});

t.test("controller headers are bounded before body decoding, including an unterminated header", () => {
    let api = { endpoint: controller.endpoint, secret: "" };
    let limit = 65536;
    let prefix = "HTTP/1.0 200 OK\r\nX-Padding: ";
    let suffix = "\r\n\r\n";
    let header = prefix + sprintf("%" + (limit - length(prefix) - length(suffix)) + "s", "") + suffix;
    t.eq(length(header), limit);
    controller.reply({ raw: header + "{}" });
    t.eq(clash.exchange(api, "GET", "/proxies", { seconds: 5 }), { status: 200, body: "{}" });
    for (let ending in [ suffix, "" ]) {
        let decoded = false;
        controller.reply({ raw: prefix + sprintf("%65536s", "") + ending + "{}" });
        let result = clash.exchange(api, "GET", "/providers/rules", { seconds: 5,
            decode: () => { decoded = true; return {}; } });
        t.ok(result == null, "oversized headers must fail without an apparent HTTP success");
        t.ok(!decoded, "body decoder must not run after a failed header check");
    }
    received();
});

t.test("buffered controller bodies have an actual byte limit and the next request still works", () => {
    let api = { endpoint: controller.endpoint, secret: "" };
    let limit = 4 * 1024 * 1024;
    let body = sprintf("%" + limit + "s", "");
    t.eq(length(body), limit);
    controller.reply({ status: 200, body });
    let boundary = clash.exchange(api, "GET", "/connections", { seconds: 5 });
    t.eq([ boundary?.status, length(boundary?.body ?? "") ], [ 200, limit ]);
    controller.reply({ raw: "HTTP/1.0 200 OK\r\nContent-Length: 1\r\n\r\n" + body + "x" });
    t.ok(clash.exchange(api, "GET", "/connections", { seconds: 5 }) == null,
        "actual body bytes must be bounded even when Content-Length understates them");
    controller.reply({ status: 200, body: "{\"connections\":[]}" });
    t.eq(clash.exchange(api, "GET", "/connections", { seconds: 5 }), { status: 200, body: "{\"connections\":[]}" });
    received();
});

t.test("the buffered-body bound does not truncate a rule-provider decoder stream", () => {
    let api = { endpoint: controller.endpoint, secret: "" };
    let bytes = 4 * 1024 * 1024 + 1;
    controller.reply({ status: 200, body: sprintf("%" + bytes + "s", "") });
    let reply = clash.exchange(api, "GET", "/providers/rules", { seconds: 5, decode: (reader) => {
        let total = 0;
        for (let chunk = reader.read(); chunk != ""; chunk = reader.read())
            total += length(chunk);
        return total;
    } });
    t.eq(reply, { status: 200, value: bytes });
    received();
});

t.test("unsafe socket metadata is refused before any connection or credential transmission", () => {
    config(controller.endpoint);
    let original = { lstat: fs.lstat, connect: socket.connect };
    let attempts = 0;
    socket.connect = () => { attempts++; die("unsafe socket reached connect"); };
    let before = original.lstat("/tmp/loki/controller.sock");
    try {
        for (let extra in [ { type: "link" }, { type: "file" }, { uid: before.uid + 1 }, { nlink: 2 }, { mode: 0666 } ]) {
            fs.lstat = (path) => path == "/tmp/loki/controller.sock" ? { ...before, ...extra } : original.lstat(path);
            t.eq(clash.exchange(clash.controller(), "GET", "/proxies", { seconds: 1 }), null);
        }
    }
    catch (e) { fs.lstat = original.lstat; socket.connect = original.connect; die(e.message); }
    fs.lstat = original.lstat;
    socket.connect = original.connect;
    t.eq(attempts, 0);
});

t.test("peer identity and post-connect metadata are checked before sending the bearer", () => {
    config(controller.endpoint);
    let original = { lstat: fs.lstat, connect: socket.connect };
    let uid = fs.stat("/proc/self").uid;
    try {
        for (let peer in [ null, {}, { uid: uid + 1, pid: 1 }, { uid, pid: 0 }, { uid, pid: false }, "throw", "changed-inode" ]) {
            let closed = 0;
            let sent = 0;
            let stats = 0;
            fs.lstat = (path) => {
                let value = original.lstat(path);
                if (path == "/tmp/loki/controller.sock" && ++stats > 1 && peer == "changed-inode")
                    value.inode++;
                return value;
            };
            socket.connect = (host, port) => {
                t.eq(host, { path: "/tmp/loki/controller.sock" });
                t.eq(port, null);
                return {
                    getopt: () => {
                        if (peer == "throw") die("synthetic credential inspection failure");
                        return peer == "changed-inode" ? { uid, pid: 1 } : peer;
                    },
                    send: () => { sent++; return 1; },
                    close: () => { closed++; }
                };
            };
            t.eq(clash.exchange(clash.controller(), "GET", "/proxies", { seconds: 1 }), null);
            t.eq([ sent, closed ], [ 0, 1 ], "no credential bytes before a verified peer");
        }
    }
    catch (e) { fs.lstat = original.lstat; socket.connect = original.connect; die(e.message); }
    fs.lstat = original.lstat;
    socket.connect = original.connect;
});

t.done();
