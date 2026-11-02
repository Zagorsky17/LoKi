let t = require("t");
let fixture = require("fixture");
let q = require("sbconfig");
let generator = require("singbox.generator");
let mask = require("diagnostics.mask");

function build(uri, extra) {
    fixture.seed({
        settings: { dns_server: [ "127.0.0.1" ], bootstrap_dns_server: [ "127.0.0.1" ], unified_delay: "0" },
        section: [
            { ".name": "hop", label: "Hop", action: "connection", outbound_jsons: [ '{"type":"direct","tag":"Direct"}' ] },
            { ".name": "main", label: "Main", action: "connection", destinations: "example.test" }
        ],
        connection_link: [ { ".name": "node", section: "main", name: "Node", uri, ...(extra ?? {}) } ]
    });
    return generator.build({ service_address: "127.0.0.1", local_prefixes: [] });
}

function outbound(uri) {
    return q.outbound(build(uri), "Main/Node");
}

t.test("plain HTTP links preserve escaped credentials, endpoint and the application tag", () => {
    let result = outbound("http://test%2Buser:synthetic%3Ap%40ss@proxy.example:8080#Other%20name");
    t.eq(result, { type: "http", tag: "Main/Node", server: "proxy.example", server_port: 8080,
        username: "test+user", password: "synthetic:p@ss" });
    let defaults = outbound("http://proxy.example#Named");
    t.eq([ defaults.type, defaults.server_port, defaults.tls ], [ "http", 80, null ]);
});

t.test("HTTPS keeps TLS enabled and the escaped path without moving an at sign into the host", () => {
    let result = outbound("https://user:synthetic-password@[::1]/con%2Fnect@target#Named");
    t.eq([ result.type, result.server, result.server_port ], [ "http", "::1", 443 ]);
    t.eq(result.tls, { enabled: true });
    t.eq(result.path, "/con%2Fnect@target");
    t.eq(result.password, "synthetic-password");
});

t.test("SOCKS versions and canonical base64 credentials become standard outbounds", () => {
    for (let scheme in [ "socks", "socks4", "socks4a", "socks5", "socks5h" ]) {
        let result = outbound(scheme + "://same:same@[::1]:1080#Named");
        t.eq([ result.type, result.server, result.server_port ], [ "socks", "::1", 1080 ]);
        t.eq([ result.username, result.password ], [ "same", "same" ]);
        t.eq(result.version, scheme == "socks4" ? "4" : scheme == "socks4a" ? "4a" : "5");
    }
    t.eq(outbound("socks5://127.0.0.1:01080#Named").server_port, 1080, "ports use decimal even with a leading zero");
    for (let credentials in [ b64enc("user:synthetic-password"), replace(b64enc("user:synthetic-password"), /=+$/, "") ]) {
        let result = outbound("socks://" + credentials + "@127.0.0.1:1080#Named");
        t.eq([ result.type, result.username, result.password ], [ "socks", "user", "synthetic-password" ]);
    }
});

t.test("base64 alphabets, decimal ports and explicit empty credentials keep their meaning", () => {
    for (let pair in [
        [ "dXNlcjo_Pz8=", "???" ],
        [ "dXNlcjo+Pj4=", ">>>" ],
        [ "dXNlcjo%2FPz8%3D", "???" ]
    ]) {
        let result = outbound("socks://" + pair[0] + "@127.0.0.1:1080#Named");
        t.eq([ result.type, result.username, result.password ], [ "socks", "user", pair[1] ]);
    }
    for (let port in [ 1, 65535 ])
        t.eq(outbound("http://proxy.example:" + port + "#Named").server_port, port);
    let empty = outbound("socks5://:@127.0.0.1:1080#Named");
    t.eq([ empty.type, empty.username, empty.password ], [ "socks", null, null ]);
});

t.test("the converter keeps cascades, fresh builds and masking of expanded secrets", () => {
    let first = build("https://private-user:synthetic-secret@proxy.example:8443#Named", { detour_section: "hop" });
    let second = build("socks5://127.0.0.1:1080#Named");
    t.eq(q.outbound(first, "Main/Node").detour, "Hop");
    t.eq(q.outbound(second, "Main/Node").detour, null);
    let masked = sprintf("%J", mask.sing_box_config(first));
    for (let secret in [ "private-user", "synthetic-secret", "proxy.example" ])
        t.excludes(masked, secret);
    t.eq(q.outbound(first, "Main/Node").password, "synthetic-secret", "masking must not mutate runtime settings");
});

t.test("raw, escaped and base64 NULs never turn a partial regex match into a standard endpoint", () => {
    for (let uri in [
        "socks5://127.0.0.1:1080#Named" + chr(0) + "hidden",
        "https://proxy.example:443#Named\nhidden",
        "socks5://127.0.0.1:1080#Named" + chr(127),
        "https://user:synthetic%00secret@proxy.example:443#Named",
        "socks://" + b64enc("user:synthetic" + chr(0) + "secret") + "@proxy.example:1080#Named"
    ])
        t.eq([ outbound(uri).type, outbound(uri).link ], [ "parser", uri ]);
});

t.test("complex and malformed links retain the exact native parser input", () => {
    let oversized = "";
    for (let i = 0; i < 8200; i++)
        oversized += "x";
    for (let uri in [
        "vless://id@proxy.example:443?security=reality&pbk=synthetic-key#Named",
        "https://user:synthetic-secret@proxy.example:443?fp=chrome#Named",
        "socks://dXNlcjp%FF@proxy.example:1080#Named",
        "http://user:synthetic%Q0@proxy.example:8080#Named",
        "http://user:synthetic%00secret@proxy.example:8080#Named",
        "http://user:synthetic%0Asecret@proxy.example:8080#Named",
        "socks5://127.0.0.1:1080" + chr(0) + "#Named",
        "https://proxy.example/con%00nect#Named",
        "http://proxy.example:65536#Named", "http://proxy.example:0#Named", "http://proxy.example:bad#Named",
        "http://proxy.example/", "socks5://proxy.example#Named", "socks5://[::1:1080#Named",
        "socks5://user:pa/ss@proxy.example:1080#Named",
        "socks5://user:pass@сайт.рф:1080#Named", "http://user:pass@proxy.example:8080/путь#Named",
        "socks5://127.0.0.1:1080#" + oversized
    ]) {
        let result = outbound(uri);
        t.eq([ result.type, result.link ], [ "parser", uri ]);
        t.eq([ result.username, result.password, result.tls ], [ null, null, null ]);
    }
});

t.done();
