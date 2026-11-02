// Restore an own LoKi backup as unsaved changes of the caller's LuCI session.

let migration = require("config.migration");

const CONFIG_NAME = "forkop";

// The file as this release reads it, or the reason it cannot, which the page words itself.
function target(path) {
    let loaded = migration.read_file(path);
    if (loaded.error != null)
        return { reason: loaded.reason ?? "unreadable", detail: "UCI could not read the configuration" };
    let decision = migration.decide(loaded.model);
    if (decision.result == "reject")
        return { reason: decision.reason, from: decision.from };
    let migrated = migration.migrate(loaded.model, decision.from);
    if (migrated.error != null)
        return { reason: "migration", from: decision.from, detail: migrated.error };
    return { from: decision.from, model: migrated.model, warnings: migrated.warnings };
}

function refused(result) {
    return { success: false, min: migration.MIN_CONFIG_VERSION, to: migration.TARGET_CONFIG_VERSION, ...result };
}

// rpcd's uci object on behalf of the page's session, shaped as the cursor config.migration applies
// changes through: what it writes waits among the session's unsaved changes.
function session(connection, id) {
    let state = { error: null };
    let call = (method, args) => {
        let reply = connection.call("uci", method, { ...args, ubus_rpc_session: id });
        state.error = connection.error();
        return state.error ? null : (reply ?? {});
    };
    return {
        state,
        add: (config, type_name) => call("add", { config, type: type_name })?.section,
        // A type alone creates the named section or changes its type, as UCI's own set does.
        set: (config, section, option, value) => value == null
            ? call("add", { config, type: option, name: section }) != null
            : call("set", { config, section, values: { [option]: value } }) != null,
        delete: (config, section, option) =>
            call("delete", option == null ? { config, section } : { config, section, option }) != null,
        revert: () => call("revert", { config: CONFIG_NAME }) != null,
        order: (sections) => call("order", { config: CONFIG_NAME, sections }) != null,
        unsaved: () => length(call("changes", { config: CONFIG_NAME })?.changes ?? []) > 0,
        model: () => {
            let staged = call("get", { config: CONFIG_NAME })?.values;
            if (staged == null)
                return null;
            let sections = sort(values(staged), (left, right) => left[".index"] - right[".index"]);
            return { sections: map(sections, (section) => {
                let copy = { ...section };
                delete copy[".index"];
                return copy;
            }) };
        }
    };
}

function connect(id) {
    if (id == null || id == "")
        return null;
    let connection = require("ubus").connect();
    return connection == null ? null : session(connection, id);
}

function names(model) {
    return join(" ", map(model.sections, (section) => section[".name"]));
}

// UCI names an anonymous section by its position, and rpcd one it adds by its own count: such a
// section is known by its content alone.
function content(model) {
    return sprintf("%J", map(model.sections, (section) => {
        let result = {};
        for (let key in sort(keys(section)))
            if (key != ".name" || !section[".anonymous"])
                result[key] = section[key];
        return result;
    }));
}

// Without a session, against the committed configuration.
function check(path, id) {
    let wanted = target(path);
    if (wanted.model == null)
        return refused(wanted);

    let uci = connect(id);
    let current = uci != null ? uci.model() : migration.read_file(migration.paths.config).model;
    if (current == null)
        return refused({ reason: "session", detail: uci?.state?.error ?? "LoKi has no configuration to replace" });
    return {
        success: true,
        from: wanted.from,
        to: migration.TARGET_CONFIG_VERSION,
        warnings: wanted.warnings,
        changed: content(current) != content(wanted.model),
        unsaved: uci != null && uci.unsaved()
    };
}

// The session's own unsaved changes to Forkop give way to the file's. Sections the file adds land
// last, and the file's order is the one routing rules are checked in.
function stage(path, id) {
    let wanted = target(path);
    if (wanted.model == null)
        return refused(wanted);
    let uci = connect(id);
    if (uci == null)
        return refused({ reason: "session", detail: "No LuCI session to stage the configuration in" });
    if (!uci.revert())
        return refused({ reason: "session", detail: uci.state.error });

    let current = uci.model();
    let created = {};
    let failure = current == null
        ? "could not read the configuration"
        : migration.apply(uci, migration.changes(current, wanted.model), created);
    if (failure == null) {
        let order = map(wanted.model.sections, (section) => created[section[".name"]] ?? section[".name"]);
        let staged = uci.model();
        if (staged == null)
            failure = "could not read the staged configuration";
        else if (names(staged) != join(" ", order) && !uci.order(order))
            failure = "could not order the sections";
    }
    if (failure != null) {
        let reason = uci.state.error;
        uci.revert();
        return refused({ reason: "staging", detail: failure + (reason ? ": " + reason : "") });
    }
    return { success: true };
}

return { check, stage };
