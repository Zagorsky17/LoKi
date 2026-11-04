let t = require("t");
let stub = require("stub");
let uci = require("uci");
let ubus = require("ubus");

t.test("a cursor sees only committed changes of another cursor", () => {
    uci.__reset();
    uci.__seed("loki", [
        { ".name": "settings", ".type": "settings", log_level: "warn", dns_server: [ "1.1.1.1", "8.8.8.8" ] },
        { ".type": "section", label: "anon" }
    ]);

    let writer = uci.cursor();
    let reader = uci.cursor();
    t.eq(writer.get("loki", "settings", "dns_server"), [ "1.1.1.1", "8.8.8.8" ]);

    writer.set("loki", "settings", "log_level", "debug");
    t.eq(reader.get("loki", "settings", "log_level"), "warn", "uncommitted change leaked");
    writer.commit("loki");
    t.eq(uci.cursor().get("loki", "settings", "log_level"), "debug");
    t.eq(uci.__commits(), [ "loki" ]);
});

t.test("foreach walks sections of one type in file order with metadata", () => {
    uci.__reset();
    uci.__seed("loki", [
        { ".name": "a", ".type": "section" },
        { ".name": "s", ".type": "settings" },
        { ".name": "b", ".type": "section", enabled: "0" }
    ]);
    let seen = [];
    uci.cursor().foreach("loki", "section", (s) => push(seen, [ s[".name"], s[".index"], s.enabled ]));
    t.eq(seen, [ [ "a", 0, null ], [ "b", 2, "0" ] ]);
});

t.test("add, set and delete shape a package", () => {
    uci.__reset();
    uci.__seed("loki", []);
    let c = uci.cursor();
    let name = c.add("loki", "server");
    c.set("loki", name, "port", 443);
    c.set("loki", "main", "section");
    c.delete("loki", name, "port");
    c.commit("loki");
    t.eq(uci.__sections("loki"), [
        { ".name": name, ".type": "server", ".anonymous": true, ".index": 0 },
        { ".name": "main", ".type": "section", ".anonymous": false, ".index": 1 }
    ]);
});

t.test("split_shell undoes the backend's quoting and drops redirections", () => {
    t.eq(stub.split_shell("'nft' '-f' '-' 2>'/tmp/err' >/dev/null 2>&1"), [ "nft", "-f", "-" ]);
    t.eq(stub.split_shell("'logger' '-t' 'loki' 'it'\\''s here' 1000>&- &"), [ "logger", "-t", "loki", "it's here" ]);
});

t.test("command fakes answer, record and refuse the unexpected", () => {
    let fs = require("fs");
    stub.commands([
        [ "ip rule", { status: 0, stdout: "105: from all fwmark\n" } ],
        [ /^'false'/, { status: 1 } ]
    ]);
    let pipe = fs.popen("'ip' 'rule' 'show'");
    t.eq(pipe.read("all"), "105: from all fwmark\n");
    t.eq(pipe.close(), 0);
    t.eq(system("'false'"), 1);
    t.eq(stub.command_lines(), [ "ip rule show", "false" ]);
    let e = t.throws(() => system("'rm' '-rf' '/'"));
    t.contains(e.message, "unexpected command");
    stub.restore();
});

t.test("ubus fake answers calls and delivers deferred replies", () => {
    ubus.__reset();
    ubus.__on("service.list", { loki: { instances: {} } });
    let connection = ubus.connect();
    t.eq(connection.call("service", "list", { name: "loki" }), { loki: { instances: {} } });
    connection.publish("demo", {
        later: { call: (request) => { request.defer(); request.reply({ ok: true }); } }
    });
    t.eq(ubus.__invoke("demo", "later").replied, { ok: true });
});

t.test("a stubbed clock stands still in seconds and comes back on restore", () => {
    stub.clock(1000);
    t.eq([ clock(), clock() ], [ [ 1000, 0 ], [ 1000, 1 ] ]);
    stub.restore();
    t.ok(clock()[0] > 1000);
});

t.done();
