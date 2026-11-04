let fs = require("fs");
let files = require("service.preflight_files");

const RESPONSE_LIMIT = 262144;
const ENTRY_LIMIT = 4096;
const KNOWN = { loki: true, "loki-state": true, "loki-core": true,
    forkop: false, "forkop-state": false, "sing-box": false, podkop: false };

function observation(kind, object, state, reason) {
    return { kind, object, state, reason };
}

function parse(data) {
    if (type(data) != "string" || length(data) > RESPONSE_LIMIT || index(data, "\u0000") >= 0)
        return { error: "service-response-invalid" };
    let value;
    try { value = json(data); }
    catch (e) { return { error: "service-response-json-invalid" }; }
    if (type(value) != "object" || length(keys(value)) > ENTRY_LIMIT)
        return { error: "service-response-shape-invalid" };
    let known = [];
    let count = 0;
    for (let name in sort(keys(value))) {
        let service = value[name];
        if (name == "" || length(name) > 255 || index(name, "\u0000") >= 0 || type(service) != "object" ||
            (exists(service, "autostart") && type(service.autostart) != "bool") ||
            (exists(service, "triggers") && type(service.triggers) != "array") ||
            (exists(service, "instances") && type(service.instances) != "object"))
            return { error: "service-response-shape-invalid" };
        let active = false;
        let pending = service.triggers != null && length(service.triggers) > 0;
        for (let id, instance in service.instances || {}) {
            count++;
            if (count > ENTRY_LIMIT || id == "" || length(id) > 255 || index(id, "\u0000") >= 0 ||
                type(instance) != "object" || type(instance.running) != "bool" ||
                (exists(instance, "respawn") && type(instance.respawn) != "object") ||
                (instance.running && (type(instance.pid) != "int" || instance.pid <= 0 || instance.pid > 4294967295)) ||
                (!instance.running && exists(instance, "pid")))
                return { error: "service-response-shape-invalid" };
            active = active || instance.running;
            pending = pending || instance.respawn != null;
        }
        if (exists(KNOWN, name))
            push(known, { name, active, pending });
    }
    return { known, services: length(keys(value)), instances: count };
}

function probe() {
    // The fixed read-only method never incorporates names or arguments from the response.
    let pipe = fs.popen("exec timeout -s KILL 5 ubus call service list '{\"verbose\":true}' 2>/dev/null", "r");
    if (pipe == null)
        return { error: "service-query-failed" };
    let data;
    let status;
    let failed = false;
    try { data = pipe.read(RESPONSE_LIMIT + 1); }
    catch (e) { failed = true; }
    try { status = pipe.close(); }
    catch (e) { failed = true; }
    if (type(data) == "string" && length(data) > RESPONSE_LIMIT)
        return { error: "service-response-size-limit" };
    if (failed || status != 0 || type(data) != "string")
        return { error: "service-query-failed" };
    return parse(data);
}

function enabled_entry(root, directory, entry, name) {
    let path = directory + "/" + entry;
    let node = fs.lstat(path);
    let owner = root == "" ? 0 : fs.lstat(root)?.uid;
    if (node == null || node.uid != owner || node.nlink != 1)
        return { state: "incomplete", reason: "autostart-entry-unverified" };
    if (node.type == "link") {
        let target = fs.readlink(path);
        if (!files.same_node(node, fs.lstat(path)))
            return { state: "incomplete", reason: "autostart-entry-changed" };
        let init = "/etc/init.d/" + name;
        if (target != "../init.d/" + name && target != init)
            return { state: "incomplete", reason: "autostart-link-target-unverified" };
        let targets = {};
        targets[init] = "file";
        let result = files.collect(root || "/", targets)[0];
        if (result.reason == "candidate-path-absent")
            return { state: "checked", reason: "autostart-dangling-link" };
        if (result.reason != "candidate-existing-file-origin-unverified")
            return { state: "incomplete", reason: "autostart-entry-unverified" };
        path = root + init;
        node = fs.lstat(path);
    }
    if (node?.type != "file" || node.uid != owner || node.nlink != 1 || (node.mode & 0022) != 0)
        return { state: "incomplete", reason: "autostart-entry-unverified" };
    let executable = (node.mode & 0111) != 0;
    if (!files.same_node(node, fs.lstat(path)))
        return { state: "incomplete", reason: "autostart-entry-changed" };
    return { state: executable ? "incomplete" : "checked",
        reason: executable ? "enabled-service-origin-unverified" : "autostart-entry-not-executable" };
}

function autostart(root) {
    let directory = root + "/etc/rc.d";
    let checked = files.collect(root || "/", { "/etc/rc.d": "directory" })[0];
    if (checked.reason != "candidate-directory-safe")
        return [ observation("autostart", "rc-directory", "incomplete", "autostart-directory-unavailable") ];
    let before = fs.lstat(directory);
    fs.error();
    let handle = fs.opendir(directory);
    if (handle == null)
        return [ observation("autostart", "rc-directory", "incomplete", "autostart-directory-read-failed") ];
    let result = [];
    let count = 0;
    let error = null;
    let unknown = false;
    try {
        while (true) {
            if (count >= ENTRY_LIMIT) { error = "autostart-directory-entry-limit"; break; }
            fs.error();
            let entry = handle.read();
            let failure = fs.error();
            if (entry == null) {
                if (failure != null) error = "autostart-directory-read-failed";
                break;
            }
            count++;
            if (substr(entry, 0, 1) != "S") continue;
            let matched = match(entry, /^S[0-9][0-9]([A-Za-z0-9_-]+)$/);
            if (matched == null || !exists(KNOWN, matched[1])) { unknown = true; continue; }
            let status = enabled_entry(root, directory, entry, matched[1]);
            push(result, observation("autostart", "service-" + matched[1], status.state, status.reason));
        }
    }
    catch (e) { error = "autostart-directory-read-failed"; }
    handle.close();
    if (!files.same_node(before, fs.lstat(directory)))
        error = "autostart-directory-changed";
    if (error != null)
        return [ observation("autostart", "rc-directory", "incomplete", error) ];
    if (unknown)
        push(result, observation("autostart", "rc-directory", "incomplete", "unclassified-autostart-entry"));
    push(result, observation("autostart", "rc-directory", "checked", "autostart-directory-read-complete"));
    return result;
}

function collect(root) {
    root = root == "/" ? "" : root;
    let result = [];
    let services = probe();
    if (services.error != null)
        push(result, observation("services", "procd-snapshot", "incomplete", services.error));
    else {
        for (let service in services.known) {
            let reason = service.active ? (KNOWN[service.name] ? "existing-service-origin-unverified" : "foreign-service-active-unverified")
                : service.pending ? "service-restart-trigger-unverified" : "known-service-inactive";
            push(result, observation("services", "service-" + service.name,
                service.active || service.pending ? "incomplete" : "checked", reason));
        }
        push(result, observation("services", "procd-snapshot", "checked", "service-snapshot-read-complete"));
    }
    for (let item in autostart(root)) push(result, item);
    // Discovery does not establish process identity, hook safety or component provenance.
    push(result, observation("services", "process-and-origin", "incomplete", "service-process-and-origin-unverified"));
    push(result, observation("autostart", "hook-provenance", "incomplete", "autostart-hook-provenance-unverified"));
    return result;
}

return { collect, parse };
