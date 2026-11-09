let fs = require("fs");
let apk_reader = require("service.preflight_apk");
let manifest_reader = require("service.preflight_manifest");
let files_reader = require("service.preflight_files");
let services_reader = require("service.preflight_services");
let listeners_reader = require("service.preflight_listeners");
let processes_reader = require("service.preflight_processes");
let rules_reader = require("service.preflight_rules");
let nft_reader = require("service.preflight_nft");
let resources_reader = require("service.preflight_resources");
let config_reader = require("service.preflight_config");
let scope_reader = require("service.preflight_scope");
let dependencies_reader = require("service.preflight_dependencies");

// Critical current package targets, not yet a complete install manifest.
const TARGETS = [
    "/etc/config/loki", "/usr/bin/loki", "/etc/init.d/loki",
    "/etc/init.d/loki-state", "/usr/share/loki/default-config",
    "/usr/share/loki/install.sh", "/lib/upgrade/keep.d/loki",
    "/usr/share/nftables.d/chain-pre/input/loki.nft",
    "/etc/uci-defaults/50_luci-loki",
    "/usr/share/rpcd/acl.d/luci-app-loki.json",
    "/usr/share/luci/menu.d/luci-app-loki.json",
    "/www/luci-static/resources/view/loki/main.js",
    "/usr/bin/loki-core", "/etc/init.d/loki-core",
    "/etc/config/loki-core", "/etc/loki-core/config.json"
];
const OWN_NAMES = [ "loki", "luci-app-loki", "loki-core", "luci-i18n-loki-ru" ];
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

function close_ok(file) {
    try { return file.close() === true; }
    catch (e) { return false; }
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
        close_ok(file);
        return { error: "changed-during-read" };
    }
    fs.error();
    let data = file.read(limit + 1);
    let error = file.error();
    let after = fs.stat("/proc/self/fd/" + file.fileno());
    let closed = close_ok(file);
    let bytes = type(data) == "string" ? length(data) : limit + 1;
    if (error != null || type(data) != "string" || !closed)
        return { error: "read-failed", bytes };
    if (length(data) > limit)
        return { error: "size-limit", bytes };
    if (length(data) != before.size || !same_file(before, after) || !same_file(before, fs.lstat(path)))
        return { error: "changed-during-read", bytes };
    if (index(data, "\u0000") >= 0)
        return { error: "nul-byte", bytes };
    return { data, bytes };
}

function package_records_from_status(data) {
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
                if (previous == "Depends" || previous == "Provides" || previous == "Version")
                    fields[previous] += " " + trim(line);
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
            push(packages, { name, version: fields.Version, depends: fields.Depends ?? "", provides: fields.Provides ?? "" });
    }
    return packages;
}

function packages_from_status(data) {
    let packages = package_records_from_status(data);
    return packages == null ? null : map(packages, (package) => package.name);
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

function release_status(data) {
    if (type(data) != "string" || data == "" || length(data) > 16384 ||
        substr(data, -1) != "\n" || index(data, "\u0000") >= 0)
        return { state: "incomplete", reason: "openwrt-release-invalid" };
    let values = {};
    for (let line in split(substr(data, 0, length(data) - 1), "\n")) {
        if (!match(line, /^DISTRIB_(ID|RELEASE|ARCH)/)) continue;
        let field = match(line, /^DISTRIB_(ID|RELEASE|ARCH)='([^']*)'$/);
        if (field == null || exists(values, field[1]))
            return { state: "incomplete", reason: "openwrt-release-invalid" };
        values[field[1]] = field[2];
    }
    if (values.ID == null || values.ID == "" || values.RELEASE == null || values.RELEASE == "")
        return { state: "incomplete", reason: "openwrt-release-invalid" };
    if (values.ID != "OpenWrt")
        return { state: "conflict", reason: "unsupported-openwrt-id" };
    if (!match(values.RELEASE, /^(24\.10|25\.12)\.(0|[1-9][0-9]*)$/))
        return { state: "conflict", reason: "unsupported-openwrt-release" };
    if (values.ARCH != null && !match(values.ARCH, /^[A-Za-z0-9][A-Za-z0-9_.+~-]{0,127}$/))
        return { state: "incomplete", reason: "openwrt-release-invalid" };
    let status = { state: "checked", reason: "openwrt-release-supported" };
    if (values.ARCH != null) status.architecture = values.ARCH;
    return status;
}

function owned_components(root) {
    let result = { files: {}, token: null };
    let update = require("service.update");
    if (update.paths.payload_root != (root || "/")) return result;
    try {
        let record = update.read();
        if (record?.error) die("invalid-record");
        let value = update.installed();
        if (value != null) {
            result.format = value.format;
            result.components = value.components;
            result.token = value.digest + ":" + sprintf("%J", record);
            for (let component in value.components)
                for (let file in component.files)
                    if (file.type == "file") result.files[file.path] = { ...file, package: component.package, version: component.version };
        }
        else if (!update.pending() && (record?.phase == "committed" && record.operation == "uninstall" ||
            record?.operation == "install" && index([ "aborted", "rolled-back" ], record.phase) >= 0)) {
            result.retained = true;
            result.token = "retained:" + sprintf("%J", record);
            for (let path in [ "/etc/config/loki", "/etc/config/loki-core" ]) result.files[path] = { mode: 0600 };
        }
    }
    catch (e) { return { files: {}, error: true, token: null }; }
    return result;
}

function own_path(proof, path, names, format, versions, complete) {
    let file = proof.files[path];
    if (!complete || file == null) return false;
    if (proof.retained) return length(names) == 0;
    return proof.format == format && length(names) == 1 && file.package == names[0] && file.version == versions[names[0]];
}

const REQUIRED_PROOFS = [
    [ "platform", "openwrt-release" ], [ "platform", "requirements" ],
    [ "environment", "namespace-layout" ], [ "environment", "system-origin" ],
    [ "candidate-manifest", "candidate-manifest" ], [ "candidate-manifest", "package-format" ],
    [ "candidate-manifest", "architecture" ], [ "candidate-manifest", "component-set" ],
    [ "ownership" ], [ "files" ], [ "dependencies" ], [ "configuration", "candidate-config" ],
    [ "services", "procd-snapshot" ], [ "services", "registration-origin" ], [ "autostart" ], [ "hooks", "hook-inventory" ],
    [ "processes", "visibility" ], [ "processes", "origin" ],
    [ "listeners", "socket-owners" ], [ "listeners", "namespace-and-configuration" ],
    [ "dns-committed", "dnsmasq" ], [ "dns-pending", "uci-deltas" ],
    [ "dns-runtime", "dnsmasq" ], [ "dns-runtime", "dnsmasq-config" ],
    [ "nft-loaded", "table-list" ], [ "nft-loaded", "rules-and-namespace" ], [ "nft-persisted", "firewall-includes" ],
    [ "policy-rules", "ownership" ], [ "policy-routes", "ownership" ],
    [ "ipv4-routes-rules", "policy-rules" ], [ "ipv4-routes-rules", "policy-routes" ],
    [ "ipv6-routes-rules", "policy-rules" ], [ "ipv6-routes-rules", "policy-routes" ],
    [ "resources", "candidate-capacity" ], [ "resources", "resource-budget" ], [ "core-check", "candidate-core" ]
];

function admission(observations) {
    for (let required in REQUIRED_PROOFS)
        if (length(filter(observations, (item) => type(item) == "object" && item.kind == required[0] &&
            (length(required) == 1 || item.object == required[1]))) == 0) {
            push(observations, observation(required[0], required[1] ?? required[0], "incomplete", "required-domain-proof-missing"));
            break;
        }
    let conflict = false, complete = true;
    for (let item in observations) {
        if (type(item) == "object" && item.state === "conflict") conflict = true;
        if (type(item) != "object" || item.state !== "checked") complete = false;
    }
    if (length(observations) > 256) {
        // Verification covers every observation; only diagnostics are capped, with failures first.
        let ordered = [ ...filter(observations, (item) => type(item) == "object" && item.state === "conflict"),
            ...filter(observations, (item) => type(item) != "object" || item.state !== "checked" && item.state !== "conflict"),
            ...filter(observations, (item) => type(item) == "object" && item.state === "checked") ];
        observations = slice(ordered, 0, 255);
        push(observations, observation("report", "ownership-observations", complete ? "checked" : "incomplete",
            complete ? "checked-observations-omitted" : "observation-count-limit"));
    }
    return { schema: 1, result: conflict ? "conflict" : complete ? "checked" : "incomplete", complete,
        install_allowed: complete, observations };
}

function collect(root, manifest_path, config_path, scratch, source_root, expected_digest, phase) {
    // The CLI always passes "/". A fixture root is only an in-process test seam.
    root = root == "/" ? "" : root;
    let observations = [];
    let owned = owned_components(root);
    let hooks = services_reader.hook_inventory(root || "/");
    let claims = {}, versions = {}, ownership_complete = false;
    let scope = scope_reader.snapshot();
    let candidate_format = null;
    let database_format = null;
    let installed_packages = null;
    let format_status = null;
    let candidate_core = null, candidate_components = null;
    let release = read_metadata(root + "/etc/openwrt_release", 16384, root || "/");
    let platform = release.error == null ? release_status(release.data) :
        { state: "incomplete", reason: "openwrt-release-" + release.error };
    push(observations, observation("platform", "openwrt-release", platform.state, platform.reason));
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
        let bound = false;
        let manifest_root = root || "/";
        if (expected_digest != null) {
            try {
                require("core.cache_path").validate({ cache_path: manifest_path });
                manifest_root = require("core.common").parent_dir(manifest_path);
                bound = require("singbox.runtime").file_digest(manifest_path) == expected_digest &&
                    require("service.update").candidate(manifest_root, expected_digest) != null;
            }
            catch (e) { bound = false; }
        }
        let read = read_metadata(manifest_path, 2097152, manifest_root);
        let manifest = read.error == null ? manifest_reader.parse(read.data) : { error: "manifest-" + read.error };
        if (expected_digest != null && !bound)
            manifest = { error: "candidate-content-or-checksum-unverified" };
        if (manifest.error != null)
            push(observations, observation("candidate-manifest", "candidate-manifest", "incomplete", manifest.error));
        else {
            candidate_format = manifest.format;
            if (bound) candidate_components = json(read.data).components;
            if (bound && platform.state == "checked" && manifest.architectures.core == platform.architecture) {
                let components = json(read.data).components;
                let component = filter(components, (entry) => entry.role == "core")[0];
                let binary = filter(component.files, (entry) => entry.path == "/usr/bin/loki-core")[0];
                let path = manifest_root + "/candidate-core";
                let raw = !require("service.lock").unmarked(path);
                candidate_core = { ...binary, path: raw ? path : root + "/usr/bin/loki-core", mode: raw ? 0700 : 0755 };
            }
            // Keep the compatibility reason ahead of file observations that may be truncated.
            format_status = observation("candidate-manifest", "package-format", "incomplete", bound ? "candidate-format-content-bound" : "package-format-unverified");
            push(observations, format_status);
            if (platform.architecture == null)
                push(observations, observation("candidate-manifest", "architecture", "incomplete", "openwrt-architecture-unverified"));
            else {
                let generic = manifest.format == "ipk" ? "all" : "noarch";
                let mismatch = false;
                for (let role in keys(manifest.architectures)) {
                    let arch = manifest.architectures[role];
                    if (arch != platform.architecture && (role == "core" || arch != generic)) mismatch = true;
                }
                push(observations, observation("candidate-manifest", "architecture", mismatch ? "conflict" : bound ? "checked" : "incomplete",
                    mismatch ? "candidate-architecture-mismatch" : bound ? "candidate-architecture-checked" : "artifact-architecture-unverified"));
            }
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
            push(observations, observation("candidate-manifest", "candidate-manifest", bound ? "checked" : "incomplete", bound ? "candidate-explicit-checksum-bound" : "artifact-provenance-unverified"));
            push(observations, observation("candidate-manifest", "candidate-manifest", bound ? "checked" : "incomplete", bound ? "candidate-archives-content-bound" : "artifact-content-unverified"));
            push(observations, manifest.component_policy);
        }
    }
    let hook_ordinal = 0;
    for (let path in hooks.paths)
        if (!exists(labels, path)) labels[path] = "hook-file-" + ++hook_ordinal;
    let process_ordinal = 0;
    for (let path in processes_reader.targets)
        if (!exists(labels, path)) labels[path] = "process-executable-" + ++process_ordinal;
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
            for (let package in parsed.packages) {
                versions[package.name] = package.version;
                for (let entry in package.entries) {
                    if (!exists(labels, entry.path))
                        continue;
                    if (claims[entry.path] == null) claims[entry.path] = [];
                    push(claims[entry.path], package.name);
                }
            }
            // The same bounded database is reread; no apk lock or scripts are involved.
            let final_read = read_metadata(path, length(read.data), root || "/");
            if (final_read.error != null || read.data != final_read.data)
                push(observations, observation("ownership", "apk-installed", "incomplete", "apk-changed-or-unavailable-on-recheck"));
            else {
                database_format = "apk";
                installed_packages = parsed.packages;
                ownership_complete = true;
                push(observations, observation("ownership", "installed-apk-candidate-files", "checked", "metadata-read-complete"));
            }
        }
    }
    else if (status == null) {
        push(observations, observation("ownership", "package-database", "incomplete", "package-database-unavailable"));
    }
    else {
        let status_read = read_metadata(opkg + "/status", STATUS_LIMIT, root || "/");
        let data = status_read.data;
        let records = package_records_from_status(data);
        let packages = records == null ? null : map(records, (package) => package.name);
        let complete = packages != null;
        // Reserve the status recheck within the aggregate read budget.
        let total = 2 * (status_read.bytes || 0) + 1;
        for (let package in records || []) versions[package.name] = package.version;
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
                if (claims[path] == null) claims[path] = [];
                push(claims[path], name);
            }
        }
        if (status_read.error == null) {
            let final_status = read_metadata(opkg + "/status", length(data), root || "/");
            if (data != final_status.data || final_status.error != null) {
                complete = false;
                failures["status-changed-or-unavailable-on-recheck"] = "opkg-status";
            }
            else if (packages != null) {
                database_format = "ipk";
                installed_packages = records;
            }
        }
        for (let reason in sort(keys(failures)))
            push(observations, observation("ownership", failures[reason], "incomplete", reason));
        if (complete) {
            ownership_complete = true;
            push(observations, observation("ownership", "installed-opkg-candidate-files", "checked", "metadata-read-complete"));
        }
    }
    if (format_status != null && database_format != null) {
        let mismatch = candidate_format != database_format;
        let verified = format_status.reason == "candidate-format-content-bound";
        format_status.state = mismatch ? "conflict" : verified ? "checked" : "incomplete";
        format_status.reason = mismatch ? "candidate-package-format-mismatch" : verified ? "candidate-package-format-checked" : "artifact-format-unverified";
    }
    for (let target in targets) {
        let names = claims[target] || [];
        if (length(names) > 1)
            push(observations, observation("ownership", labels[target], "conflict", "multiple-packages-claim-candidate-path"));
        else if (length(names) == 1) {
            let foreign = index(OWN_NAMES, names[0]) < 0;
            let verified = !foreign && own_path(owned, target, names, database_format, versions, ownership_complete);
            push(observations, observation("ownership", labels[target], foreign ? "conflict" : verified ? "checked" : "incomplete",
                foreign ? "foreign-package-owns-candidate-path" : verified ? "installed-component-content-checked" : "package-name-does-not-prove-own-origin"));
        }
    }
    for (let item in files_reader.collect(root || "/", file_targets)) {
        if (item.reason == "candidate-existing-file-origin-unverified" &&
            own_path(owned, item.path, claims[item.path] || [], database_format, versions, ownership_complete)) {
            let node = fs.lstat(root + item.path);
            if (node != null && (node.mode & 07777) == owned.files[item.path].mode) {
                item.state = "checked";
                item.reason = owned.retained ? "retained-own-configuration-checked" : "installed-component-content-checked";
            }
        }
        push(observations, observation("files", labels[item.path], item.state, item.reason));
    }
    let own_files = {};
    for (let path in keys(owned.files))
        if (own_path(owned, path, claims[path] ?? [], database_format, versions, ownership_complete))
            own_files[path] = owned.files[path];
    let origin = scope_reader.origin(root || "/", platform, installed_packages);
    let hook_own = {};
    for (let path in hooks.paths)
        if (own_path(owned, path, claims[path] || [], database_format, versions, ownership_complete)) hook_own[path] = true;
    for (let item in services_reader.collect(root || "/", { claims, own: hook_own, system: origin.state == "checked",
        complete: ownership_complete && hooks.error == null, token: hooks.token }))
        push(observations, item);
    for (let item in listeners_reader.collect(root || "/", scope))
        push(observations, item);
    for (let item in processes_reader.collect(root || "/", scope,
        { claims, own_files, system: origin.state == "checked", complete: ownership_complete }))
        push(observations, item);
    for (let item in rules_reader.collect())
        push(observations, item);
    for (let item in rules_reader.collect_routes())
        push(observations, item);
    for (let item in nft_reader.collect(scope, root || "/", own_files))
        push(observations, item);
    let resources = resources_reader.collect(root || "/", candidate_components);
    for (let item in resources) if (item.object != "resource-budget") push(observations, item);
    if (candidate_components != null && length(filter(resources, (item) => item.object == "candidate-capacity" && item.state == "checked")) != 1)
        candidate_core = null;
    if (config_path != null) {
        if (type(source_root) != "string" || config_path != source_root + "/loki/files/etc/config/loki")
            push(observations, observation("configuration", "candidate-config", "incomplete", "unsupported-candidate-config-path"));
        else {
            let read = read_metadata(config_path, 1048576, source_root);
            if (read.error != null)
                push(observations, observation("configuration", "candidate-config", "incomplete", "candidate-config-" + read.error));
            else {
                let platform = {};
                for (let name in [ "dhcp", "system", "firewall" ]) {
                    let snapshot = read_metadata(root + "/etc/config/" + name, 1048576, root || "/");
                    if (snapshot.error == null)
                        platform[name] = snapshot.data;
                    else
                        push(observations, observation("configuration", "platform-" + name, "incomplete", "platform-config-" + snapshot.error));
                }
                for (let item in config_reader.check(read.data, scratch, platform, candidate_core, root || "/",
                    { components: candidate_components, previous: owned.components, scope, phase, own_files }))
                    push(observations, item);
                let final_config = read_metadata(config_path, 1048576, source_root);
                if (final_config.error != null || final_config.data != read.data)
                    push(observations, observation("configuration", "candidate-config", "incomplete", "candidate-config-changed-on-recheck"));
                for (let name in keys(platform)) {
                    let recheck = read_metadata(root + "/etc/config/" + name, 1048576, root || "/");
                    let stable = recheck.error == null && recheck.data == platform[name];
                    push(observations, observation("configuration", "platform-" + name, stable ? "checked" : "incomplete",
                        stable ? "platform-config-snapshot-checked" : "platform-config-changed-on-recheck"));
                }
            }
        }
    }
    let rechecked_owned = owned_components(root);
    if (owned.error || rechecked_owned.error)
        push(observations, observation("ownership", "active-components", "incomplete", "installed-component-origin-unverified"));
    else if (owned.token != rechecked_owned.token)
        push(observations, observation("ownership", "active-components", "incomplete", "installed-components-changed-during-read"));
    else if (owned.token != null)
        push(observations, observation("ownership", "active-components", "checked", "installed-component-snapshot-checked"));
    let dependencies = dependencies_reader.check(installed_packages, database_format);
    for (let item in dependencies) push(observations, item);
    let release_recheck = read_metadata(root + "/etc/openwrt_release", 16384, root || "/");
    if (release.error != null || release_recheck.error != null || release.data != release_recheck.data) {
        origin.state = "incomplete"; origin.reason = "openwrt-release-changed-or-unavailable";
    }
    let ipv6 = null;
    try { ipv6 = require("nft.state").ipv6_interfaces(); }
    catch (e) {}
    push(observations, observation("platform", "ipv6-kernel", ipv6 == null ? "incomplete" : "checked",
        ipv6 == null ? "kernel-ipv6-context-unavailable" : "kernel-ipv6-context-checked"));
    let requirements = origin.state == "checked" && ipv6 != null && length(dependencies) > 0 &&
        length(filter(dependencies, (item) => item.state != "checked")) == 0;
    push(observations, observation("platform", "requirements", requirements ? "checked" : "incomplete",
        requirements ? "openwrt-system-requirements-checked" : "platform-requirements-unverified"));
    push(observations, config_reader.pending(root || "/"));
    if (length(filter(observations, (item) => item.kind == "resources" && item.object == "resource-budget")) == 0)
        push(observations, observation("resources", "resource-budget", "incomplete", "resource-transaction-budget-namespace-unverified"));
    // Unimplemented domains are mandatory; a partial inventory never grants permission.
    for (let kind in [ "nft-persisted", "hooks", "core-check", "dns-committed", "ipv4-routes-rules", "ipv6-routes-rules" ])
        if (length(filter(observations, (item) => item.kind == kind)) == 0)
            push(observations, observation(kind, kind, "incomplete", "not-implemented"));
    if (config_path == null)
        push(observations, observation("configuration", "configuration", "incomplete", "not-implemented"));
    push(observations, scope_reader.check(scope));
    push(observations, origin);
    return admission(observations);
}

return { collect, admission, packages_from_status, package_records_from_status, target_paths, read_metadata, release_status };
