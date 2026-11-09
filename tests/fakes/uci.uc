// In-memory ucode uci module: each cursor works on its own copy and publishes it on commit, so
// another cursor sees only what was committed.

let store = {};
let commits = [];

function copy(value) {
    return value == null ? null : json(sprintf("%J", value));
}

function empty_package() {
    return { sections: {}, order: [], anonymous_counter: 0 };
}

function section_view(name, section, position) {
    let view = copy(section.options);
    view[".name"] = name;
    view[".type"] = section.type;
    view[".anonymous"] = section.anonymous;
    view[".index"] = position;
    return view;
}

function cursor() {
    let loaded = {};
    let last_error = null;

    function package_data(config) {
        if (loaded[config] == null)
            loaded[config] = copy(store[config]) ?? empty_package();
        return loaded[config];
    }

    function known(config) {
        return store[config] != null || loaded[config] != null;
    }

    return {
        load: function(config) {
            if (store[config] == null) {
                last_error = "Entry not found";
                return false;
            }
            loaded[config] = copy(store[config]);
            return true;
        },

        unload: function(config) {
            delete loaded[config];
            return true;
        },

        get: function(config, section, option) {
            if (!known(config))
                return null;
            let data = package_data(config);
            let entry = data.sections[section];
            if (entry == null)
                return null;
            if (option == null)
                return entry.type;
            return copy(entry.options[option]);
        },

        get_all: function(config, section) {
            if (!known(config))
                return null;
            let data = package_data(config);
            if (section == null) {
                let result = {};
                for (let i, name in data.order)
                    result[name] = section_view(name, data.sections[name], i);
                return result;
            }
            let entry = data.sections[section];
            if (entry == null)
                return null;
            return section_view(section, entry, index(data.order, section));
        },

        get_first: function(config, type_name, option) {
            if (!known(config))
                return null;
            let data = package_data(config);
            for (let name in data.order) {
                let entry = data.sections[name];
                if (entry.type != type_name)
                    continue;
                return option == null ? name : copy(entry.options[option]);
            }
            return null;
        },

        foreach: function(config, type_name, callback) {
            if (!known(config))
                return false;
            let data = package_data(config);
            let found = false;
            for (let i, name in copy(data.order)) {
                let entry = data.sections[name];
                if (entry == null || (type_name != null && entry.type != type_name))
                    continue;
                found = true;
                if (callback(section_view(name, entry, i)) === false)
                    break;
            }
            return found;
        },

        add: function(config, type_name) {
            let data = package_data(config);
            let name = sprintf("cfg%06x", ++data.anonymous_counter);
            while (data.sections[name] != null)
                name = sprintf("cfg%06x", ++data.anonymous_counter);
            data.sections[name] = { type: type_name, anonymous: true, options: {} };
            push(data.order, name);
            return name;
        },

        set: function(config, section, option, value) {
            let data = package_data(config);
            if (value == null) {
                if (data.sections[section] == null) {
                    data.sections[section] = { type: option, anonymous: false, options: {} };
                    push(data.order, section);
                }
                else
                    data.sections[section].type = option;
                return true;
            }
            let entry = data.sections[section];
            if (entry == null) {
                last_error = "Entry not found";
                return false;
            }
            entry.options[option] = type(value) == "array" ? map(value, (v) => "" + v) : "" + value;
            return true;
        },

        delete: function(config, section, option) {
            let data = package_data(config);
            let entry = data.sections[section];
            if (entry == null)
                return false;
            if (option == null) {
                delete data.sections[section];
                data.order = filter(data.order, (name) => name != section);
                return true;
            }
            if (entry.options[option] == null)
                return false;
            delete entry.options[option];
            return true;
        },

        save: function(config) {
            return true;
        },

        commit: function(config) {
            if (loaded[config] == null)
                return true;
            store[config] = copy(loaded[config]);
            push(commits, config);
            return true;
        },

        revert: function(config) {
            delete loaded[config];
            return true;
        },

        changes: function(config) {
            return {};
        },

        error: function() {
            return last_error;
        }
    };
}

// Replaces a whole package. Sections are given in file order as objects with
// ".name" and ".type" plus their options; a missing ".name" makes the section
// anonymous, and ".anonymous" marks one named as UCI names it by its position.
function __seed(config, sections) {
    let data = empty_package();
    for (let section in sections ?? []) {
        let name = section[".name"];
        let anonymous = section[".anonymous"] ?? (name == null);
        if (name == null)
            name = sprintf("cfg%06x", ++data.anonymous_counter);
        let options = {};
        for (let key, value in section)
            if (substr(key, 0, 1) != ".")
                options[key] = type(value) == "array" ? map(value, (v) => "" + v) : "" + value;
        data.sections[name] = { type: section[".type"], anonymous, options };
        push(data.order, name);
    }
    store[config] = data;
}

function __reset() {
    store = {};
    commits = [];
}

// The committed package as the section list __seed takes.
function __sections(config) {
    let data = store[config];
    if (data == null)
        return null;
    let result = [];
    for (let i, name in data.order)
        push(result, section_view(name, data.sections[name], i));
    return result;
}

function __commits() {
    return copy(commits);
}

return { cursor, __seed, __reset, __sections, __commits };
