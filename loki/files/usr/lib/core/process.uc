let fs = require("fs");

// The command name may contain spaces and parentheses; fields start after its final ") ".
function stat_fields(stat) {
    stat = stat == null ? "" : "" + stat;
    let marker = rindex(stat, ") ");
    if (marker < 0)
        return null;

    let fields = split(trim(substr(stat, marker + 2)), /[ \t\r\n]+/);
    for (let i in [ 11, 12, 19 ])
        if (match(fields[i] ?? "", /^[0-9]+$/) == null)
            return null;
    return fields;
}

function start_ticks(pid) {
    pid = "" + pid;
    if (index(pid, "\x00") >= 0 || match(pid, /^[1-9][0-9]{0,9}$/) == null)
        return null;
    let fields = stat_fields(fs.readfile("/proc/" + pid + "/stat"));
    return fields == null ? null : int(fields[19]);
}

return { stat_fields, start_ticks };
