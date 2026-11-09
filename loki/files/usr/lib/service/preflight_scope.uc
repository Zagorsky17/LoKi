let fs = require("fs");
let files = require("service.preflight_files");

const BYTE_LIMIT = 262144;
const ROW_LIMIT = 2048;
const NAMESPACE_LIMIT = 32;

function parse_mountinfo(data) {
    if (type(data) != "string" || data == "" || length(data) > BYTE_LIMIT ||
        index(data, "\u0000") >= 0 || substr(data, -1) != "\n" || !match(data, /^[ -~\n]+$/))
        return { error: "environment-mountinfo-invalid" };
    let lines = split(substr(data, 0, length(data) - 1), "\n");
    if (length(lines) > ROW_LIMIT) return { error: "environment-mountinfo-limit" };
    let root = 0;
    let proc = 0;
    let ids = {};
    for (let line in lines) {
        let columns = split(line, " ");
        let separator = index(columns, "-");
        if (separator < 6 || length(columns) != separator + 4 ||
            length(filter(columns, (value) => value == "" || value == "-")) != 1 ||
            !match(columns[0], /^[1-9][0-9]{0,9}$/) || !match(columns[1], /^[1-9][0-9]{0,9}$/) ||
            !match(columns[2], /^[0-9]{1,10}:[0-9]{1,10}$/) || exists(ids, columns[0]))
            return { error: "environment-mountinfo-invalid" };
        ids[columns[0]] = true;
        for (let path in [ columns[3], columns[4] ])
            if (substr(path, 0, 1) != "/" || index(replace(path, /\\(040|011|012|134)/g, ""), "\\") >= 0)
                return { error: "environment-mountinfo-invalid" };
        if (columns[4] == "/") root++;
        if (match(columns[4], /^\/proc\/[0-9]+(\/|$)/))
            return { error: "environment-proc-submount-unverified" };
        // Unrelated procfs helpers such as binfmt_misc do not hide these collectors' inputs.
        for (let observed in [ "/proc/self", "/proc/thread-self", "/proc/net", "/proc/meminfo", "/proc/sys/net" ])
            if (columns[4] != "/proc" && (columns[4] == observed || index(columns[4], observed + "/") == 0 ||
                index(observed, columns[4] + "/") == 0))
                return { error: "environment-proc-submount-unverified" };
        if (columns[4] != "/proc") continue;
        proc++;
        if (columns[3] != "/" || columns[separator + 1] != "proc")
            return { error: "environment-proc-mount-unverified" };
        for (let option in split(columns[separator + 3], ","))
            if ((index(option, "hidepid") == 0 && option != "hidepid=0") || index(option, "subset") == 0)
                return { error: "environment-proc-visibility-restricted" };
    }
    return root == 1 && proc == 1 ? {} : { error: "environment-proc-mount-unverified" };
}

function mountinfo() {
    let path = "/proc/self/mountinfo";
    let node = fs.lstat(path);
    if (node?.type != "file" || node.uid != 0 || node.nlink != 1 || (node.mode & 0022) != 0)
        return { error: "environment-mountinfo-unavailable" };
    let file = fs.open(path, "re");
    if (file == null) return { error: "environment-mountinfo-unavailable" };
    let result;
    try {
        let descriptor = "/proc/self/fd/" + file.fileno();
        if (!files.same_node(node, fs.stat(descriptor)))
            result = { error: "environment-mountinfo-changed" };
        else {
            fs.error();
            let data = file.read(BYTE_LIMIT + 1);
            let error = file.error();
            if (error != null || type(data) != "string") result = { error: "environment-mountinfo-read-failed" };
            else if (length(data) > BYTE_LIMIT) result = { error: "environment-mountinfo-limit" };
            else if (!files.same_node(node, fs.stat(descriptor)) || !files.same_node(node, fs.lstat(path)))
                result = { error: "environment-mountinfo-changed" };
            else {
                result = parse_mountinfo(data);
                if (result.error == null) result.data = data;
            }
        }
    }
    catch (e) { result = { error: "environment-mountinfo-read-failed" }; }
    try { if (file.close() !== true) result = { error: "environment-mountinfo-read-failed" }; }
    catch (e) { result = { error: "environment-mountinfo-read-failed" }; }
    return result;
}

function namespace_names(path) {
    let directory = fs.opendir(path);
    if (directory == null) return { error: "environment-namespace-unavailable" };
    let result = { names: [] };
    let seen = {};
    try {
        for (let count = 0; ; count++) {
            fs.error();
            let name = directory.read();
            let error = fs.error();
            if (error != null) { result = { error: "environment-namespace-unavailable" }; break; }
            if (name == null) break;
            if (count >= NAMESPACE_LIMIT || type(name) != "string" || index(name, "\u0000") >= 0 ||
                !match(name, /^(\.|\.\.|[a-z_]{1,32})$/) || exists(seen, name)) {
                result = { error: "environment-namespace-invalid" };
                break;
            }
            seen[name] = true;
            if (name != "." && name != "..") push(result.names, name);
        }
    }
    catch (e) { result = { error: "environment-namespace-unavailable" }; }
    try { if (directory.close() !== true) result = { error: "environment-namespace-unavailable" }; }
    catch (e) { result = { error: "environment-namespace-unavailable" }; }
    if (result.error == null && index(result.names, "mnt") < 0)
        result = { error: "environment-namespace-unavailable" };
    return result;
}

function snapshot() {
    // procfs, the running kernel and visible PID1 are trusted; their global origin is checked separately.
    try {
        let mounts = mountinfo();
        if (mounts.error != null) return mounts;
        let self = namespace_names("/proc/self/ns");
        let init = namespace_names("/proc/1/ns");
        if (self.error != null || init.error != null)
            return { error: self.error ?? init.error };
        if (join(",", sort(self.names)) != join(",", sort(init.names)))
            return { error: "environment-namespace-entries-differ" };
        let identities = {};
        for (let kind in [ "mnt", "net", "pid", "user" ]) {
            // Some OpenWrt kernels disable PID/user/net namespaces; a complete listing proves absence.
            if (index(self.names, kind) < 0) continue;
            let process = fs.readlink("/proc/self/ns/" + kind);
            let initial = fs.readlink("/proc/1/ns/" + kind);
            for (let value in [ process, initial ])
                if (type(value) != "string" || index(value, "\u0000") >= 0 ||
                    !match(value, regexp("^" + kind + ":\\[[1-9][0-9]{0,19}\\]$")))
                    return { error: "environment-namespace-invalid" };
            if (process != initial) return { error: "environment-namespace-differs-from-pid1" };
            identities[kind] = process;
        }
        let roots = [];
        for (let path in [ "/", "/proc/self/root", "/proc/1/root" ]) {
            let node = fs.stat(path);
            if (node?.type != "directory" || node.uid != 0 || (node.mode & 0022) != 0)
                return { error: "environment-root-unavailable-or-unsafe" };
            push(roots, { inode: node.inode, major: node.dev.major, minor: node.dev.minor, mode: node.mode });
        }
        if (sprintf("%J", roots[0]) != sprintf("%J", roots[1]) || sprintf("%J", roots[0]) != sprintf("%J", roots[2]))
            return { error: "environment-root-differs-from-pid1" };
        return { mounts: mounts.data, identities, root: roots[0] };
    }
    catch (e) { return { error: "environment-scope-unavailable" }; }
}

function check(first) {
    let second = snapshot();
    let error = first?.error ?? second.error;
    if (error == null && (type(first) != "object" || first.mounts != second.mounts ||
        sprintf("%J", first.identities) != sprintf("%J", second.identities) || sprintf("%J", first.root) != sprintf("%J", second.root)))
        error = "environment-scope-changed-during-read";
    return { kind: "environment", object: "namespace-layout", state: error == null ? "checked" : "incomplete",
        reason: error ?? "environment-pid1-relative-scope-checked" };
}

// The OS, kernel and package database are trusted; require the supported OpenWrt init profile.
function origin(root, platform, packages) {
    root = root == "/" ? "" : root;
    let result = { kind: "environment", object: "system-origin", state: "incomplete", reason: "openwrt-init-profile-unverified" };
    if (platform?.state != "checked" || type(platform.architecture) != "string" || type(packages) != "array") return result;
    for (let name in [ "base-files", "procd", "kernel" ])
        if (length(filter(packages, (package) => type(package) == "object" && package.name == name && type(package.version) == "string" && package.version != "")) != 1)
            return result;
    try {
        let executable = fs.readlink(root + "/proc/1/exe");
        if (index([ root + "/sbin/procd", root + "/usr/sbin/procd" ], executable) < 0) return result;
        let node = fs.lstat(executable), process = fs.stat(root + "/proc/1/exe");
        let owner = root == "" ? 0 : fs.stat(root)?.uid;
        if (node?.type != "file" || node.uid != owner || node.nlink != 1 || (node.mode & 07777) != 0755 ||
            !files.same_node(node, process) || fs.readlink(root + "/proc/1/exe") != executable) return result;
        result.state = "checked"; result.reason = "trusted-openwrt-init-profile-checked";
    }
    catch (e) {}
    return result;
}

return { snapshot, check, origin, parse_mountinfo };
