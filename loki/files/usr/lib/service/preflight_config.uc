let fs = require("fs");

const CONFIG_LIMIT = 1048576;

function item(state, reason) {
    return { kind: "configuration", object: "candidate-config", state, reason };
}

function cleanup(config, delta, made_config, made_delta, made_file) {
    let okay = !made_file || fs.unlink(config + "/loki") === true;
    if (made_delta && fs.rmdir(delta) !== true) okay = false;
    if (made_config && fs.rmdir(config) !== true) okay = false;
    return okay;
}

function check(data, scratch) {
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
    let result = [ item("incomplete", "scratch-write-failed") ];
    let made_config = fs.mkdir(config) === true;
    let made_delta = made_config && fs.mkdir(delta) === true;
    let made_file = false;
    if (made_delta &&
        fs.chmod(config, 0700) === true && fs.chmod(delta, 0700) === true) {
        let file = fs.open(config + "/loki", "wx", 0600);
        if (file != null) {
            made_file = true;
            let written = file.write(data);
            let closed = file.close();
            let stat = fs.lstat(config + "/loki");
            if (written == length(data) && closed === true && stat?.type == "file" && stat.size == length(data) &&
                stat.uid == owner && (stat.mode & 0777) == 0600 && stat.nlink == 1) {
                let native = null;
                try { native = require("uci").cursor(config, delta, ""); }
                catch (e) { native = null; }
                if (native == null)
                    result = [ item("incomplete", "uci-unavailable") ];
                else {
                    let loaded = false;
                    try { loaded = native.load("loki") === true; }
                    catch (e) { loaded = false; }
                    if (loaded) {
                        let decision = null;
                        let model = null;
                        try {
                            let migration = require("config.migration");
                            model = migration.model_from_cursor(native, "loki");
                            if (model != null) decision = migration.decide(model);
                        }
                        catch (e) { decision = null; }
                        let reason = decision?.result == "current" ? "candidate-core-unverified" :
                            decision?.result == "migrate" ? "candidate-schema-migration-required" :
                            decision?.result == "reject" && index([ "foreign", "schema", "missing", "invalid", "newer", "below_min", "unknown" ], decision.reason) >= 0
                                ? "candidate-schema-" + decision.reason : "candidate-schema-unavailable";
                        result = [ item("checked", "uci-syntax-checked") ];
                        if (decision?.result == "current") {
                            push(result, item("checked", "uci-schema-checked"));
                            let valid = false;
                            try { require("config.validator").validate_candidate(model); valid = true; }
                            catch (e) { valid = false; }
                            if (valid)
                                push(result, item("checked", "uci-values-checked"));
                            else
                                reason = "candidate-config-values-invalid";
                        }
                        push(result, item("incomplete", reason));
                    }
                    else
                        result = [ item("incomplete", "uci-load-failed") ];
                }
            }
        }
    }
    if (!cleanup(config, delta, made_config, made_delta, made_file))
        return [ item("incomplete", "scratch-cleanup-failed") ];
    return result;
}

return { check };
