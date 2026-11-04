// Modified for LoKi on 2026-11-01: identify known overlapping list sources without changing them.
// The lists of github.com/ushan0v/forkop-lists by the name a section stores; a release names
// each file after its list, "-" for "_". subnets: the list carries addresses the core exports
// for nftables.
const LISTS_URL = "https://github.com/ushan0v/forkop-lists/releases/latest/download";

const COMMUNITY_SERVICES = {
    ru_blocked_all: { subnets: true },
    ru_blocked_rkn: { subnets: true },
    ru_blocked_geo: { subnets: true },
    ru_only: {},
    ua_blocked: {},
    ai: { subnets: true },
    chatgpt: {},
    claude: { subnets: true },
    cloudflare: { subnets: true },
    discord: { subnets: true },
    facebook: {},
    gemini: {},
    github: {},
    google_play: {},
    instagram: {},
    roblox: { subnets: true },
    spotify: {},
    supercell: {},
    telegram: { subnets: true },
    tiktok: {},
    twitch: {},
    whatsapp: { subnets: true },
    x: { subnets: true },
    youtube: {},
    ads: {}
};

function as_string(value) {
    return value == null ? "" : "" + value;
}

function is_community(name) {
    return type(COMMUNITY_SERVICES[as_string(name)]) == "object";
}

function community_has_subnets(name) {
    return is_community(name) && COMMUNITY_SERVICES[as_string(name)].subnets == true;
}

function community_url(name) {
    return LISTS_URL + "/" + replace(as_string(name), /_/g, "-") + ".srs";
}

const REGIONAL_INCLUDES = {
    ru_blocked_all: [ "ru_blocked_rkn", "ru_blocked_geo", "youtube", "discord", "facebook", "instagram", "x", "telegram", "whatsapp", "roblox", "chatgpt", "claude", "gemini", "spotify", "supercell", "tiktok" ],
    ru_blocked_rkn: [ "youtube", "discord", "facebook", "instagram", "x", "telegram", "whatsapp", "roblox" ],
    ru_blocked_geo: [ "chatgpt", "claude", "gemini", "spotify", "supercell", "tiktok" ]
};
const LEGACY_URL = "https://github.com/itdoginfo/allow-domains/releases/latest/download/";
const LEGACY_HOLDERS = {
    russia_inside: [ "ru_blocked_all", "ru_blocked_rkn", "ru_blocked_geo" ],
    meta: [ "ru_blocked_all", "ru_blocked_rkn" ]
};

function reference_community(reference) {
    if (is_community(reference))
        return reference;
    let prefix = LISTS_URL + "/";
    if (substr(reference, 0, length(prefix)) != prefix)
        return null;
    let name = replace(replace(substr(reference, length(prefix)), /-/g, "_"), /\.srs$/, "");
    return is_community(name) && reference == community_url(name) ? name : null;
}

// Exact known references only: shared provenance does not prove identical file contents.
function overlaps(communities, references) {
    let selected = {};
    for (let name in communities)
        if (is_community(name))
            selected[name] = true;
    if (length(keys(selected)) == 0)
        return [];
    let result = [];
    let seen = {};
    for (let reference in references) {
        reference = as_string(reference);
        let name = reference_community(reference);
        let legacy = reference == LEGACY_URL + "russia_inside.srs" ? "russia_inside"
            : reference == LEGACY_URL + "meta.srs" ? "meta" : null;
        if (name == null && legacy == null)
            continue;
        let external = name != null ? "forkop-lists/" + replace(name, /_/g, "-") + ".srs" : "itdog/" + legacy + ".srs";
        if (seen[external])
            continue;
        seen[external] = true;
        let builtin = name != null && selected[name] ? name : null;
        let relation = builtin != null ? "same_source" : "possible_overlap";
        if (builtin == null)
            for (let holder in communities)
                if ((name != null && index(REGIONAL_INCLUDES[holder] ?? [], name) >= 0) ||
                    (legacy != null && index(LEGACY_HOLDERS[legacy], holder) >= 0)) {
                    builtin = holder;
                    break;
                }
        if (builtin != null)
            push(result, { builtin, external, relation });
    }
    return result;
}

// Twelve hex digits naming a rule set reference too long for a tag: two multiplicative hashes
// folded to 24 bits each. The constants are frozen, since changing one renames every inline
// custom rule set in the generated config.
function hash12(value) {
    value = as_string(value);
    let first = 2166136261;
    let second = 16777619;

    for (let i = 0; i < length(value); i++) {
        let code = ord(substr(value, i, 1));
        first = (first * 33 + code) % 4294967296;
        second = (second * 131 + code) % 4294967296;
    }

    return sprintf("%06x%06x", first % 16777216, second % 16777216);
}

function section_tag(section_name, name, kind) {
    kind = as_string(kind);
    return kind == ""
        ? as_string(section_name) + "-" + as_string(name) + "-ruleset"
        : as_string(section_name) + "-" + as_string(name) + "-" + kind + "-ruleset";
}

function community_tag(section_name, community) {
    return section_tag(section_name, community, "community");
}

function custom_reference_tag(reference) {
    reference = as_string(reference);
    return is_community(reference)
        ? "builtin-" + reference + "-ruleset"
        : "inline-custom-" + hash12(reference) + "-ruleset";
}

return {
    overlaps,
    COMMUNITY_SERVICES,
    is_community,
    community_has_subnets,
    community_url,
    community_tag,
    custom_reference_tag
};
