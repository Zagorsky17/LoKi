#!/usr/bin/env ucode

let common = require("core.common");

let as_string = common.as_string;

let runtime_cursor = false;
let loaded_packages = {};

function words(value) {
    value = trim(as_string(value));
    return value == "" ? [] : split(value, /[ \t\r\n]+/);
}

function path_parts(path) {
    path = as_string(path);
    let first = index(path, ".");
    if (first < 0)
        return null;

    let package_name = substr(path, 0, first);
    let rest = substr(path, first + 1);
    let second = index(rest, ".");
    if (second < 0)
        return { package: package_name, section: rest, option: "" };

    return {
        package: package_name,
        section: substr(rest, 0, second),
        option: substr(rest, second + 1)
    };
}

function anonymous_section_selector(section) {
    let matched = match(as_string(section), /^@([A-Za-z0-9_-]+)\[([0-9]+)\]$/);
    if (!matched)
        return null;

    return {
        type: as_string(matched[1]),
        index: int(matched[2])
    };
}

function resolve_section_name(c, package_name, raw_section_name) {
    raw_section_name = as_string(raw_section_name);

    let selector = anonymous_section_selector(raw_section_name);
    if (selector == null)
        return raw_section_name;

    let found = "";
    let current = 0;
    try {
        c.foreach(as_string(package_name), selector.type, function(section) {
            if (found != "")
                return;
            if (current == selector.index && type(section) == "object")
                found = as_string(section[".name"] || "");
            current++;
        });
    }
    catch (e) {
        return "";
    }

    return found;
}

function resolve_parts(c, parts) {
    if (parts == null)
        return null;

    let section = resolve_section_name(c, parts.package, parts.section);
    if (section == "")
        return null;

    return {
        package: parts.package,
        section,
        option: parts.option
    };
}

function cursor() {
    if (runtime_cursor !== false)
        return runtime_cursor;

    try {
        runtime_cursor = require("uci").cursor();
    }
    catch (e) {
        runtime_cursor = null;
    }
    return runtime_cursor;
}

function available() {
    return cursor() != null;
}

function reset() {
    runtime_cursor = false;
    loaded_packages = {};
}

function load(package_name) {
    package_name = as_string(package_name);
    if (loaded_packages[package_name])
        return true;

    let c = cursor();
    if (c == null)
        return false;

    try {
        // Native UCI returns null for API failures.
        if (c.load(package_name) !== true)
            return false;
        loaded_packages[package_name] = true;
        return true;
    }
    catch (e) {
        return false;
    }
}

function value_to_string(value) {
    if (value == null)
        return "";
    if (type(value) == "array")
        return join(" ", value);
    return as_string(value);
}

function value_to_list(value) {
    if (value == null)
        return [];
    if (type(value) == "array")
        return value;
    return words(value);
}

function get(path) {
    path = as_string(path);
    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option == "")
        return "";
    if (!load(parts.package))
        return "";
    parts = resolve_parts(c, parts);
    if (parts == null)
        return "";

    return value_to_string(c.get(parts.package, parts.section, parts.option));
}

function get_all(package_name, section_name) {
    let c = cursor();
    if (c == null)
        return null;

    try {
        if (!load(package_name))
            return null;
        section_name = resolve_section_name(c, package_name, section_name);
        if (section_name == "")
            return null;
        return c.get_all(as_string(package_name), as_string(section_name));
    }
    catch (e) {
        return null;
    }
}

function exists(path) {
    path = as_string(path);
    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null)
        return false;
    if (!load(parts.package))
        return false;
    parts = resolve_parts(c, parts);
    if (parts == null)
        return false;

    if (parts.option == "")
        return c.get_all(parts.package, parts.section) != null;
    return c.get(parts.package, parts.section, parts.option) != null;
}

function delete_path(path) {
    path = as_string(path);
    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null)
        return false;
    if (!load(parts.package))
        return false;
    parts = resolve_parts(c, parts);
    if (parts == null)
        return false;

    try {
        if (parts.option == "")
            return c.delete(parts.package, parts.section) === true;
        return c.delete(parts.package, parts.section, parts.option) === true;
    }
    catch (e) {
        return false;
    }
}

function set_section(path, type_name) {
    path = as_string(path);
    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option != "")
        return false;
    if (!load(parts.package))
        return false;
    parts = resolve_parts(c, parts);
    if (parts == null)
        return false;

    try {
        return c.set(parts.package, parts.section, as_string(type_name)) === true;
    }
    catch (e) {
        return false;
    }
}

function add(package_name, type_name) {
    let c = cursor();
    if (c == null)
        return "";

    try {
        if (!load(package_name))
            return "";
        let section = c.add(as_string(package_name), as_string(type_name));
        return as_string(section);
    }
    catch (e) {
        return "";
    }
}

function set(path, value) {
    path = as_string(path);
    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option == "")
        return false;
    if (!load(parts.package))
        return false;
    parts = resolve_parts(c, parts);
    if (parts == null)
        return false;

    try {
        return c.set(parts.package, parts.section, parts.option, type(value) == "array" ? value : as_string(value)) === true;
    }
    catch (e) {
        return false;
    }
}

function add_list(path, value) {
    path = as_string(path);
    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option == "")
        return false;
    if (!load(parts.package))
        return false;
    parts = resolve_parts(c, parts);
    if (parts == null)
        return false;

    try {
        let values = value_to_list(c.get(parts.package, parts.section, parts.option));
        push(values, as_string(value));
        return c.set(parts.package, parts.section, parts.option, values) === true;
    }
    catch (e) {
        return false;
    }
}

function del_list(path, value) {
    path = as_string(path);
    let parts = path_parts(path);
    let c = cursor();
    if (c == null || parts == null || parts.option == "")
        return false;
    if (!load(parts.package))
        return false;
    parts = resolve_parts(c, parts);
    if (parts == null)
        return false;

    let values = [];
    let removed = false;
    for (let item in value_to_list(c.get(parts.package, parts.section, parts.option))) {
        if (item == value) {
            removed = true;
            continue;
        }
        push(values, item);
    }

    if (!removed)
        return false;

    try {
        if (length(values) == 0)
            return c.delete(parts.package, parts.section, parts.option) === true;
        return c.set(parts.package, parts.section, parts.option, values) === true;
    }
    catch (e) {
        return false;
    }
}

function commit(package_name) {
    let c = cursor();
    if (c == null || !load(package_name))
        return false;

    try {
        return c.commit(package_name) === true;
    }
    catch (e) {
        return false;
    }
}

function section_name(section) {
    if (type(section) == "object")
        return as_string(section[".name"] || "");
    return as_string(section);
}

function sections(package_name, type_name) {
    let c = cursor();
    if (c == null)
        return [];

    let result = [];
    try {
        if (!load(package_name))
            return [];
        c.foreach(package_name, as_string(type_name), function(section) {
            let name = section_name(section);
            if (name != "")
                push(result, name);
        });
    }
    catch (e) {
        return [];
    }
    return result;
}

function section_objects(package_name, type_name) {
    let c = cursor();
    if (c == null)
        return [];

    let result = [];
    try {
        if (!load(package_name))
            return [];
        c.foreach(package_name, type_name == null ? null : as_string(type_name), function(section) {
            if (type(section) == "object")
                push(result, section);
        });
    }
    catch (e) {
        return [];
    }
    return result;
}

return {
    available,
    reset,
    load,
    get,
    get_all,
    exists,
    delete: delete_path,
    set_section,
    add,
    set,
    add_list,
    del_list,
    commit,
    sections,
    section_objects
};
