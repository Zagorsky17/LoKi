let fs = require("fs");
let exec = require("core.exec");

let paths = {
    opkg_status: "/usr/lib/opkg/status",
    sing_box_version: "/usr/share/loki-core/version",
    sing_box_variant: "/usr/share/loki-core/variant"
};

function apk_present() {
    return exec.ok([ "sh", "-c", "command -v apk" ]);
}

function apk_installed(name) {
    return apk_present() && exec.ok([ "apk", "info", "-e", name ]);
}

// The last word decides: "not-installed" also ends in "installed".
function opkg_status_installed(status) {
    let words = split(trim(status), /[ \t]+/);
    return words[length(words) - 1] == "installed";
}

function opkg_status_version(text, name) {
    let stanza = {};
    for (let line in [ ...split(text ?? "", "\n"), "" ]) {
        line = trim(line);
        if (line == "") {
            if (stanza.Package == name && opkg_status_installed(stanza.Status ?? ""))
                return stanza.Version ?? "";
            stanza = {};
            continue;
        }
        let parts = match(line, /^(Package|Version|Status): (.*)$/);
        if (parts)
            stanza[parts[1]] = trim(parts[2]);
    }
    return "";
}

// The status file needs no lock; `opkg list-installed` takes opkg's and fails a concurrent
// install. The listing is only for a layout that keeps the status elsewhere.
function opkg_version(name) {
    let text = fs.readfile(paths.opkg_status);
    if (text != null)
        return opkg_status_version(text, name);

    let prefix = name + " - ";
    for (let line in split(exec.output([ "opkg", "list-installed" ]) ?? "", "\n"))
        if (substr(line, 0, length(prefix)) == prefix)
            return trim(substr(line, length(prefix)));
    return "";
}

function opkg_installed(name) {
    return opkg_version(name) != "";
}

function installed(name) {
    return apk_installed(name) || opkg_installed(name);
}

function apk_list_version(name, output) {
    let prefix = name + "-";
    for (let field in split(output ?? "", /[ \t\r\n]+/))
        if (length(field) > length(prefix) && substr(field, 0, length(prefix)) == prefix)
            return substr(field, length(prefix));
    return "";
}

function apk_manifest_version(name, output) {
    let found = false;
    for (let line in split(output ?? "", "\n")) {
        line = trim(line);
        if (substr(line, 0, 2) == "P:")
            found = substr(line, 2) == name;
        else if (found && substr(line, 0, 2) == "V:")
            return substr(line, 2);
    }
    return "";
}

function apk_version(name) {
    if (!apk_installed(name))
        return "";
    return apk_list_version(name, exec.output([ "apk", "list", "--installed", name ])) ||
        apk_manifest_version(name, exec.output([ "apk", "list", "--installed", "--manifest", name ])) ||
        apk_manifest_version(name, exec.output([ "apk", "list", "--installed", "--manifest" ])) ||
        apk_list_version(name, exec.output([ "apk", "info", "-v", name ]));
}

// Recognize the supported own-core format without accepting unrelated fork versions.
function loki_core_version(value) {
    value = trim(value ?? "");
    return match(value, /^[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+(\+[0-9]+)?$/) ? value : "";
}

function recorded_sing_box_version() {
    return loki_core_version(fs.readfile(paths.sing_box_version));
}

// As the release spells it, with "-" where the package version carries "~".
function sing_box_version() {
    return replace(recorded_sing_box_version(), /~/g, "-");
}

// The variant the core package was built as, or "" for a core no package recorded.
function sing_box_variant() {
    let value = trim(fs.readfile(paths.sing_box_variant) ?? "");
    return value in [ "base", "full", "tiny", "custom" ] ? value : "";
}

function version(name) {
    if (name == "loki-core" && installed(name) && fs.stat(paths.sing_box_version) != null)
        return recorded_sing_box_version();
    return apk_version(name) || opkg_version(name);
}

return { paths, installed, opkg_installed, opkg_version, opkg_status_version, apk_version, version, loki_core_version, sing_box_version, sing_box_variant };
