let t = require("t");
let fs = require("fs");
let common = require("core.common");
let process = require("core.process");

const STAT = "4242 (sing) box) S 1 4242 4242 0 -1 4194560 15734 0 6 0 239 42 0 0 20 0 9 0 190694980 812421120 16851 4294967295\n";

t.test("process fields follow the last command-name delimiter", () => {
    let fields = process.stat_fields(STAT);
    t.eq([ fields[11], fields[12], fields[19] ], [ "239", "42", "190694980" ]);
    for (let bad in [ null, "", "4242 (missing", "4242 () S 1", replace(STAT, "239", "bad"),
        replace(STAT, "42 0 0", "-1 0 0"), replace(STAT, "190694980", "ticks") ])
        t.eq(process.stat_fields(bad), null);
});

t.test("birth ticks are read only from a numeric PID's proc stat", () => {
    let original = fs.readfile;
    let reads = [];
    fs.readfile = (path) => { push(reads, path); return STAT; };
    let ticks = process.start_ticks(4242);
    let bad = [];
    for (let pid in [ null, "", "0", "-1", "../self", "self", "1/stat", "1\x00ignored", "99999999999" ])
        push(bad, process.start_ticks(pid));
    fs.readfile = original;
    t.eq(ticks, 190694980);
    t.eq(reads, [ "/proc/4242/stat" ]);
    for (let result in bad) t.eq(result, null);
    t.ok(process.start_ticks(common.own_pid()) != null);
});

t.done();
