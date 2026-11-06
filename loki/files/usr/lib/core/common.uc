let fs = require("fs");

// Returned as is, not copied: the nft set builders pass every address through here.
function as_string(value) {
    if (type(value) == "string")
        return value;
    return value == null ? "" : "" + value;
}

function object_or_empty(value) {
    return type(value) == "object" ? value : {};
}

function array_or_empty(value) {
    return type(value) == "array" ? value : [];
}

// A shell that execs the command reports the signal negated, one that waits reports 128 + signal.
function signal_from_status(status) {
    status = int(status || 0);
    if (status < 0)
        return 0 - status;
    if (status > 128 && status < 160)
        return status - 128;
    return 0;
}

function parse_json(text) {
    if (text == null)
        return null;
    try {
        return json(text);
    }
    catch (e) {
        return null;
    }
}

function read_json_file(path) {
    return parse_json(fs.readfile(path));
}

function write_json(value) {
    print(sprintf("%J", value), "\n");
}

function parent_dir(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash <= 0 ? "" : substr(path, 0, slash);
}

function ensure_dir(path) {
    path = as_string(path);
    if (path == "" || path == "/")
        return true;
    let stat = fs.stat(path);
    if (stat != null)
        return stat.type == "directory";
    if (!ensure_dir(parent_dir(path)))
        return false;
    return fs.mkdir(path, 0755) || fs.stat(path)?.type == "directory";
}

function write_file(path, text) {
    return fs.writefile(as_string(path), as_string(text)) != null;
}

function write_private_file(path, text) {
    path = as_string(path);
    text = as_string(text);
    let file = fs.open(path, "wxe", 0600);
    if (file == null)
        return false;
    let written = file.write(text) == length(text);
    file.close();
    // The pinned ucode flush() cannot report failure reliably; verify the closed file.
    if (written && fs.readfile(path) == text)
        return true;
    fs.unlink(path);
    return false;
}

function write_file_atomic(path, text) {
    path = as_string(path);
    let now = clock();
    let temporary = sprintf("%s.%d.%d.tmp", path, now[0], now[1]);
    if (!ensure_dir(parent_dir(path)) || !write_private_file(temporary, text))
        return false;
    if (!fs.rename(temporary, path)) {
        fs.unlink(temporary);
        return false;
    }
    return true;
}

function read_first_line(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return "";
    let newline = index(data, "\n");
    return newline >= 0 ? substr(data, 0, newline) : data;
}

function remove_tree(path) {
    path = as_string(path);
    let stat = fs.lstat(path);
    if (stat == null)
        return;
    if (stat.type == "directory") {
        for (let name in fs.lsdir(path) ?? [])
            if (name != "." && name != "..")
                remove_tree(path + "/" + name);
        fs.rmdir(path);
        return;
    }
    fs.unlink(path);
}

function own_pid() {
    let stat = as_string(fs.readfile("/proc/self/stat"));
    let separator = index(stat, " ");
    return separator > 0 ? substr(stat, 0, separator) : "";
}

function pid_alive(pid) {
    pid = as_string(pid);
    return index(pid, "\u0000") < 0 && match(pid, /^[1-9][0-9]*$/) != null && fs.stat("/proc/" + pid) != null;
}

function now_seconds() {
    return clock()[0];
}

function monotonic_ms() {
    let now = clock(true);
    return now[0] * 1000 + int(now[1] / 1000000);
}

function strip_internal_fields(value) {
    if (type(value) == "array") {
        for (let i = 0; i < length(value); i++)
            value[i] = strip_internal_fields(value[i]);
        return value;
    }

    if (type(value) == "object") {
        for (let key in keys(value)) {
            if (substr(key, 0, 2) == "__") {
                delete value[key];
                continue;
            }
            value[key] = strip_internal_fields(value[key]);
        }
    }

    return value;
}

// Go duration syntax ("3m", "1h30m", "1.5s") as whole seconds, or null.
function duration_to_seconds(value) {
    let rest = as_string(value);
    if (rest == "")
        return null;

    let total = 0.0;
    let multipliers = {
        ns: 0.000000001,
        us: 0.000001,
        ms: 0.001,
        s: 1,
        m: 60,
        h: 3600,
        d: 86400
    };

    while (rest != "") {
        let matched = match(rest, /^([0-9]+(\.[0-9]+)?)(ns|us|ms|s|m|h|d)/);
        if (!matched)
            return null;

        total += (matched[1] * 1) * multipliers[matched[3]];
        rest = substr(rest, length(matched[0]));
    }

    return total <= 0 ? null : int(total + 0.5);
}

function parse_number(value) {
    value = as_string(value);
    // Native lowercasing can discard the suffix after NUL before the numeric check.
    if (index(value, "\u0000") >= 0)
        return null;
    value = lc(trim(value));
    if (value == "")
        return null;

    if (substr(value, 0, 2) != "0x")
        return match(value, /^[0-9]+$/) == null ? null : int(value);

    value = substr(value, 2);
    if (value == "")
        return null;

    let result = 0;
    for (let i = 0; i < length(value); i++) {
        let digit = index("0123456789abcdef", substr(value, i, 1));
        if (digit < 0)
            return null;
        result = result * 16 + digit;
    }

    return result;
}

function option(section, key, fallback) {
    if (fallback == null)
        fallback = "";
    let value = object_or_empty(section)[key];
    if (value == null)
        return fallback;
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function words(value) {
    let result = [];
    for (let item in (type(value) == "array" ? value : split(as_string(value), /[ \t\r\n]+/))) {
        item = trim(as_string(item));
        if (item != "")
            push(result, item);
    }
    return result;
}

function list_option(section, key) {
    let value = object_or_empty(section)[key];
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;
    return words(value);
}

// An empty value is unset, as in UCI.
function bool_value(value, fallback) {
    if (value == null || value == "")
        return !!fallback;
    value = as_string(value);
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function bool_option(section, key, fallback) {
    return bool_value(object_or_empty(section)[key], fallback);
}

function int_option(section, key, fallback) {
    let value = option(section, key, "");
    if (index(value, "\u0000") >= 0 || match(value, /^[0-9]+$/) == null)
        value = as_string(fallback);
    return index(value, "\u0000") >= 0 || match(value, /^[0-9]+$/) == null ? 0 : int(value, 10);
}

return {
    as_string,
    object_or_empty,
    array_or_empty,
    signal_from_status,
    parse_json,
    read_json_file,
    write_json,
    parent_dir,
    ensure_dir,
    write_file,
    write_private_file,
    write_file_atomic,
    read_first_line,
    remove_tree,
    own_pid,
    pid_alive,
    now_seconds,
    monotonic_ms,
    strip_internal_fields,
    duration_to_seconds,
    parse_number,
    option,
    words,
    list_option,
    bool_value,
    bool_option,
    int_option
};
