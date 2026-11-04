let fs = require("fs");
let apk_reader = require("service.preflight_apk");
let manifest_reader = require("service.preflight_manifest");
let files_reader = require("service.preflight_files");
let services_reader = require("service.preflight_services");
let listeners_reader = require("service.preflight_listeners");

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
const OWN_NAMES = [ "forkop", "luci-app-forkop", "sing-box-forkop", "luci-i18n-forkop-ru" ];
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

function target_paths(data, targets) {
    if (targets == null) {
        targets = {};
        for (let path in TARGETS) targets[path] = true;
    }
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
        if (exists(targets, path))
            push(found, path);
    }
    return found;
}

function observation(kind, object, state, reason) {
    return { kind, object, state, reason };
}

function collect(root, manifest_path) {
    // The CLI always passes "/". A fixture root is only an in-process test seam.
    root = root == "/" ? "" : root;
    let observations = [];
    let targets = map(TARGETS, (path) => path);
    let labels = {};
    let file_targets = {};
    for (let path in TARGETS) {
        labels[path] = path;
        file_targets[path] = "file";
    }
    if (manifest_path == null) {
        push(observations, observation("candidate-manifest", "candidate-manifest", "incomplete", "manifest-not-provided"));
    }
    else {
        let read = read_metadata(manifest_path, 2097152, root || "/");
        let manifest = read.error == null ? manifest_reader.parse(read.data) : { error: "manifest-" + read.error };
        if (manifest.error != null)
            push(observations, observation("candidate-manifest", "candidate-manifest", "incomplete", manifest.error));
        else {
            let ordinal = 0;
            let directories = 0;
            for (let path in sort(keys(manifest.paths))) {
                let expected = manifest.paths[path].type;
                if (expected == "directory") {
                    directories++;
                    if (exists(file_targets, path) && file_targets[path] != expected)
                        push(observations, observation("candidate-manifest", labels[path], "conflict", "critical-file-target-type-mismatch"));
                    else {
                        file_targets[path] = expected;
                        labels[path] = "candidate-directory-" + directories;
                    }
                    continue;
                }
                ordinal++;
                if (!exists(labels, path)) {
                    push(targets, path);
                    labels[path] = "candidate-file-" + ordinal;
                }
                file_targets[path] = "file";
            }
            push(observations, observation("candidate-manifest", "candidate-manifest", "incomplete", "artifact-provenance-unverified"));
            push(observations, observation("candidate-manifest", "candidate-manifest", "incomplete", "artifact-content-unverified"));
            push(observations, observation("candidate-manifest", "candidate-manifest", "incomplete", "candidate-component-set-unverified"));
        }
    }
    let opkg = root + "/usr/lib/opkg";
    let apk = fs.lstat(root + "/lib/apk/db/installed");
    let status = fs.lstat(opkg + "/status");
    if (apk != null && status != null) {
        push(observations, observation("ownership", "package-database", "incomplete", "multiple-package-databases"));
    }
    else if (apk != null) {
        let path = root + "/lib/apk/db/installed";
        let read = read_metadata(path, STATUS_LIMIT, root || "/");
        let parsed = read.error == null ? apk_reader.parse(read.data) : { error: "apk-installed-" + read.error };
        if (parsed.error != null)
            push(observations, observation("ownership", "apk-installed", "incomplete", parsed.error));
        else {
            let owners = {};
            for (let package in parsed.packages) {
                for (let entry in package.entries) {
                    if (!exists(labels, entry.path))
                        continue;
                    if (owners[entry.path] == null)
                        owners[entry.path] = [];
                    push(owners[entry.path], package.name);
                }
            }
            for (let target in targets) {
                let names = owners[target] || [];
                if (length(names) > 1)
                    push(observations, observation("ownership", labels[target], "conflict", "multiple-packages-claim-candidate-path"));
                else if (length(names) == 1)
                    push(observations, observation("ownership", labels[target],
                        index(OWN_NAMES, names[0]) >= 0 ? "incomplete" : "conflict",
                        index(OWN_NAMES, names[0]) >= 0 ? "package-name-does-not-prove-own-origin" : "foreign-package-owns-candidate-path"));
            }
            // The same bounded database is reread; no apk lock or scripts are involved.
            let final_read = read_metadata(path, length(read.data), root || "/");
            if (final_read.error != null || read.data != final_read.data)
                push(observations, observation("ownership", "apk-installed", "incomplete", "apk-changed-or-unavailable-on-recheck"));
            else
                push(observations, observation("ownership", "installed-apk-candidate-files", "checked", "metadata-read-complete"));
        }
    }
    else if (status == null) {
        push(observations, observation("ownership", "package-database", "incomplete", "package-database-unavailable"));
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
            let listed_targets = target_paths(listing, labels);
            if (listed_targets == null) {
                complete = false;
                let reason = read.error == null ? "ownership-list-invalid" : "ownership-list-" + read.error;
                if (!exists(failures, reason))
                    failures[reason] = "installed-package-list-" + ordinal;
                continue;
            }
            for (let path in listed_targets) {
                if (index(OWN_NAMES, name) >= 0)
                    uncertain[path] = true;
                else
                    conflicts[path] = true;
            }
        }
        for (let path in targets) {
            if (conflicts[path])
                push(observations, observation("ownership", labels[path], "conflict", "foreign-package-owns-candidate-path"));
            if (uncertain[path])
                push(observations, observation("ownership", labels[path], "incomplete", "package-name-does-not-prove-own-origin"));
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
            push(observations, observation("ownership", "installed-opkg-candidate-files", "checked", "metadata-read-complete"));
    }
    for (let item in files_reader.collect(root || "/", file_targets))
        push(observations, observation("files", labels[item.path], item.state, item.reason));
    for (let item in services_reader.collect(root || "/"))
        push(observations, item);
    for (let item in listeners_reader.collect(root || "/"))
        push(observations, item);
    // Unimplemented domains are mandatory; a partial inventory never grants permission.
    for (let kind in [ "hooks",
        "dns-committed", "dns-pending", "dns-runtime", "nft-loaded", "nft-persisted",
        "ipv4-routes-rules", "ipv6-routes-rules", "dependencies", "resources", "configuration", "core-check" ])
        push(observations, observation(kind, kind, "incomplete", "not-implemented"));
    let conflict = false;
    for (let item in observations)
        if (item.state == "conflict")
            conflict = true;
    if (length(observations) > 256) {
        // Keep the final mandatory-domain failures as well as the first conflicts.
        splice(observations, 224, length(observations) - 255);
        push(observations, observation("report", "ownership-observations", "incomplete", "observation-count-limit"));
    }
    return { schema: 1, result: conflict ? "conflict" : "incomplete", complete: false,
        install_allowed: false, observations };
}

return { collect, packages_from_status, target_paths, read_metadata };
