let t = require("t");
let v = require("validation");
let fixture = require("fixture");
let validator = require("config.validator");
let generator = require("singbox.generator");
let nft = require("nft.apply");
let uci = require("core.uci");
let raw = require("uci");
let stub = require("stub");

function data(host, network) {
    return v.with_dns({ settings: { source_network_interfaces: [ network ] },
        section: [ { ".name": "main", action: "connection", destinations: host } ],
        connection_link: fixture.links("main", [ "socks5://127.0.0.1:1080#Node" ]) });
}

t.test("core and nft generation consume the validated snapshot after another cursor commits", () => {
    fixture.seed(data("validated.example", "br-lan"));
    stub.commands([ stub.logger([]) ]);
    let model = validator.validate();
    let other = raw.cursor();
    other.load("loki");
    other.set("loki", "main", "destinations", "unvalidated.example");
    other.set("loki", "settings", "source_network_interfaces", [ "eth9" ]);
    other.commit("loki");
    let config = sprintf("%J", generator.build({ controller_secret: fixture.CONTROLLER_SECRET, local_prefixes: [] }, model));
    let rules = nft.build(model).script;
    stub.restore();
    t.contains(config, "validated.example");
    t.excludes(config, "unvalidated.example");
    t.contains(rules, "{ br-lan }");
    t.excludes(rules, "{ eth9 }");
    uci.reset();
    t.eq(uci.get("loki.main.destinations"), "unvalidated.example", "the independent commit is retained");
});

t.done();
