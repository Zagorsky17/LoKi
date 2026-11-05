// The controller credential belongs to this boot, outside UCI and browser configuration.
let fs = require("fs");
let common = require("core.common");
let storage = require("core.cache_path");

const SECRET_PATH = "/tmp/loki/controller.secret";

function refuse() {
    die("Private LoKi controller credential is unsafe or unavailable");
}

function read(path) {
    let before = fs.lstat(path);
    if (before?.type != "file" || before.uid != fs.stat("/proc/self").uid || before.nlink != 1 ||
        (before.mode & 0777) != 0600 || before.size != 64)
        refuse();
    let file = fs.open(path, "re");
    if (file == null)
        refuse();
    let value;
    try { value = file.read(65); }
    catch (e) { file.close(); refuse(); }
    file.close();
    let after = fs.lstat(path);
    if (after == null || after.inode != before.inode || after.dev?.major != before.dev?.major ||
        after.dev?.minor != before.dev?.minor || after.uid != before.uid ||
        after.nlink != before.nlink || after.mode != before.mode || after.size != before.size ||
        after.mtime != before.mtime || after.ctime != before.ctime || type(value) != "string" ||
        length(value) != 64 || !match(value, /^[a-f0-9]{64}$/) || value == sprintf("%064d", 0))
        refuse();
    return value;
}

function load() {
    let path = storage.ensure({ cache_path: SECRET_PATH });
    if (fs.lstat(path) != null)
        return read(path);

    let file = fs.open("/dev/urandom", "re");
    if (file == null)
        refuse();
    let entropy;
    try { entropy = file.read(32); }
    catch (e) { file.close(); refuse(); }
    file.close();
    if (type(entropy) != "string" || length(entropy) != 32)
        refuse();
    let value = "";
    for (let i = 0; i < 32; i++)
        value += sprintf("%02x", ord(entropy, i));
    if (value == sprintf("%064d", 0))
        refuse();
    // Exclusive creation preserves a concurrent winner; a partial or uncertain file is refused.
    common.write_private_file(path, value);
    return read(path);
}

function redactor() {
    let value;
    try {
        let path = storage.validate({ cache_path: SECRET_PATH });
        if (fs.lstat(path) != null)
            value = read(path);
    }
    catch (e) {
        return (text) => "Log data is unavailable: private LoKi controller credential inspection failed";
    }
    return (text) => type(text) != "string" ? "" : value == null ? text : join("SERVER_ONLY", split(text, value));
}

return { load, redactor };
