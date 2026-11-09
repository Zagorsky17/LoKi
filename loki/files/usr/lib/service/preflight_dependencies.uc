const REQUIRED = [ "libc", "ca-bundle", "ucode", "ucode-mod-fs", "ucode-mod-resolv", "ucode-mod-socket",
    "ucode-mod-ubus", "ucode-mod-uloop", "ucode-mod-uci", "uclient-fetch", "kmod-nft-tproxy", "nftables", "kmod-nft-nat", "ip", "luci-base" ];
const PACKAGE_LIMIT = 4096;
const FIELD_LIMIT = 8192;
const TERM_LIMIT = 128;
const DEPTH_LIMIT = 64;
const WORK_LIMIT = 16384;
const PROVIDER_LIMIT = 16384;
// Keep byte limits outside recurring POSIX patterns to avoid expensive bounded-repeat automata on musl.
const NAME_PATTERN = /^[a-z0-9][a-z0-9+_.-]*$/;
const VERSION_PATTERN = /^[A-Za-z0-9][A-Za-z0-9+_.:~-]*$/;
const TOKEN_CONTROL = /[\x01-\x20\x7f]/;
const DATA_CONTROL = /[\x01-\x08\x0a-\x1f\x7f]/;
const WHITESPACE = /[ \t]+/;
const IPK_EXACT = /^([a-z0-9][a-z0-9+_.-]*)[ \t]+\(=[ \t]*([A-Za-z0-9][A-Za-z0-9+_.:~-]*)\)$/;
const APK_EXACT = /^([a-z0-9][a-z0-9+_.-]*)=([A-Za-z0-9][A-Za-z0-9+_.:~-]*)$/;

function name_valid(value) {
    return type(value) == "string" && length(value) <= 128 && index(value, "\u0000") < 0 && !match(value, TOKEN_CONTROL) &&
        match(value, NAME_PATTERN) != null;
}

function version_valid(value) {
    return type(value) == "string" && length(value) <= 128 && index(value, "\u0000") < 0 && !match(value, TOKEN_CONTROL) &&
        match(value, VERSION_PATTERN) != null;
}

function terms(data, format, provides) {
    if (type(data) != "string" || index(data, "\u0000") >= 0 || match(data, DATA_CONTROL))
        return { error: "system-dependency-metadata-unverified" };
    if (length(data) > FIELD_LIMIT) return { error: "system-dependency-metadata-limit" };
    if (trim(data) == "") return { values: [] };
    let values = split(trim(data), format == "ipk" ? "," : WHITESPACE);
    if (length(values) > TERM_LIMIT) return { error: "system-dependency-metadata-limit" };
    let result = [];
    for (let value in values) {
        value = trim(value);
        if (name_valid(value)) { push(result, { name: value }); continue; }
        // shortcut: prove byte-identical equality only; extend comparisons after native PM coverage.
        let exact = !provides || format == "apk" ? match(value, format == "ipk" ? IPK_EXACT : APK_EXACT) : null;
        if (exact == null || !name_valid(exact[1]) || !version_valid(exact[2]))
            return { error: "system-dependency-constraint-unverified" };
        push(result, { name: exact[1], version: exact[2] });
    }
    return { values: result };
}

function check(packages, format) {
    let failure = (reason) => [{ kind: "dependencies", object: "system-packages", state: "incomplete", reason }];
    if (type(format) != "string" || index(format, "\u0000") >= 0 || (format != "ipk" && format != "apk"))
        return failure("dependency-package-format-unverified");
    if (type(packages) != "array" || length(packages) > PACKAGE_LIMIT)
        return failure("system-package-metadata-unverified");
    let names = {};
    let providers = {};
    let unknown_providers = false;
    let provider_count = 0;
    for (let package in packages) {
        if (type(package) != "object" || !name_valid(package.name) || exists(names, package.name))
            return failure("system-package-metadata-unverified");
        names[package.name] = package;
        let parsed = terms(package.provides, format, true);
        if (parsed.error != null) { unknown_providers = true; continue; }
        let seen = {};
        for (let term in parsed.values) {
            if (term.name == package.name || seen[term.name]) continue;
            seen[term.name] = true;
            if (++provider_count > PROVIDER_LIMIT) return failure("system-dependency-metadata-limit");
            if (providers[term.name] == null) providers[term.name] = [];
            push(providers[term.name], { package, version: term.version });
        }
    }
    let observations = [];
    for (let required in REQUIRED) {
        let work = 0;
        let resolve;
        let inspect = (package, stack, depth) => {
            if (stack[package.name]) return null;
            if (!version_valid(package.version)) return "system-package-version-unverified";
            let parsed = terms(package.depends, format, false);
            if (parsed.error != null) return parsed.error;
            stack[package.name] = true;
            let error = null;
            for (let term in parsed.values) {
                error = resolve(term, stack, depth + 1);
                if (error != null) break;
            }
            delete stack[package.name];
            return error;
        };
        resolve = (term, stack, depth) => {
            if (++work > WORK_LIMIT || depth >= DEPTH_LIMIT) return "system-dependency-work-limit";
            let direct = names[term.name];
            let candidates = [];
            if (term.version != null) {
                if (direct != null && direct.version == term.version) push(candidates, direct);
                for (let provider in providers[term.name] || [])
                    if (provider.version == term.version) push(candidates, provider.package);
                if (length(candidates) == 0) return "system-dependency-version-unverified";
            }
            else {
                if (direct != null) push(candidates, direct);
                for (let provider in providers[term.name] || []) push(candidates, provider.package);
            }
            let error = depth == 0 ? "required-system-package-missing" : "required-system-dependency-missing";
            for (let package in candidates) {
                let candidate_error = inspect(package, stack, depth);
                if (candidate_error == null) return null;
                error = candidate_error;
                if (work > WORK_LIMIT) return "system-dependency-work-limit";
            }
            return unknown_providers ? "system-dependency-providers-unverified" : error;
        };
        let error = resolve({ name: required }, {}, 0);
        push(observations, { kind: "dependencies", object: required, state: error == null ? "checked" : "incomplete",
            reason: error ?? "system-dependency-metadata-present" });
    }
    return observations;
}

return { check };
