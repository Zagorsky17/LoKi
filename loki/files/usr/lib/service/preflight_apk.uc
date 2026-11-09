// Read the installed text database, never apk commands or package scripts.
// Grammar: apk-tools 3.0.5, database.c:apk_db_fdb_read and package.c:apk_pkgtmpl_add_info.
const BYTE_LIMIT = 4194304;
const ENTRY_LIMIT = 16384;
const PACKAGE_LIMIT = 4096;
// Keep recurring POSIX expressions simple and enforce the same byte limits separately on musl.
const PATH_CONTROL_PATTERN = /[\x01-\x1f\x7f]/;
const CONTROL_PATTERN = /[\x01-\x08\x0b-\x1f\x7f]/;
const ACL_PATTERN = /^[0-9]{1,10}:[0-9]{1,10}:[0-7]{1,4}(:[A-Za-z0-9+\/=]{1,128})?$/;
const DIGEST_PATTERN = /^[A-Za-z0-9+\/=]+$/;
const NUMBER_PATTERN = /^[0-9]+$/;
const NAME_PATTERN = /^[a-z0-9][a-z0-9+_.-]*$/;
const VERSION_PATTERN = /^[A-Za-z0-9+_.~-]+$/;
const ARCH_PATTERN = /^[A-Za-z0-9_-]+$/;


function relative_path(value, directory) {
    if (type(value) != "string" || length(value) > 4095 || index(value, "\u0000") >= 0 || match(value, PATH_CONTROL_PATTERN))
        return false;
    if (value == "")
        return directory;
    if (substr(value, 0, 1) == "/" || substr(value, -1) == "/" || index(value, "//") >= 0)
        return false;
    for (let part in split(value, "/"))
        if (part == "." || part == "..")
            return false;
    return true;
}

function parse(data) {
    if (type(data) != "string" || data == "" || substr(data, -2) != "\n\n")
        return { error: "apk-record-termination-invalid" };
    if (length(data) > BYTE_LIMIT)
        return { error: "apk-byte-limit" };
    // POSIX regex patterns cannot contain NUL; check that byte separately.
    if (index(data, "\u0000") >= 0 || match(data, CONTROL_PATTERN))
        return { error: "apk-control-byte" };
    let packages = [];
    let names = {};
    let count = 0;
    for (let record in split(substr(data, 0, length(data) - 2), "\n\n")) {
        let fields = {};
        let paths = {};
        let entries = [];
        let directory = null;
        let file = null;
        let acl = false;
        let digest = false;
        let directory_acl = false;
        for (let line in split(record, "\n")) {
            if (length(line) > 8192)
                return { error: "apk-line-limit" };
            if (length(line) < 2 || substr(line, 1, 1) != ":")
                return { error: "apk-field-invalid" };
            let key = substr(line, 0, 1);
            let value = substr(line, 2);
            if (key == "F") {
                if (fields.P == null || !relative_path(value, true))
                    return { error: "apk-directory-invalid" };
                directory = value == "" ? "/" : "/" + value;
                if (exists(paths, directory))
                    return { error: "apk-path-duplicate" };
                paths[directory] = true;
                push(entries, { path: directory, type: "directory" });
                file = null;
                directory_acl = false;
                count++;
            }
            else if (key == "R") {
                if (directory == null || !relative_path(value, false) || index(value, "/") >= 0)
                    return { error: "apk-file-invalid" };
                file = directory + (directory == "/" ? "" : "/") + value;
                if (length(file) > 4096 || exists(paths, file))
                    return { error: "apk-path-duplicate-or-limit" };
                paths[file] = true;
                push(entries, { path: file, type: "non-directory" });
                acl = false;
                digest = false;
                count++;
            }
            else if (key == "M" || key == "a") {
                if ((key == "M" && (directory == null || file != null || directory_acl)) ||
                    (key == "a" && (file == null || acl)) ||
                    !match(value, ACL_PATTERN))
                    return { error: "apk-acl-invalid" };
                let ids = split(value, ":");
                if (int(ids[0], 10) > 4294967295 || int(ids[1], 10) > 4294967295)
                    return { error: "apk-acl-invalid" };
                if (key == "M") directory_acl = true;
                else acl = true;
            }
            else if (key == "Z") {
                // Digests are opaque observations, never provenance evidence.
                if (file == null || digest || length(value) > 128 || !match(value, DIGEST_PATTERN))
                    return { error: "apk-digest-invalid" };
                digest = true;
            }
            else {
                if (index("PVTULADCSIpiomtckrqsgf", key) < 0)
                    return { error: "apk-field-unsupported" };
                if (exists(fields, key) || directory != null)
                    return { error: "apk-header-duplicate-or-order" };
                fields[key] = value;
                if (index("SItkq", key) >= 0 && (length(value) > 20 || !match(value, NUMBER_PATTERN)))
                    return { error: "apk-number-invalid" };
                if (key == "f" && value != "S")
                    return { error: "apk-broken-or-unknown-flags" };
            }
            if (count > ENTRY_LIMIT)
                return { error: "apk-entry-limit" };
        }
        if (length(fields.P || "") > 128 || length(fields.V || "") > 128 || length(fields.A || "") > 64 ||
            !match(fields.P || "", NAME_PATTERN) ||
            !match(fields.V || "", VERSION_PATTERN) ||
            !match(fields.A || "", ARCH_PATTERN))
            return { error: "apk-identity-invalid" };
        if (exists(names, fields.P))
            return { error: "apk-package-duplicate" };
        names[fields.P] = true;
        push(packages, { name: fields.P, version: fields.V, depends: fields.D ?? "", provides: fields.p ?? "", entries });
        if (length(packages) > PACKAGE_LIMIT)
            return { error: "apk-package-limit" };
    }
    return { packages };
}

return { parse };
