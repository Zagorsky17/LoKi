let t = require("t");
let fixture = require("fixture");
let generator = require("singbox.generator");

function build(data, context) {
    fixture.seed(data);
    return generator.build({ controller_secret: fixture.CONTROLLER_SECRET, ...(context ?? { service_address: "127.0.0.1" }) });
}

function refused(data) {
    return t.throws(() => build(data)).message;
}

t.test("a configuration without an enabled section is refused", () => {
    t.eq(refused({ settings: fixture.settings(), section: [] }), "no usable sections");
});

t.test("a connection section without a single source does not count as usable", () => {
    t.eq(refused({
        settings: fixture.settings(),
        section: [ { ".name": "main", action: "connection" } ]
    }), "no usable sections");
});

t.test("loki-core has something to run in a section that needs no source, or one with a source", () => {
    let runnable = (data) => {
        fixture.seed({ settings: fixture.settings(), ...data });
        return generator.runnable();
    };
    let link = fixture.links("main", [ "vless://u@a.example:443#A" ]);
    t.ok(!runnable({}), "the configuration the package ships");
    t.ok(!runnable({ section: [ { ".name": "main", action: "connection" } ] }), "a connection section without a source");
    t.ok(!runnable({ section: [ { ".name": "main", action: "connection", enabled: "0" } ], connection_link: link }), "a disabled section");
    t.ok(runnable({ section: [ { ".name": "main", action: "connection" } ], connection_link: link }));
    t.ok(runnable({ section: [ { ".name": "ads", action: "block", destinations: "ads.example" } ] }));
    t.ok(!runnable({ server: [ { ".name": "in", protocol: "vless" } ] }), "a server never switched on");
    t.ok(!runnable({ server: [ { ".name": "in", protocol: "vless", enabled: "1" } ] }));
});

t.test("a disabled section is left out", () => {
    let config = build({
        settings: fixture.settings(),
        section: [
            { ".name": "off", action: "connection", enabled: "0" },
            { ".name": "on", action: "block", destinations: "ads.example" }
        ],
        connection_link: fixture.links("off", [ "vless://u@a.example:443#A" ])
    });
    for (let outbound in config.outbounds)
        t.ok(outbound.tag != "off", "disabled section produced an outbound");
});

t.test("each build reads the configuration committed at that moment", () => {
    let first = build({
        settings: fixture.settings(),
        section: [ { ".name": "main", action: "connection" } ],
        connection_link: fixture.links("main", [ "vless://u@a.example:443#A" ])
    });
    let second = build({
        settings: fixture.settings(),
        section: [ { ".name": "other", action: "connection" } ],
        connection_link: fixture.links("other", [ "vless://u@b.example:443#B" ])
    });
    let tags = map(second.outbounds, (o) => o.tag);
    t.contains(tags, "other");
    t.excludes(tags, "main");
    t.contains(map(first.outbounds, (o) => o.tag), "main");
});

t.done();
