let fs = require("fs");
let common = require("core.common");

const DEFAULT_PATH = "/tmp/loki/cache.db";

function effective_path(settings) {
    return common.option(settings, "cache_path", DEFAULT_PATH) || DEFAULT_PATH;
}

function refuse(reason) {
    die("Private LoKi cache storage: " + reason);
}

function own_uid() {
    let file = fs.open("/proc/self/status", "r");
    if (file == null)
        refuse("cannot establish the process owner");
    let status = file.read(16384);
    file.close();
    let found = match(status ?? "", /(^|\n)Uid:[ \t]+[0-9]+[ \t]+([0-9]+)/);
    if (found == null)
        refuse("cannot establish the process owner");
    return int(found[2]);
}

// fs exposes strerror rather than errno. Empty-path lstat gives the local ENOENT
// text without looking up a filesystem target, including on translated libc locales.
function missing_error() {
    fs.error();
    if (fs.lstat("") != null)
        refuse("cannot establish filesystem inspection errors");
    let missing = fs.error();
    if (missing == null)
        refuse("cannot establish filesystem inspection errors");
    return missing;
}

function inspect_entry(path, missing) {
    fs.error();
    let stat = fs.lstat(path);
    if (stat == null && fs.error() != missing)
        refuse("cannot inspect its filesystem path");
    return stat;
}

// This is a read-only filesystem gate. The core rechecks anchored descriptors and the DB marker.
function inspect(path, create) {
    if (type(path) != "string" || substr(path, 0, 1) != "/" || index(path, "\u0000") >= 0 || match(path, /[[:cntrl:]]/) != null)
        refuse("use an absolute canonical file path");
    let parts = split(substr(path, 1), "/");
    if (length(parts) < 2)
        refuse("use a private cache directory");
    for (let part in parts)
        if (part == "" || part == "." || part == "..")
            refuse("use an absolute canonical file path");
    let uid = own_uid();
    let no_entry = missing_error();
    let root = inspect_entry("/", no_entry);
    if (root == null || root.type != "directory" || root.uid != 0 || (root.mode & 0022) != 0)
        refuse("the filesystem root is unsafe");
    let current = "";
    let missing = false;
    for (let index = 0; index < length(parts) - 1; index++) {
        current += "/" + parts[index];
        let stat = missing ? null : inspect_entry(current, no_entry);
        if (stat == null && create) {
            if (!fs.mkdir(current, 0700))
                refuse("cannot create its private directory");
            stat = inspect_entry(current, no_entry);
        }
        if (stat == null) {
            missing = true;
            continue;
        }
        let sticky = stat.uid == 0 && (stat.mode & 01000) != 0;
        if (stat.type != "directory" || (stat.uid != uid && stat.uid != 0) || ((stat.mode & 0022) != 0 && !sticky))
            refuse("a parent directory is unsafe");
        if (index == length(parts) - 2 && (stat.uid != uid || (stat.mode & 0777) != 0700))
            refuse("the cache directory must be owned by the process with mode 0700");
    }
    let file = missing ? null : inspect_entry(path, no_entry);
    if (file != null && (file.type != "file" || file.uid != uid || file.nlink != 1))
        refuse("the database must be an owned regular file with one link");
    return path;
}

function validate(settings) {
    return inspect(effective_path(settings), false);
}

function ensure(settings) {
    return inspect(effective_path(settings), true);
}

return { DEFAULT_PATH, effective_path, validate, ensure };
