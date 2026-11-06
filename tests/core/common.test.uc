let t = require("t");
let stub = require("stub");
let fs = require("fs");
let common = require("core.common");

t.test("as_string keeps strings and turns null into an empty string", () => {
    t.eq(common.as_string("a"), "a");
    t.eq(common.as_string(null), "");
    t.eq(common.as_string(42), "42");
});

t.test("durations follow Go syntax, as loki-core reads them", () => {
    let cases = [
        [ "3m", 180 ], [ "30m", 1800 ], [ "1h30m", 5400 ], [ "1d", 86400 ], [ "1.5s", 2 ],
        [ "90", null ], [ "bogus", null ], [ "", null ], [ "0s", null ], [ "1h\u0000private", null ]
    ];
    for (let entry in cases)
        t.eq(common.duration_to_seconds(entry[0]), entry[1], entry[0]);
});

t.test("parse_number reads hex marks and decimals only", () => {
    t.eq(common.parse_number("0x40000000"), 1073741824);
    t.eq(common.parse_number("105"), 105);
    t.eq(common.parse_number("0x"), null);
    t.eq(common.parse_number("12a"), null);
});

t.test("numeric parsing rejects embedded NUL before native string operations", () => {
    for (let value in [ "105\u0000", "105\u0000private", "\u0000105", "0x1\u0000", "0x1\u0000f", " 1\u0000x " ])
        t.eq(common.parse_number(value), null);
    t.eq(common.parse_number(" \t0x000a\n"), 10);
    t.eq(common.parse_number(105), 105);
});

t.test("option joins lists and falls back for a missing key", () => {
    let section = { a: "x", l: [ "1", "2" ] };
    t.eq(common.option(section, "a"), "x");
    t.eq(common.option(section, "l"), "1 2");
    t.eq(common.option(section, "missing", "d"), "d");
    t.eq(common.option(null, "a"), "");
});

t.test("list_option splits a scalar on runs of whitespace", () => {
    t.eq(common.list_option({ p: "80  443" }, "p"), [ "80", "443" ]);
    t.eq(common.list_option({ p: [ "a b" ] }, "p"), [ "a b" ]);
    t.eq(common.list_option({ p: "" }, "p"), []);
    t.eq(common.list_option({}, "p"), []);
});

t.test("bool_option accepts the UCI spellings of true", () => {
    for (let value in [ "1", "true", "yes", "on" ])
        t.ok(common.bool_option({ b: value }, "b"), value);
    t.ok(!common.bool_option({ b: "0" }, "b", true));
    t.ok(!common.bool_option({ b: "1\u0000private" }, "b", false));
    t.ok(common.bool_option({}, "b", true), "missing key takes the fallback");
    t.ok(common.bool_option({ b: "" }, "b", true), "an empty value is one nobody set, as in UCI");
    t.ok(!common.bool_option({ b: "" }, "b", false));
});

t.test("int_option takes digits only and falls back otherwise", () => {
    t.eq(common.int_option({ n: "12" }, "n", 5), 12);
    t.eq(common.int_option({ n: "12abc" }, "n", 5), 5);
    t.eq(common.int_option({}, "n", 7), 7);
    for (let value in [ "12\u0000", "12\u0000private", "\u000012" ]) {
        t.eq(common.int_option({ n: value }, "n", 5), 5);
        t.eq(common.int_option({}, "n", value), 0);
    }
    t.eq(common.int_option({ n: "012" }, "n", 5), 12);
    t.eq(common.int_option({ n: " 12" }, "n", "7"), 7);
    t.eq(common.int_option({ n: "0x12" }, "n", 5), 5);
});

t.test("signal_from_status decodes both ways a killed command is reported", () => {
    t.eq(common.signal_from_status(-9), 9);
    t.eq(common.signal_from_status(137), 9);
    t.eq(common.signal_from_status(1), 0);
});

t.test("files are written atomically and directories created with their parents", () => {
    let dir = stub.tmpdir() + "/a/b";
    t.ok(common.ensure_dir(dir));
    t.ok(common.write_file_atomic(dir + "/state.json", "{}\n"));
    t.eq(fs.readfile(dir + "/state.json"), "{}\n");
    t.eq(length(fs.glob(dir + "/*")), 1, "no temporary file left behind");
    t.eq(common.read_first_line(dir + "/state.json"), "{}");
    t.eq(common.read_first_line(dir + "/missing"), "");
});

t.test("remove_tree deletes a nested directory and ignores a missing one", () => {
    let dir = stub.tmpdir();
    common.ensure_dir(dir + "/x/y");
    fs.writefile(dir + "/x/y/f", "1");
    common.remove_tree(dir + "/x");
    t.eq(fs.stat(dir + "/x"), null);
    common.remove_tree(dir + "/never");
});

t.test("own_pid names this process and pid_alive knows it is running", () => {
    let pid = common.own_pid();
    t.matches(pid, /^[0-9]+$/);
    t.ok(common.pid_alive(pid));
    t.ok(!common.pid_alive("0"));
    t.ok(!common.pid_alive("abc"));
    t.ok(!common.pid_alive(pid + "\u0000"));
    t.ok(!common.pid_alive(pid + "\u0000private"));
    t.ok(!common.pid_alive("\u0000" + pid));
});

t.done();
