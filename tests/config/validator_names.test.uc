let t = require("t");
let v = require("validation");
let fixture = require("fixture");

t.test("untagged-subscription", () => {
    v.refuses({
        "settings": {
            "dns_server": [
                "77.88.8.8"
            ],
            "bootstrap_dns_server": [
                "77.88.8.8"
            ]
        },
        "section": [
            {
                ".name": "proxy",
                "label": "Main",
                "enabled": "1",
                "action": "connection"
            }
        ],
        "subscription_url": [
            {
                ".name": "one",
                "section": "proxy",
                "url": "https://one.example/sub"
            },
            {
                ".name": "two",
                "section": "proxy",
                "url": "https://two.example/sub",
                "tag": "sub2"
            }
        ]
    }, "A subscription in section 'Main' has no name");
});

t.test("every link of a section has a link and a name of its own", () => {
    let main = [ { ".name": "proxy", label: "Main", enabled: "1", action: "connection" } ];
    let links = fixture.links("proxy", [ "socks5://127.0.0.1:1080#A", "socks5://127.0.0.1:1081#B" ]);
    v.accepts({ section: main, connection_link: links });
    v.refuses({ section: main, connection_link: [ links[0], { ...links[1], name: "A" } ] }, "Section 'Main' has more than one link named 'A'");
    v.refuses({ section: main, connection_link: [ links[0], { ...links[1], name: " " } ] }, "A link in section 'Main' has no name");
    v.refuses({ section: main, connection_link: [ links[0], { ...links[1], uri: "" } ] }, "A link in section 'Main' is empty");
    for (let address in [ "https://sub.example.com/api/sub/token", "https://example.com" ])
        v.refuses({ section: main, connection_link: [ links[0], { ...links[1], uri: address } ] },
            "Link 'B' in section 'Main' is probably a subscription URL. Paste it into Subscription");
    for (let address in [ "http://user:pass@proxy.example.com:8080", "https://proxy.example.com:443#RU/Moscow" ])
        v.accepts({ section: main, connection_link: [ links[0], { ...links[1], uri: address } ] });
    v.accepts({ section: [ ...main, { ".name": "other", enabled: "1", action: "connection" } ],
        connection_link: [ ...links, { ...links[1], ".name": "other_link1", name: "A", section: "other" } ] });
});

t.test("a name belongs to one server or group of its section and holds no slash", () => {
    let main = [ { ".name": "proxy", label: "Main", enabled: "1", action: "connection" } ];
    let links = fixture.links("proxy", [ "socks5://127.0.0.1:1080#A" ]);
    let tailnet = { ".name": "proxy_tunnel", section: "proxy", kind: "tailscale", name: "B",
        tailscale_auth_key: "tskey-auth-test", tailscale_hostname: "forkop-router" };
    v.accepts({ section: main, connection_link: links, tunnel: [ tailnet ], urltest: [ { ".name": "ut", section: "proxy", name: "C" } ] });
    v.refuses({ section: main, connection_link: links, tunnel: [ { ...tailnet, name: "A" } ] },
        "Section 'Main' has a link and a tunnel named 'A'. Rename one of them");
    v.refuses({ section: main, connection_link: links, urltest: [ { ".name": "ut", section: "proxy", name: "A" } ] },
        "Section 'Main' has a link and a URLTest named 'A'");
    v.refuses({ section: main, tunnel: [ tailnet ], fallback_group: [ { ".name": "fb", section: "proxy", name: "B" } ],
        fallback_level: [ { ".name": "fl", group: "fb", name: "All", order: "0", server_filter_mode: "all" } ] },
        "Section 'Main' has a tunnel and a fallback group named 'B'");
    v.refuses({ section: [ { ...main[0], outbound_jsons: [ "{\"type\":\"direct\",\"tag\":\"wg0\"}" ] } ],
        section_interface: [ { ".name": "wan", section: "proxy", name: "wg0" } ] },
        "Section 'Main' has an interface and a JSON outbound named 'wg0'");
    v.refuses({ section: main, connection_link: [ { ...links[0], name: "US/LA" } ] },
        "Name 'US/LA' in section 'Main' contains '/'. Use another character");
    v.refuses({ section: main, urltest: [ { ".name": "ut", section: "proxy", name: "Auto/Best" } ], tunnel: [ tailnet ] },
        "Name 'Auto/Best' in section 'Main' contains '/'");
});

t.test("a refusal names sections by their display labels", () => {
    v.refuses({
        section: [ { ".name": "section_70536a", label: "Streaming", enabled: "1", action: "connection",
             ports: [ "99999" ] } ],
        connection_link: fixture.links("section_70536a", [ "socks5://127.0.0.1:1080" ])
    }, "Invalid port condition '99999' in section 'Streaming'");

});

t.test("duplicate-json-tags", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection",
                "outbound_jsons": [
                    "{\"type\":\"direct\",\"tag\":\"same\"}",
                    "{\"type\":\"direct\",\"tag\":\"same\"}"
                ],
                "destinations": "example.org"
            }
        ]
    }, "Section 'proxy' has more than one JSON outbound named 'same'");
});

t.test("tagless-json", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "enabled": "1",
                "action": "connection",
                "outbound_jsons": [
                    "{\"type\":\"direct\"}"
                ],
                "destinations": "example.org"
            }
        ]
    }, "JSON outbound without a non-empty tag");
});

t.test("duplicate-section-names", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "one",
                "label": "Office",
                "enabled": "0"
            },
            {
                ".name": "two",
                "label": "Office",
                "enabled": "0"
            }
        ]
    }, "Duplicate section display name 'Office'");
});

t.test("duplicate-subscription-tags", () => {
    v.refuses({
        "settings": {},
        "section": [
            {
                ".name": "proxy",
                "label": "Office",
                "enabled": "0"
            }
        ],
        "subscription_url": [
            {
                ".name": "one",
                "section": "proxy",
                "url": "https://one.example/sub",
                "tag": "premium"
            },
            {
                ".name": "two",
                "section": "proxy",
                "url": "https://two.example/sub",
                "tag": "premium"
            }
        ]
    }, "Duplicate subscription name 'premium'");
});

t.done();
