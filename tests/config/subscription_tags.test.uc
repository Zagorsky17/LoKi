let t = require("t");
let fixture = require("fixture");
let connections = require("config.connections");

function tags(stored) {
    let sources = [];
    for (let i = 0; i < length(stored); i++) {
        let source = { ".name": "source" + i, "section": "proxy", "url": "https://example.com/" + i };
        if (stored[i] != null)
            source.tag = stored[i];
        push(sources, source);
    }
    fixture.seed({
        section: [ { ".name": "proxy", "enabled": "1", "action": "connection" } ],
        subscription_url: sources
    });
    connections.load();
    return connections.subscription_tags({ ".name": "proxy", ".type": "section" });
}

t.test("a stored tag names the subscription", () => {
    t.eq(tags([ "main", " spare " ]), [ "main", "spare" ]);
});

t.test("an untagged subscription has no name", () => {
    t.eq(tags([ null, "sub1" ]), [ "", "sub1" ]);
});

t.done();
