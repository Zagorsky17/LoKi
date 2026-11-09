let fs = require("fs");
let common = require("core.common");
let constants = require("core.constants");
let lock = require("service.lock");

let paths = {
    pending: "/var/run/loki/start.retry",
    lock: "/var/run/loki/start-request.lock",
    autostart: "/etc/rc.d/S" + constants.LOKI_START_PRIORITY + "loki"
};
let sequence = 0;

function enabled() {
    return fs.readlink(paths.autostart) == "../init.d/loki";
}

function token() {
    if (fs.lstat(paths.pending)?.type != "file")
        return "";
    let file = fs.open(paths.pending, "r");
    if (file == null)
        return "";
    let value = file.read(128);
    file.close();
    return type(value) == "string" && match(value, /^[1-9][0-9]*-[0-9]+-[1-9][0-9]*\n$/) != null ? trim(value) : "";
}

function current(expected) {
    return expected != "" && token() == expected;
}

// Never hold this short lock while waiting for lifecycle or calling procd.
function locked(action) {
    let owner = common.own_pid();
    if (!lock.acquire_wait(paths.lock, owner, 5))
        return null;
    let value;
    try {
        value = require("service.update").allowed() ? action() : null;
    }
    catch (e) {
        lock.release(paths.lock, owner);
        return null;
    }
    lock.release(paths.lock, owner);
    return value;
}

function begin() {
    return locked(function() {
        let value = sprintf("%s-%d-%d", common.own_pid(), common.monotonic_ms(), ++sequence);
        return common.write_file_atomic(paths.pending, value + "\n") ? value : "";
    }) ?? "";
}

function cancel(expected) {
    return locked(function() {
        if (expected != null && !current(expected))
            return true;
        fs.lstat("");
        let absent = fs.error();
        let entry = fs.lstat(paths.pending);
        if (entry == null)
            return fs.error() == absent;
        return entry.type == "file" && fs.unlink(paths.pending);
    }) === true;
}

return { paths, enabled, token, current, begin, cancel };
