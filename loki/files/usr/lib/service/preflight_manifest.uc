// A machine-written catalog, not authorization to install or trust an artifact.
const ROLES = { backend: "loki", luci: "luci-app-loki", core: "loki-core", locale: "luci-i18n-loki-ru" };
const LIMIT = 536870912;
// Keep recurring POSIX expressions simple and enforce byte bounds separately on musl.
const TOKEN_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_.+~-]*$/;
const TOKEN_CONTROL = /[\x01-\x20\x7f]/;
const HASH_PATTERN = /^[a-f0-9]{64}$/;
const PATH_PATTERN = /^\/[A-Za-z0-9_.+@\/-]+$/;
const DOT_COMPONENT = /\/(\.\.?)(\/|$)/;
const CORE_VERSION_PATTERN = /^[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+(\+[0-9]+)?$/;
const REQUIRED = {
    backend: { "/usr/bin/loki": 0755, "/etc/config/loki": 0600,
        "/etc/init.d/loki": 0755, "/etc/init.d/loki-state": 0755, "/lib/upgrade/keep.d/loki": 0644,
        "/usr/libexec/loki-gateway": 0755, "/usr/share/loki/default-config": 0644, "/usr/share/loki/install.sh": 0644,
        "/usr/share/nftables.d/chain-pre/input/loki.nft": 0644 },
    luci: { "/www/luci-static/resources/view/loki/main.js": 0644, "/www/luci-static/resources/view/loki/loki.js": 0644,
        "/usr/share/rpcd/acl.d/luci-app-loki.json": 0644, "/usr/share/luci/menu.d/luci-app-loki.json": 0644,
        "/usr/share/loki/yacd/index.html": 0644 },
    core: { "/usr/bin/loki-core": 0755, "/etc/config/loki-core": 0600, "/etc/init.d/loki-core": 0755,
        "/etc/loki-core/config.json": 0600, "/lib/upgrade/keep.d/loki-core": 0644,
        "/usr/share/loki-core/version": 0644, "/usr/share/loki-core/variant": 0644,
        "/usr/share/licenses/loki-core/build-info.json": 0644, "/usr/share/licenses/loki-core/THIRD_PARTY_NOTICES": 0644 },
    locale: { "/usr/lib/lua/luci/i18n/loki.ru.lmo": 0644 }
};
const PREFIXES = {
    backend: [ "/usr/lib/loki/", "/usr/share/licenses/loki/" ],
    luci: [ "/www/luci-static/resources/view/loki/", "/usr/share/loki/yacd/", "/usr/share/licenses/luci-app-loki/" ],
    core: [ "/usr/share/loki-core/", "/usr/share/licenses/loki-core/" ],
    locale: [ "/usr/share/licenses/luci-i18n-loki-ru/" ]
};

function component_policy(components) {
    let item = (state, reason) => ({ kind: "candidate-manifest", object: "component-set", state, reason });
    let failure = (reason) => item("incomplete", reason);
    let roles = {};
    for (let component in components) roles[component.role] = component;
    for (let role in [ "backend", "luci", "core" ])
        if (roles[role] == null) return failure("candidate-component-required-missing");
    if (roles.backend.version != roles.luci.version ||
        (roles.locale != null && roles.locale.version != roles.backend.version))
        return failure("candidate-component-versions-mismatch");
    let version = roles.core.version;
    if (length(version) > 64 || !match(version, CORE_VERSION_PATTERN) ||
        !require("core.version").version_at_least(version, require("core.constants").SB_REQUIRED_VERSION))
        return failure("candidate-core-version-unverified");
    for (let component in components) {
        let required = {};
        for (let path in keys(REQUIRED[component.role])) required[path] = REQUIRED[component.role][path];
        required["/usr/share/licenses/" + component.package + "/LICENSE"] = 0644;
        if (component.format == "apk") required["/lib/apk/packages/" + component.package + ".list"] = 0644;
        let metadata = component.format == "apk" ? [ "/lib/apk/packages/" + component.package + ".conffiles",
            "/lib/apk/packages/" + component.package + ".conffiles_static" ] : [];
        let files = {};
        let parents = {};
        for (let file in component.files) {
            if (file.type != "file") continue;
            let configuration_list = index(metadata, file.path) >= 0;
            if (configuration_list && file.mode != 0644) return failure("candidate-component-file-unverified");
            let owned = exists(required, file.path) || configuration_list;
            for (let prefix in PREFIXES[component.role])
                if (substr(file.path, 0, length(prefix)) == prefix) owned = true;
            if (!owned) return failure("candidate-component-path-unverified");
            files[file.path] = file;
            let parts = split(file.path, "/");
            let parent = "";
            parents["/"] = true;
            for (let i = 1; i < length(parts) - 1; i++) {
                parent += "/" + parts[i];
                parents[parent] = true;
            }
        }
        for (let file in component.files)
            if (file.type == "directory" && (file.mode != 0755 || !parents[file.path]))
                return failure("candidate-component-directory-unverified");
        for (let path in keys(required))
            if (files[path] == null || files[path].mode != required[path])
                return failure("candidate-component-file-unverified");
    }
    return item("checked", "candidate-component-metadata-checked");
}

function fields(value, expected) {
    return type(value) == "object" && join(",", sort(keys(value))) == expected;
}

function integer(value, maximum) {
    return type(value) == "int" && value >= 0 && value <= maximum;
}

function token(value) {
    return type(value) == "string" && length(value) <= 128 && index(value, "\u0000") < 0 &&
        !match(value, TOKEN_CONTROL) && match(value, TOKEN_PATTERN) != null;
}

function hash(value) {
    return type(value) == "string" && length(value) == 64 && index(value, "\u0000") < 0 && match(value, HASH_PATTERN) != null;
}

function path_valid(path) {
    return type(path) == "string" && index(path, "\u0000") < 0 && length(path) <= 4096 && !match(path, TOKEN_CONTROL) &&
        (path == "/" || (match(path, PATH_PATTERN) != null && substr(path, -1) != "/")) &&
        index(path, "//") < 0 && match(path, DOT_COMPONENT) == null;
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
        roles[component.role] = component.architecture;
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
    return { paths, architectures: roles, format, component_policy: component_policy(manifest.components) };
}

return { parse };
