let t = require("t");
let v = require("validation");

t.test("the DNS timeout accepts a duration and refuses malformed values", () => {
    v.accepts({ settings: { dns_timeout: "15s" } });
    v.refuses({ settings: { dns_timeout: "bad" } }, "DNS timeout");
});

t.done();
