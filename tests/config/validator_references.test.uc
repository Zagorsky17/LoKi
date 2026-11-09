let t = require("t");
let v = require("validation");
let fixture = require("fixture");

function section(name, action, extra) {
    return { ".name": name, enabled: "1", action, ...(extra ?? {}) };
}

function served(names) {
    let result = [];
    for (let name in names)
        push(result, ...fixture.links(name, [ "socks://127.0.0.1:1080#one" ]));
    return result;
}

function through(name, target) {
    return fixture.links(name, [ "socks://127.0.0.1:1080#one" ], { detour_section: target });
}


t.test("a cascade points at another enabled Connection section with servers", () => {
    let source = section("source", "connection");
    let target = section("target", "connection");
    v.accepts({ section: [ source, target ], connection_link: [ ...through("source", "target"), ...served([ "target" ]) ] });
    v.refuses({ section: [ source ], connection_link: through("source", "missing") },
        "The cascade of link 'one' in section 'source' points to section 'missing', which does not exist");
    v.refuses({ section: [ source, { ...target, enabled: "0" } ], connection_link: [ ...through("source", "target"), ...served([ "target" ]) ] },
        "points to section 'target', which is disabled");
    v.refuses({ section: [ source, section("target", "zapret") ], connection_link: through("source", "target") },
        "points to section 'target', whose action is 'zapret'");
    v.refuses({ section: [ source, target ], connection_link: through("source", "target") },
        "points to section 'target', which has no servers");
    v.refuses({ section: [ source ], connection_link: through("source", "source") },
        "The cascade of link 'one' in section 'source' cannot point to its own section");
    v.accepts({ section: [ section("source", "bypass"), target ], connection_link: [ ...through("source", "missing"), ...served([ "target" ]) ] });
    v.accepts({ section: [ { ...source, enabled: "0" }, target ], connection_link: [ ...through("source", "missing"), ...served([ "target" ]) ] });
});

t.test("a subscription names its cascade target", () => {
    let sections = [ section("source", "connection"), section("target", "connection") ];
    v.refuses({ section: sections, connection_link: served([ "source" ]),
        subscription_url: [ { ".name": "sub", section: "source", url: "https://sub.example/s", tag: "sub1", detour_section: "target" } ] },
        "The cascade of subscription 'sub1' in section 'source' points to section 'target', which has no servers");

});

t.test("a cascade never leads back to its own section", () => {
    let first = section("first", "connection");
    let second = section("second", "connection");
    let third = section("third", "connection");
    v.refuses({ section: [ first, second ], connection_link: [ ...through("first", "second"), ...through("second", "first") ] },
        "loops back through section 'second'");
    v.refuses({ section: [ first, second, third ],
        connection_link: [ ...through("first", "second"), ...through("second", "third"), ...through("third", "first") ] },
        "loops back through section 'second'");
    v.accepts({ section: [ first, second, third ],
        connection_link: [ ...through("first", "third"), ...through("second", "third"), ...served([ "third" ]) ] });
});

t.test("no reference may lead to a section without servers", () => {
    let empty = section("empty", "connection");
    let dns = section("dns", "dns", { dns_server: [ "8.8.8.8" ], destinations: "example.org", dns_detour_enabled: "1", dns_detour_section: "empty" });
    for (let data in [
        { settings: { dns_detour_enabled: "1", dns_detour_section: "empty" }, section: [ empty ] },
        { section: [ empty, dns ] },
        { settings: { download_lists_via_proxy: "1", download_lists_via_proxy_section: "empty" }, section: [ empty ] },
    ])
        v.refuses(data, "points to section 'empty', which has no servers");

});

function download_through(target, sections) {
    return {
        settings: { download_lists_via_proxy: "1", download_lists_via_proxy_section: target },
        section: sections
    };
}

t.test("downloads go through an enabled section with servers", () => {
    v.accepts({ ...download_through("proxy", [ section("proxy", "connection") ]), connection_link: served([ "proxy" ]) });
    v.accepts(download_through("outbound", [ section("outbound", "connection", { outbound_jsons: [ "{\"type\":\"direct\",\"tag\":\"Direct\"}" ] }) ]));
    v.accepts({ ...download_through("vpn", [ section("vpn", "connection") ]), section_interface: [ { ".name": "vpn_wg0", section: "vpn", name: "wg0" } ] });
    v.refuses(download_through("", [ section("proxy", "connection") ]), "no download section is selected");
    v.refuses(download_through("missing", [ section("proxy", "connection") ]), "points to section 'missing', which does not exist");
    v.refuses({ ...download_through("proxy", [ section("proxy", "connection", { enabled: "0" }) ]), connection_link: served([ "proxy" ]) },
        "points to section 'proxy', which is disabled");
    v.refuses(download_through("bypass", [ section("bypass", "bypass") ]), "whose action is 'bypass'");
});

function with_rule_sets(key, values) {
    return { section: [ section("proxy", "connection", { [key]: values }) ] };
}

t.test("community lists name a known service", () => {
    v.accepts(with_rule_sets("community_lists", [ "x", "telegram" ]));
    v.refuses(with_rule_sets("community_lists", [ "unknown" ]), "names an unknown built-in list 'unknown'");
    v.refuses(with_rule_sets("community_lists", [ "russia_inside" ]), "names an unknown built-in list 'russia_inside'");
});

t.test("rule sets are community names, http(s) URLs or absolute paths, never YAML", () => {
    for (let reference in [ "telegram", "https://example.com/rule.srs", "/tmp/rule.srs", "/tmp/rule.json", "/tmp/rule.lst", "/tmp/rule" ])
        v.accepts(with_rule_sets("rule_set", [ reference ]));
    for (let reference in [ "/tmp/rule.yaml", "https://example.com/rule.yml?token=secret", "relative/rule.srs", "ftp://example.com/rule.srs" ])
        v.refuses(with_rule_sets("rule_set", [ reference ]), "is neither an http(s) URL nor an absolute path");
});

t.done();
