let t = require("t");
let uci = require("uci");
let core_uci = require("core.uci");

function seed_dhcp() {
    uci.__reset();
    core_uci.reset();
    uci.__seed("dhcp", [
        { ".name": "cfg01411c", ".type": "dnsmasq", server: [ "1.1.1.1", "8.8.8.8" ], noresolv: "0", cachesize: "150" },
        { ".name": "cfg02422d", ".type": "dnsmasq", server: [ "9.9.9.9" ], noresolv: "0" }
    ]);
}

t.test("an anonymous selector reads the section it counts to", () => {
    seed_dhcp();
    t.eq(core_uci.get("dhcp.@dnsmasq[0].server"), "1.1.1.1 8.8.8.8");
    t.eq(core_uci.get("dhcp.@dnsmasq[1].server"), "9.9.9.9");
    t.eq(core_uci.get_all("dhcp", "@dnsmasq[0]")[".name"], "cfg01411c");
});

t.test("an anonymous selector writes the section it counts to", () => {
    seed_dhcp();
    t.ok(core_uci.set("dhcp.@dnsmasq[0].noresolv", "1"));
    t.eq(core_uci.get("dhcp.cfg01411c.noresolv"), "1");

    t.ok(core_uci.delete("dhcp.@dnsmasq[0].server"));
    t.eq(core_uci.get("dhcp.cfg01411c.server"), "");

    t.ok(core_uci.add_list("dhcp.@dnsmasq[0].server", "127.0.0.42"));
    t.ok(core_uci.add_list("dhcp.@dnsmasq[0].server", "1.1.1.1"));
    t.eq(core_uci.get("dhcp.cfg01411c.server"), "127.0.0.42 1.1.1.1");

    t.ok(core_uci.del_list("dhcp.@dnsmasq[0].server", "127.0.0.42"));
    t.eq(core_uci.get("dhcp.cfg01411c.server"), "1.1.1.1");
    t.eq(core_uci.get("dhcp.cfg02422d.server"), "9.9.9.9", "the other section is untouched");
});

t.test("a write through a selector that counts past the last section fails", () => {
    seed_dhcp();
    t.eq(core_uci.delete("dhcp.@dnsmasq[9].server"), false);
});

function with_cursor(factory, callback) {
    let real_cursor = uci.cursor;
    uci.cursor = (...args) => factory(real_cursor(...args));
    core_uci.reset();
    try { callback(); }
    catch (e) {
        uci.cursor = real_cursor;
        core_uci.reset();
        die(e);
    }
    uci.cursor = real_cursor;
    core_uci.reset();
}

t.test("a failed native load is retried without discarding later pending writes", () => {
    for (let failure in [ null, false, "throw" ]) {
        seed_dhcp();
        let loads = 0;
        with_cursor((c) => {
            let real_load = c.load;
            c.load = (name) => {
                loads++;
                if (loads > 1)
                    return real_load(name);
                if (failure == "throw")
                    die("synthetic load failure");
                return failure;
            };
            return c;
        }, () => {
            t.eq(core_uci.load("dhcp"), false);
            t.eq(core_uci.load("dhcp"), true);
            t.eq(loads, 2);
            t.ok(core_uci.set("dhcp.@dnsmasq[0].noresolv", "1"));
            t.eq(core_uci.get("dhcp.@dnsmasq[0].noresolv"), "1");
            t.eq(loads, 2, "a successful load stays cached for pending changes");
        });
    }
});

t.test("failed loading cannot reach implicit reads or mutations", () => {
    for (let failure in [ null, false, "throw" ]) {
        seed_dhcp();
        let calls = [];
        with_cursor((c) => {
            let record = function(name) {
                let original = c[name];
                c[name] = (...args) => {
                    push(calls, name);
                    return original(...args);
                };
            };
            for (let name in [ "get", "get_all", "foreach", "add", "set", "delete", "commit" ])
                record(name);
            c.load = () => {
                if (failure == "throw")
                    die("synthetic load failure");
                return failure;
            };
            return c;
        }, () => {
            t.eq(core_uci.get("dhcp.@dnsmasq[0].noresolv"), "");
            t.eq(core_uci.get_all("dhcp", "cfg01411c"), null);
            t.eq(core_uci.exists("dhcp.cfg01411c"), false);
            t.eq(core_uci.sections("dhcp", "dnsmasq"), []);
            t.eq(core_uci.section_objects("dhcp", "dnsmasq"), []);
            t.eq(core_uci.add("dhcp", "dnsmasq"), "");
            t.eq(core_uci.set_section("dhcp.new", "dnsmasq"), false);
            t.eq(core_uci.set("dhcp.cfg01411c.noresolv", "1"), false);
            t.eq(core_uci.delete("dhcp.cfg01411c.server"), false);
            t.eq(core_uci.add_list("dhcp.cfg01411c.server", "127.0.0.42"), false);
            t.eq(core_uci.del_list("dhcp.cfg02422d.server", "9.9.9.9"), false);
            t.eq(core_uci.commit("dhcp"), false);
            t.eq(calls, [], "no implicit load or write may follow the refused load");
            t.eq(uci.__commits(), []);
            t.eq(uci.__sections("dhcp")[0].noresolv, "0");
        });
    }
});

t.test("native null, false and thrown mutation failures are preserved", () => {
    for (let operation in [ "set", "delete", "commit" ]) {
        for (let failure in [ null, false, "throw" ]) {
            seed_dhcp();
            with_cursor((c) => {
                c[operation] = () => {
                    if (failure == "throw")
                        die("synthetic mutation failure");
                    return failure;
                };
                return c;
            }, () => {
                if (operation == "set") {
                    t.eq(core_uci.set("dhcp.cfg01411c.noresolv", "1"), false);
                    t.eq(core_uci.set_section("dhcp.new", "dnsmasq"), false);
                    t.eq(core_uci.add_list("dhcp.cfg01411c.server", "127.0.0.42"), false);
                    t.eq(core_uci.del_list("dhcp.cfg01411c.server", "1.1.1.1"), false);
                }
                else if (operation == "delete") {
                    t.eq(core_uci.delete("dhcp.cfg01411c.server"), false);
                    t.eq(core_uci.delete("dhcp.cfg01411c"), false);
                    t.eq(core_uci.del_list("dhcp.cfg02422d.server", "9.9.9.9"), false);
                }
                else {
                    t.eq(core_uci.commit("dhcp"), false);
                }
                t.eq(uci.__commits(), []);
                t.eq(uci.__sections("dhcp")[0].noresolv, "0");
            });
        }
    }
});

t.test("successful pending mutations can still be committed and reloaded", () => {
    seed_dhcp();
    t.ok(core_uci.set_section("dhcp.extra", "dnsmasq"));
    t.ok(core_uci.delete("dhcp.extra"));
    t.eq(core_uci.exists("dhcp.extra"), false);
    t.ok(core_uci.set("dhcp.cfg01411c.noresolv", "1"));
    t.ok(core_uci.commit("dhcp"));
    t.eq(uci.__commits(), [ "dhcp" ]);
    core_uci.reset();
    t.eq(core_uci.get("dhcp.cfg01411c.noresolv"), "1");
});

t.done();
