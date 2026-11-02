#!/usr/bin/env ucode

// Modified for LoKi on 2026-11-02: accept only LoKi schemas and remove foreign cleanup.
// Brings /etc/config/forkop to the schema of this release. settings.config_version names the
// release whose schema a configuration follows; RELEASES lists every schema from the oldest one
// migrated, each with the steps that lead to it from the one before. A release that changes the
// schema appends its entry and a step module. Raising MIN_CONFIG_VERSION deletes the entries
// below it with their modules; the new first entry keeps only its section types.

let fs = require("fs");
let uci = require("uci");
let common = require("core.common");
let exec = require("core.exec");
let model_lib = require("config.migrations.model");

let as_string = common.as_string;

const CONFIG_NAME = "forkop";
const CONFIG_FORMAT = "loki";
const MAX_CONFIG_SIZE = 1024 * 1024;
const MIN_CONFIG_VERSION = "2.0.0";
const RELEASES = [
    {
        version: MIN_CONFIG_VERSION,
        types: [ "settings", "section", "subscription_url", "section_interface", "connection_link", "urltest", "fallback_group", "fallback_level" ],
        steps: []
    }
];
const TARGET_CONFIG_VERSION = RELEASES[length(RELEASES) - 1].version;

let paths = {
    config: "/etc/config/" + CONFIG_NAME,
    // Read by the init script: a reload of the exact configuration committed here is skipped.
    internal_change: "/var/run/forkop.internal-config-change"
};

function version_parts(value) {
    let matched = match(as_string(value), /^([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})$/);
    return matched ? [ int(matched[1]), int(matched[2]), int(matched[3]) ] : null;
}

function compare_versions(left, right) {
    left = version_parts(left);
    right = version_parts(right);
    for (let i = 0; i < 3; i++)
        if (left[i] != right[i])
            return left[i] < right[i] ? -1 : 1;
    return 0;
}

function release_index(version) {
    for (let i = 0; i < length(RELEASES); i++)
        if (RELEASES[i].version == version)
            return i;
    return -1;
}

// A format marker separates LoKi's schema versions from identically numbered foreign releases.
function decide(model) {
    let sections = model?.sections;
    if (type(sections) != "array")
        return { result: "reject", from: "unknown", reason: "schema" };
    for (let section in sections)
        if (type(section) != "object")
            return { result: "reject", from: "unknown", reason: "schema" };
    let settings = filter(sections, (section) => section[".type"] == "settings");
    if (length(settings) != 1 || settings[0][".name"] != "settings")
        return { result: "reject", from: "unknown", reason: "schema" };
    settings = settings[0];
    if (settings.config_format !== CONFIG_FORMAT)
        return { result: "reject", from: "unknown", reason: "foreign" };
    let version = settings.config_version;
    if (version == null || version === "")
        return { result: "reject", from: "unknown", reason: "missing" };
    if (type(version) != "string" || version_parts(version) == null)
        return { result: "reject", from: "unknown", reason: "invalid" };
    if (compare_versions(version, TARGET_CONFIG_VERSION) > 0)
        return { result: "reject", from: version, reason: "newer" };
    if (compare_versions(version, MIN_CONFIG_VERSION) < 0)
        return { result: "reject", from: version, reason: "below_min" };
    let release = release_index(version);
    if (release < 0)
        return { result: "reject", from: version, reason: "unknown" };
    let names = {};
    for (let section in sections) {
        let name = section[".name"];
        if (type(name) != "string" || name == "" || names[name] || !(section[".type"] in RELEASES[release].types))
            return { result: "reject", from: version, reason: "schema" };
        names[name] = true;
    }
    return { result: version == TARGET_CONFIG_VERSION ? "current" : "migrate", from: version };
}

const REJECTION_REASONS = {
    foreign: "it is not a LoKi configuration",
    schema: "its section structure is not supported",
    missing: "it names no version",
    invalid: "its version is not a release number",
    newer: "it was written by a newer LoKi",
    below_min: "its schema is no longer supported by LoKi",
    unknown: "its schema version is unknown to LoKi"
};

function deep_copy(value) {
    return json(sprintf("%J", value));
}

// Runs every step after the source release on a copy; the original stays as it was for the
// difference. A step stops the migration with die().
function migrate(model, from) {
    let decision = decide(model);
    if (decision.result == "reject" || decision.from != from)
        return { error: REJECTION_REASONS[decision.reason] ?? "the source schema does not match" };
    let migrated = deep_copy(model);
    let ctx = { warnings: [] };
    try {
        for (let i = release_index(from) + 1; i < length(RELEASES); i++)
            for (let step in RELEASES[i].steps)
                step(migrated, ctx);
    }
    catch (e) {
        return { error: "a LoKi migration step failed" };
    }

    let settings = model_lib.settings(migrated);
    if (settings == null)
        return { error: "a LoKi migration produced an invalid configuration" };
    settings.config_version = TARGET_CONFIG_VERSION;
    if (decide(migrated).result != "current")
        return { error: "a LoKi migration produced an invalid configuration" };
    return { model: migrated, warnings: ctx.warnings };
}

function option_keys(section) {
    return filter(keys(section), (key) => substr(key, 0, 1) != ".");
}

function same_value(left, right) {
    return sprintf("%J", left) == sprintf("%J", right);
}

// The UCI writes that turn one model into the other, in file order: sections added first, so
// that options naming them can be resolved, then edits, then removals.
function changes(before, after) {
    let ops = [];
    let old = {};
    for (let section in before.sections)
        old[section[".name"]] = section;

    for (let section in after.sections)
        if (old[section[".name"]] == null)
            push(ops, section[".anonymous"]
                ? { op: "add", section: section[".name"], type: section[".type"] }
                : { op: "create", section: section[".name"], type: section[".type"] });

    let kept = {};
    for (let section in after.sections) {
        let name = section[".name"];
        let previous = old[name] ?? {};
        kept[name] = true;
        if (previous[".type"] != null && previous[".type"] != section[".type"])
            push(ops, { op: "retype", section: name, type: section[".type"] });
        for (let key in option_keys(section))
            if (!same_value(previous[key], section[key]))
                push(ops, { op: "set", section: name, option: key, value: section[key] });
        for (let key in option_keys(previous))
            if (section[key] == null)
                push(ops, { op: "unset", section: name, option: key });
    }

    for (let section in before.sections)
        if (!kept[section[".name"]])
            push(ops, { op: "remove", section: section[".name"] });
    return ops;
}

function model_from_cursor(cursor, package_name) {
    let sections = [];
    cursor.foreach(package_name ?? CONFIG_NAME, null, (section) => {
        let copy = {};
        for (let key, value in section)
            if (key != ".index")
                copy[key] = value;
        push(sections, copy);
    });
    return { sections };
}

// A configuration file anywhere, as UCI reads it with no change staged on top.
function file_error(path) {
    let stat = fs.lstat(path);
    if (stat == null)
        return "unreadable";
    return stat.type == "file" && stat.size <= MAX_CONFIG_SIZE ? null : "file";
}

function read_file(path) {
    path = as_string(path);
    let reason = file_error(path);
    if (reason != null)
        return { error: "Configuration file check failed", reason };
    let slash = rindex(path, "/");
    let dir = slash > 0 ? substr(path, 0, slash) : ".";
    let package_name = substr(path, slash + 1);
    let cursor = uci.cursor(dir, "/var/run/forkop-migration-check.nonexistent");
    if (!cursor.load(package_name))
        return { error: "UCI cannot read " + path + ": " + (cursor.error() ?? "unknown error") };
    return { model: model_from_cursor(cursor, package_name) };
}

// created collects the name UCI gave each section added in place of its placeholder.
function apply(cursor, ops, created) {
    created ??= {};
    let resolve = (value) => type(value) == "array"
        ? map(value, (item) => created[item] ?? item)
        : created[value] ?? value;

    for (let op in ops) {
        let section = created[op.section] ?? op.section;
        let done;
        if (op.op == "add") {
            done = cursor.add(CONFIG_NAME, op.type);
            created[op.section] = done;
        }
        else if (op.op == "create" || op.op == "retype")
            done = cursor.set(CONFIG_NAME, section, op.type);
        else if (op.op == "set")
            done = cursor.set(CONFIG_NAME, section, op.option, resolve(op.value));
        else if (op.op == "unset")
            done = cursor.delete(CONFIG_NAME, section, op.option);
        else if (op.op == "remove")
            done = cursor.delete(CONFIG_NAME, section);
        if (!done)
            return "could not " + op.op + " " + (op.option != null ? "option '" + op.option + "' of " : "") +
                "section '" + section + "'";
    }
    return null;
}

function stamp() {
    let now = localtime();
    return sprintf("%04d%02d%02d-%02d%02d%02d", now.year, now.mon, now.mday, now.hour, now.min, now.sec);
}

// Beside the configuration, under a name UCI does not read as a package: a dot ends it.
function aside_path(version) {
    let base = paths.config + "." + replace(as_string(version), /[^A-Za-z0-9._-]/g, "_") + "-" + stamp();
    let path = base;
    for (let n = 2; fs.stat(path) != null; n++)
        path = base + "-" + n;
    return path;
}

function copy_file(from, to, mode) {
    let text = fs.readfile(from);
    if (text == null)
        return false;
    let temporary = to + ".new";
    if (fs.writefile(temporary, text) == null || !fs.chmod(temporary, mode) || !fs.rename(temporary, to)) {
        fs.unlink(temporary);
        return false;
    }
    return true;
}

function mark_internal_change() {
    let hash = split(trim(exec.output([ "md5sum", paths.config ]) ?? ""), " ")[0];
    if (hash == "")
        return;
    common.write_file_atomic(paths.internal_change, common.now_seconds() + "\n" + hash + "\n");
}

// One line each to the log and to the terminal of whoever installed the package.
function report(level, message) {
    exec.log(level, message);
    warn("[" + level + "] " + message + "\n");
}

function migrate_runtime(model, decision) {
    let result = migrate(model, decision.from);
    if (result.error != null) {
        report("error", "Failed to migrate the configuration from " + decision.from + " to " + TARGET_CONFIG_VERSION +
            ": " + result.error + "; it was left as it was");
        return false;
    }

    // Steps that changed nothing here move only the label, which leaves no copy worth keeping.
    let ops = changes(model, result.model);
    let label_only = length(filter(ops, (op) => op.op != "set" || op.option != "config_version")) == 0;
    let aside = label_only ? null : aside_path(decision.from);
    if (aside != null && !copy_file(paths.config, aside, 0600)) {
        report("error", "Failed to save the configuration to " + aside + " before migrating it; it was left as it was");
        return false;
    }
    let cursor = uci.cursor();
    let failure = cursor.load(CONFIG_NAME) ? apply(cursor, ops) : "could not load it";
    if (failure == null && !cursor.commit(CONFIG_NAME))
        failure = "could not commit it";
    if (failure != null) {
        report("error", "Failed to migrate the configuration from " + decision.from + " to " + TARGET_CONFIG_VERSION +
            ": " + failure + "; it was left as it was");
        return false;
    }
    mark_internal_change();

    report("info", "Migrated the configuration from " + decision.from + " to " + TARGET_CONFIG_VERSION +
        (aside != null ? "; the previous one is saved as " + aside : "; nothing but its version changed"));
    for (let line in result.warnings)
        report("warn", line);
    return true;
}

// The configuration on the router. A file UCI cannot parse is left for its owner to fix.
function load_runtime() {
    if (file_error(paths.config) != null)
        return { error: "The configuration must be a regular file of at most 1 MiB" };
    let cursor = uci.cursor();
    if (!cursor.load(CONFIG_NAME))
        return { error: "UCI cannot read " + paths.config + ": " + (cursor.error() ?? "unknown error") };
    return { model: model_from_cursor(cursor) };
}

// Unsupported files are never moved, reset or used to clean another application's state.
function run() {
    let loaded = load_runtime();
    if (loaded.error != null) {
        report("error", "Failed to read the LoKi configuration; it was left unchanged");
        return false;
    }
    let decision = decide(loaded.model);
    if (decision.result == "current")
        return true;
    if (decision.result == "reject") {
        report("error", "LoKi cannot use this configuration because " + REJECTION_REASONS[decision.reason] + "; it was left unchanged");
        return false;
    }
    return migrate_runtime(loaded.model, decision);
}

function start() {
    return run();
}

// The installer's question before it changes anything: what this release would do to the
// configuration at path. Reads only the file, and writes nothing anywhere.
function check(path) {
    if (fs.stat(as_string(path)) == null)
        return { result: "fail", from: "unknown", reason: "missing" };

    let loaded = read_file(path);
    if (loaded.error != null)
        return { result: "fail", from: "unknown", reason: loaded.reason ?? "unreadable" };
    let model = loaded.model;
    let decision = decide(model);
    if (decision.result == "current")
        return { result: "current", to: TARGET_CONFIG_VERSION };
    if (decision.result == "reject")
        return { result: "fail", from: decision.from, reason: decision.reason };
    let migrated = migrate(model, decision.from);
    if (migrated.error != null)
        return { result: "fail", from: decision.from, reason: migrated.error };
    return { result: "migrate", from: decision.from, to: TARGET_CONFIG_VERSION, warnings: migrated.warnings };
}

function main(argv) {
    let mode = argv[0] ?? "";
    if (mode == "migrate")
        return run() ? 0 : 1;
    if (mode == "check" && argv[1] != null) {
        let verdict = check(argv[1]);
        common.write_json(verdict);
        return verdict.result == "fail" ? 1 : 0;
    }

    warn("Usage: config/migration.uc migrate\n");
    warn("       config/migration.uc check <path of a copy of /etc/config/forkop>\n");
    return 2;
}

if (sourcepath(1) != null && sourcepath(1) != "")
    return { paths, MIN_CONFIG_VERSION, TARGET_CONFIG_VERSION, decide, migrate, changes, apply, read_file, run, start, check, main };

exit(main(ARGV));
