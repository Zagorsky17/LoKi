let fs = require("fs");

// Critical current package targets, not yet a complete install manifest.
const TARGETS = [
    "/etc/config/forkop", "/usr/bin/forkop", "/etc/init.d/forkop",
    "/etc/init.d/forkop-state", "/usr/share/forkop/default-config",
    "/usr/share/forkop/install.sh", "/lib/upgrade/keep.d/forkop",
    "/usr/share/nftables.d/chain-pre/input/forkop.nft",
    "/etc/uci-defaults/50_luci-forkop",
    "/usr/share/rpcd/acl.d/luci-app-forkop.json",
    "/usr/share/luci/menu.d/luci-app-forkop.json",
    "/www/luci-static/resources/view/forkop/main.js",
    "/usr/bin/sing-box", "/etc/init.d/sing-box",
    "/etc/config/sing-box", "/etc/sing-box/config.json"
];
const OWN_NAMES = [ "forkop", "luci-app-forkop", "sing-box-forkop" ];
const STATUS_LIMIT = 4194304;
const LIST_LIMIT = 1048576;
const TOTAL_LIMIT = 16777216;
const PACKAGE_LIMIT = 4096;

function same_file(a, b) {
    return a != null && b != null && a.type == "file" && b.type == "file" &&
        a.inode == b.inode && a.dev.major == b.dev.major && a.dev.minor == b.dev.minor &&
        a.size == b.size && a.mtime == b.mtime && a.ctime == b.ctime &&
        a.uid == b.uid && a.mode == b.mode && a.nlink == b.nlink;
}

function read_metadata(path, limit, root) {
    root = root || "/";
    let base = fs.lstat(root);
    let prefix = root == "/" ? "" : root;
    let owner = root == "/" ? 0 : base?.uid;
    if (base?.type != "directory" || base.uid != owner || (base.mode & 0022) != 0 ||
        substr(path, 0, length(prefix) + 1) != prefix + "/")
        return { error: "unsafe-root" };
    let parent = prefix;
    let parts = split(substr(path, length(prefix)), "/");
    for (let i = 1; i < length(parts) - 1; i++) {
        parent += "/" + parts[i];
        let stat = fs.lstat(parent);
        if (stat?.type != "directory" || stat.uid != owner || (stat.mode & 0022) != 0)
            return { error: "unsafe-parent-path" };
    }
    let before = fs.lstat(path);
    if (before == null)
        return { error: "unavailable" };
    if (before.type != "file")
        return { error: "not-regular-file" };
    if (before.uid != owner)
        return { error: "unsafe-owner" };
    if ((before.mode & 0022) != 0)
        return { error: "unsafe-mode" };
    if (before.nlink != 1)
        return { error: "hardlinked-file" };
    if (before.size > limit)
        return { error: "size-limit" };
    let file = fs.open(path, "re");
    if (file == null)
        return { error: "open-failed" };
    // Check the opened inode before reading: lstat alone cannot pin a pathname.
    let opened = fs.stat("/proc/self/fd/" + file.fileno());
    if (!same_file(before, opened)) {
        file.close();
        return { error: "changed-during-read" };
    }
    fs.error();
    let data = file.read(limit + 1);
    let error = file.error();
    let after = fs.stat("/proc/self/fd/" + file.fileno());
    file.close();
    let bytes = type(data) == "string" ? length(data) : limit + 1;
    if (error != null || type(data) != "string")
        return { error: "read-failed", bytes };
    if (length(data) > limit)
        return { error: "size-limit", bytes };
    if (length(data) != before.size || !same_file(before, after) || !same_file(before, fs.lstat(path)))
        return { error: "changed-during-read", bytes };
    if (index(data, "\u0000") >= 0)
        return { error: "nul-byte", bytes };
    return { data, bytes };
}

function packages_from_status(data) {
    if (type(data) != "string" || trim(data) == "" || length(data) > STATUS_LIMIT || index(data, "\u0000") >= 0)
        return null;
    let packages = [];
    let seen = {};
    for (let stanza in split(replace(data, /\n+$/, ""), /\n\n+/)) {
        if (stanza == "")
            continue;
        let fields = {};
        let previous = "";
        for (let line in split(stanza, "\n")) {
            if (match(line, /^[ \t]/)) {
                if (previous == "" || previous == "Package" || previous == "Status")
                    return null;
                continue;
            }
            let field = match(line, /^([A-Za-z][A-Za-z0-9-]*):[ \t]*(.*)$/);
            if (field == null || exists(fields, field[1]))
                return null;
            fields[field[1]] = field[2];
            previous = field[1];
        }
        let name = fields.Package;
        let status = fields.Status;
        if (type(name) != "string" || !match(name, /^[a-z0-9][a-z0-9+.-]{0,127}$/) ||
            exists(seen, name) || type(status) != "string")
            return null;
        seen[name] = true;
        // Unknown or half-installed states cannot prove ownership coverage.
        let state = match(status, /^(install|deinstall|purge|unknown) [a-z,-]+ (installed|not-installed|config-files)$/);
        if (state == null || length(keys(seen)) > PACKAGE_LIMIT)
            return null;
        if (state[2] == "installed")
            push(packages, name);
    }
    return packages;
}

function target_paths(data) {
    if (type(data) != "string" || data == "" || length(data) > LIST_LIMIT ||
        substr(data, -1) != "\n" || index(data, "\u0000") >= 0)
        return null;
    let found = [];
    let seen = {};
    for (let path in split(substr(data, 0, length(data) - 1), "\n")) {
        if (length(path) > 4096 || !match(path, /^\/[A-Za-z0-9_.+@\/-]*$/) || index(path, "//") >= 0 ||
            match(path, /\/(\.\.?)(\/|$)/) || exists(seen, path))
            return null;
        seen[path] = true;
        if (index(TARGETS, path) >= 0)
            push(found, path);
    }
    return found;
}

function observation(kind, object, state, reason) {
    return { kind, object, state, reason };
}

function collect(root) {
    // The CLI always passes "/". A fixture root is only an in-process test seam.
    root = root == "/" ? "" : root;
    let observations = [];
    let opkg = root + "/usr/lib/opkg";
    let apk = fs.lstat(root + "/lib/apk/db/installed");
    let status = fs.lstat(opkg + "/status");
    if (apk != null || status == null) {
        push(observations, observation("ownership", "package-database", "incomplete",
            apk != null && status != null ? "multiple-package-databases" :
            apk != null ? "apk-reader-not-implemented" : "opkg-database-unavailable"));
    }
    else {
        let status_read = read_metadata(opkg + "/status", STATUS_LIMIT, root || "/");
        let data = status_read.data;
        let packages = packages_from_status(data);
        let complete = packages != null;
        // Reserve the status recheck within the aggregate read budget.
        let total = 2 * (status_read.bytes || 0) + 1;
        let conflicts = {};
        let uncertain = {};
        let failures = {};
        if (status_read.error != null)
            failures["status-" + status_read.error] = "opkg-status";
        else if (packages == null)
            failures[length(split(trim(data), /\n\n+/)) > PACKAGE_LIMIT ? "package-count-limit" : "status-invalid"] = "opkg-status";
        let ordinal = 0;
        for (let name in packages || []) {
            ordinal++;
            let remaining = TOTAL_LIMIT - total;
            if (remaining <= 1) {
                complete = false;
                failures["aggregate-byte-limit"] = "opkg-metadata";
                break;
            }
            let read = read_metadata(opkg + "/info/" + name + ".list", min(LIST_LIMIT, remaining - 1), root || "/");
            let listing = read.data;
            total += read.bytes || 0;
            if (read.error == "size-limit" && remaining - 1 < LIST_LIMIT) {
                complete = false;
                failures["aggregate-byte-limit"] = "opkg-metadata";
                break;
            }
            let targets = target_paths(listing);
            if (targets == null) {
                complete = false;
                let reason = read.error == null ? "ownership-list-invalid" : "ownership-list-" + read.error;
                if (!exists(failures, reason))
                    failures[reason] = "installed-package-list-" + ordinal;
                continue;
            }
            for (let path in targets) {
                if (index(OWN_NAMES, name) >= 0)
                    uncertain[path] = true;
                else
                    conflicts[path] = true;
            }
        }
        for (let path in TARGETS) {
            if (conflicts[path])
                push(observations, observation("ownership", path, "conflict", "foreign-package-owns-candidate-path"));
            if (uncertain[path])
                push(observations, observation("ownership", path, "incomplete", "package-name-does-not-prove-own-origin"));
        }
        if (status_read.error == null) {
            let final_status = read_metadata(opkg + "/status", length(data), root || "/");
            if (data != final_status.data || final_status.error != null) {
                complete = false;
                failures["status-changed-or-unavailable-on-recheck"] = "opkg-status";
            }
        }
        for (let reason in sort(keys(failures)))
            push(observations, observation("ownership", failures[reason], "incomplete", reason));
        if (complete)
            push(observations, observation("ownership", "installed-opkg-critical-paths", "checked", "metadata-read-complete"));
    }
    // Unimplemented domains are mandatory; a partial inventory never grants permission.
    for (let kind in [ "candidate-manifest", "files", "services", "autostart", "hooks", "listeners",
        "dns-committed", "dns-pending", "dns-runtime", "nft-loaded", "nft-persisted",
        "ipv4-routes-rules", "ipv6-routes-rules", "dependencies", "resources", "configuration", "core-check" ])
        push(observations, observation(kind, kind, "incomplete", "not-implemented"));
    let conflict = false;
    for (let item in observations)
        if (item.state == "conflict")
            conflict = true;
    return { schema: 1, result: conflict ? "conflict" : "incomplete", complete: false,
        install_allowed: false, observations };
}

return { collect, packages_from_status, target_paths, read_metadata };
