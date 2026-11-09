let t = require("t");
let v = require("validation");
let fixture = require("fixture");
let generator = require("singbox.generator");
let headers = require("singbox.subscription_headers");
let urltest = require("singbox.urltest");
let nft = require("nft.apply");

function subscription(url) {
    return { section: [ { ".name": "main", action: "connection" } ],
        subscription_url: [ { ".name": "sub", section: "main", tag: "Feed", url } ] };
}
function link(uri) {
    return { section: [ { ".name": "main", action: "connection" } ],
        connection_link: [ { ".name": "node", section: "main", name: "Node", uri } ] };
}

t.test("local subscriptions require canonical nonempty path segments", () => {
    v.accepts(subscription("/etc/loki/subs/feed.txt"));
    for (let path in [ "/etc/../etc/shadow", "/etc/./feed", "/etc//feed", "//etc/feed", "/etc/feed/", "/etc/feed" + chr(0) + "hidden" ])
        v.refuses(subscription(path), "Invalid subscription source");
});

t.test("HTTP subscription URLs reject controls and excessive input before parsing", () => {
    v.accepts(subscription("https://example.test/sub"));
    for (let suffix in [ chr(0) + "hidden", chr(1), chr(127), sprintf("%8192s", "x") ])
        v.refuses(subscription("https://example.test/sub" + suffix), "Invalid subscription source");
});

t.test("manual links have the same raw input boundary for every parser", () => {
    for (let uri in [ "vless://id@example.test:443" + chr(0), "custom://example.test/" + chr(1),
        "custom://example.test/" + chr(127), "custom://" + sprintf("%8192s", "x"), "\tvless://id@example.test:443" ]) {
        v.refuses(link(uri), "Invalid connection link");
        fixture.seed(v.with_dns(link(uri)));
        t.throws(() => generator.build({ controller_secret: fixture.CONTROLLER_SECRET, local_prefixes: [] }));
    }
});

t.test("HTTP header field values reject every control except horizontal tab", () => {
    t.eq(headers.parse_header_line("X-Test: a\tb").valid, true);
    for (let code = 0; code < 32; code++)
        if (code != 9) t.eq(headers.parse_header_line("X-Test: a" + chr(code) + "b").valid, false, "control " + code);
    t.eq(headers.parse_header_line("X-Test: a" + chr(127) + "b").valid, false);
    t.eq(headers.parse_header_line("X-Test: " + sprintf("%8193s", "x")).valid, false);
});

t.test("unsupported expressions cannot silently change group membership", () => {
    t.throws(() => urltest.regex_matching_tag_array([ "node" ], {}, [ "\\pL" ]));
});

t.test("interface names cannot add nft syntax", () => {
    for (let name in [ "x};drop", "x\"", "x\\y", "x" + chr(0) + "y" ]) {
        fixture.seed({ settings: { source_network_interfaces: [ name ] } });
        t.throws(() => nft.build());
    }
});

t.done();
