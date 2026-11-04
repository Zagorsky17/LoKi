// A machine-written catalog, not authorization to install or trust an artifact.
const ROLES = { backend: "loki", luci: "luci-app-loki", core: "loki-core", locale: "luci-i18n-loki-ru" };
const LIMIT = 536870912;

function fields(value, expected) {
    return type(value) == "object" && join(",", sort(keys(value))) == expected;
}

function integer(value, maximum) {
    return type(value) == "int" && value >= 0 && value <= maximum;
}

function token(value) {
    return type(value) == "string" && index(value, "\u0000") < 0 && match(value, /^[A-Za-z0-9][A-Za-z0-9_.+~-]{0,127}$/) != null;
}

function hash(value) {
    return type(value) == "string" && index(value, "\u0000") < 0 && match(value, /^[a-f0-9]{64}$/) != null;
}

function path_valid(path) {
    return type(path) == "string" && index(path, "\u0000") < 0 && length(path) <= 4096 &&
        (path == "/" || (match(path, /^\/[A-Za-z0-9_.+@\/-]+$/) != null && substr(path, -1) != "/")) &&
        index(path, "//") < 0 && match(path, /\/(\.\.?)(\/|$)/) == null;
}

function encode_file(file) {
    return sprintf('{"gid":%d,"mode":%d,"path":%J,"sha256":%J,"size":%d,"type":%J,"uid":%d}',
        file.gid, file.mode, file.path, file.sha256, file.size, file.type, file.uid);
}

function encode_component(component) {
    let artifact = component.artifact;
    let files = map(component.files, encode_file);
    return sprintf('{"architecture":%J,"artifact":{"name":%J,"sha256":%J,"size":%d},"files":[%s],"format":%J,"package":%J,"role":%J,"version":%J}',
        component.architecture, artifact.name, artifact.sha256, artifact.size, join(",", files),
        component.format, component.package, component.role, component.version);
}

function parse(data) {
    if (type(data) != "string" || length(data) > 2097152)
        return { error: "manifest-byte-limit" };
    let manifest;
    try { manifest = json(data); }
    catch (e) { return { error: "manifest-json-invalid" }; }
    if (!fields(manifest, "components,schema") || type(manifest.schema) != "int" || manifest.schema != 1 ||
        type(manifest.components) != "array" || length(manifest.components) < 1 || length(manifest.components) > 4)
        return { error: "manifest-schema-invalid" };
    let roles = {};
    let artifacts = {};
    let paths = {};
    let entries = 0;
    let total = 0;
    let format = null;
    for (let component in manifest.components) {
        if (!fields(component, "architecture,artifact,files,format,package,role,version") ||
            !token(component.role) || !exists(ROLES, component.role) || !token(component.package) || ROLES[component.role] != component.package ||
            !token(component.version) || !token(component.architecture) ||
            !token(component.format) || (component.format != "ipk" && component.format != "apk") ||
            type(component.files) != "array" || length(component.files) < 1)
            return { error: "manifest-component-invalid" };
        if (exists(roles, component.role) || (format != null && format != component.format))
            return { error: "manifest-component-duplicate-or-format" };
        format = component.format;
        roles[component.role] = true;
        let artifact = component.artifact;
        if (!fields(artifact, "name,sha256,size") || !token(artifact.name) ||
            substr(artifact.name, -4) != "." + component.format || !hash(artifact.sha256) ||
            !integer(artifact.size, LIMIT) || artifact.size == 0 || exists(artifacts, artifact.name))
            return { error: "manifest-artifact-invalid" };
        artifacts[artifact.name] = true;
        let seen = {};
        for (let file in component.files) {
            if (++entries > 4096)
                return { error: "manifest-entry-limit" };
            if (!fields(file, "gid,mode,path,sha256,size,type,uid") || !path_valid(file.path) ||
                !token(file.type) || (file.type != "file" && file.type != "directory") || (file.path == "/" && file.type != "directory") ||
                !integer(file.uid, 0) || !integer(file.gid, 0) || !integer(file.mode, 0777) ||
                (file.mode & 0022) != 0 || !integer(file.size, LIMIT))
                return { error: "manifest-file-invalid" };
            if ((file.type == "file" && !hash(file.sha256)) ||
                (file.type == "directory" && (file.size != 0 || file.sha256 != null)))
                return { error: "manifest-file-content-invalid" };
            total += file.size;
            if (total > LIMIT)
                return { error: "manifest-total-size-limit" };
            if (exists(seen, file.path))
                return { error: "manifest-path-duplicate" };
            seen[file.path] = true;
            if (exists(paths, file.path) && (file.type != "directory" ||
                encode_file(paths[file.path]) != encode_file(file)))
                return { error: "manifest-owner-ambiguous" };
            paths[file.path] = file;
        }
    }
    // Require all parents in the catalog; a file cannot hide beneath another file.
    for (let path in paths) {
        let parts = split(path, "/");
        let parent = "";
        for (let i = 1; i < length(parts) - 1; i++) {
            parent += "/" + parts[i];
            if (paths[parent]?.type != "directory")
                return { error: "manifest-parent-missing-or-not-directory" };
        }
    }
    // Re-encoding this fixed schema detects duplicate keys lost by json(), too.
    let canonical = '{"components":[' + join(",", map(manifest.components, encode_component)) + '],"schema":1}\n';
    if (data != canonical)
        return { error: "manifest-noncanonical" };
    return { paths };
}

return { parse };
