let fs = require("fs");

const CONFIG_LIMIT = 1048576;

function item(state, reason) {
    return { kind: "configuration", object: "candidate-config", state, reason };
}

function cleanup(config, delta, made_config, made_delta, made_files) {
    let okay = true;
    for (let name in made_files)
        if (fs.unlink(config + "/" + name) !== true) okay = false;
    if (made_delta && fs.rmdir(delta) !== true) okay = false;
    if (made_config && fs.rmdir(config) !== true) okay = false;
    return okay;
}

function stage(config, name, data, owner, made_files) {
    let path = config + "/" + name;
    let file = fs.open(path, "wx", 0600);
    if (file == null) return false;
    push(made_files, name);
    let written = null;
    let closed = false;
    try { written = file.write(data); }
    catch (e) { written = null; }
    try { closed = file.close(); }
    catch (e) { closed = false; }
    let stat = fs.lstat(path);
    return written === length(data) && closed === true && stat?.type == "file" &&
        stat.size == length(data) && stat.uid == owner && (stat.mode & 0777) == 0600 && stat.nlink == 1;
}

function generation(native, model, config, owner, made_files, platform) {
    let models = {};
    for (let name in [ "dhcp", "system" ]) {
        let data = platform?.[name];
        if (type(data) != "string")
            return item("incomplete", "candidate-platform-config-unavailable");
        if (length(data) > CONFIG_LIMIT || index(data, "\u0000") >= 0)
            return item("incomplete", "candidate-platform-config-invalid");
        if (!stage(config, name, data, owner, made_files))
            return item("incomplete", "candidate-platform-stage-failed");
        try {
            if (native.load(name) !== true)
                return item("incomplete", "candidate-platform-parse-failed");
            models[name] = require("config.migration").model_from_cursor(native, name);
            if (models[name] == null)
                return item("incomplete", "candidate-platform-parse-failed");
        }
        catch (e) { return item("incomplete", "candidate-platform-parse-failed"); }
    }
    let credential;
    try { credential = require("service.gateway_secret").generate(); }
    catch (e) { return item("incomplete", "candidate-credential-unavailable"); }
    try {
        let generated = require("singbox.generator").build_candidate(model, models, { controller_secret: credential });
        return item("checked", generated == null ? "uci-generation-empty" : "uci-generation-checked");
    }
    catch (e) { return item("incomplete", "candidate-generation-failed"); }
}

function inspect(config, delta, data, owner, made_files, platform) {
    if (!stage(config, "loki", data, owner, made_files))
        return [ item("incomplete", "scratch-write-failed") ];
    let native = null;
    try { native = require("uci").cursor(config, delta, ""); }
    catch (e) { native = null; }
    if (native == null)
        return [ item("incomplete", "uci-unavailable") ];
    try {
        if (native.load("loki") !== true)
            return [ item("incomplete", "uci-load-failed") ];
    }
    catch (e) { return [ item("incomplete", "uci-load-failed") ]; }
    let decision = null;
    let model = null;
    try {
        let migration = require("config.migration");
        model = migration.model_from_cursor(native, "loki");
        if (model != null) decision = migration.decide(model);
    }
    catch (e) { decision = null; }
    let result = [ item("checked", "uci-syntax-checked") ];
    if (decision?.result != "current") {
        let reason = decision?.result == "migrate" ? "candidate-schema-migration-required" :
            decision?.result == "reject" && index([ "foreign", "schema", "missing", "invalid", "newer", "below_min", "unknown" ], decision.reason) >= 0
                ? "candidate-schema-" + decision.reason : "candidate-schema-unavailable";
        push(result, item("incomplete", reason));
        return result;
    }
    push(result, item("checked", "uci-schema-checked"));
    try { require("config.validator").validate_candidate(model); }
    catch (e) {
        push(result, item("incomplete", "candidate-config-values-invalid"));
        return result;
    }
    push(result, item("checked", "uci-values-checked"));
    push(result, generation(native, model, config, owner, made_files, platform));
    push(result, item("incomplete", "candidate-core-unverified"));
    return result;
}

function check(data, scratch, platform) {
    if (type(data) != "string" || index(data, "\u0000") >= 0)
        return [ item("incomplete", "candidate-config-invalid") ];
    if (length(data) > CONFIG_LIMIT)
        return [ item("incomplete", "candidate-config-size-limit") ];
    let directory = type(scratch) == "string" ? fs.lstat(scratch) : null;
    let owner = fs.stat("/proc/self/status")?.uid;
    if (type(scratch) != "string" || !match(scratch, /^\/[A-Za-z0-9_.+@\/-]+$/) ||
        index(scratch, "//") >= 0 || match(scratch, /\/(\.\.?)(\/|$)/) ||
        directory?.type != "directory" || (directory.mode & 0777) != 0700 ||
        owner == null || directory.uid != owner)
        return [ item("incomplete", "scratch-unsafe") ];

    let config = scratch + "/config";
    let delta = scratch + "/delta";
    let made_files = [];
    let made_config = fs.mkdir(config) === true;
    let made_delta = made_config && fs.mkdir(delta) === true;
    let result = [ item("incomplete", "scratch-write-failed") ];
    try {
        if (made_delta && fs.chmod(config, 0700) === true && fs.chmod(delta, 0700) === true)
            result = inspect(config, delta, data, owner, made_files, platform);
    }
    catch (e) { result = [ item("incomplete", "candidate-check-failed") ]; }
    let cleaned = false;
    try { cleaned = cleanup(config, delta, made_config, made_delta, made_files); }
    catch (e) { cleaned = false; }
    if (!cleaned)
        return [ item("incomplete", "scratch-cleanup-failed") ];
    return result;
}

return { check };
