// Shared by nft/apply.uc and nft/ruleset_sync.uc: a set apply.uc does not create is a set
// ruleset_sync must not flush.

let common = require("core.common");
let connections = require("config.connections");
let runtime_rulesets = require("singbox.rulesets");

let as_string = common.as_string;
let object_or_empty = common.object_or_empty;

const CAPTURE_ACTIONS = {
    connection: true,
    block: true
};

const SET_SUFFIXES = {
    subnets: "_subnets",
    subnets6: "_subnets6",
    ports: "_ports",
    ip_ports: "_ip_ports",
    ip6_ports: "_ip6_ports",
    proto_ports: "_proto_ports",
    proto6_ports: "_proto6_ports",
    sources: "_sources",
    sources6: "_sources6",
    fully_sources: "_fully_sources",
    fully_sources6: "_fully_sources6"
};

function section_name(section) {
    return as_string(object_or_empty(section)[".name"]);
}

function enabled(section) {
    return common.bool_option(section, "enabled", true);
}

// "bypass", "capture" or "" for a section the table has no rule for at all.
function priority_action(section) {
    let action = common.option(section, "action", "");
    if (action == "bypass")
        return "bypass";
    return CAPTURE_ACTIONS[action] == true ? "capture" : "";
}

function set_names(section) {
    let prefix = "loki_rule_" + section_name(section);
    let result = {};

    for (let key in keys(SET_SUFFIXES))
        result[key] = prefix + SET_SUFFIXES[key];

    return result;
}

function subnet_source_tags(section) {
    section = object_or_empty(section);
    let name = section_name(section);
    let result = [];
    let seen = {};

    for (let community in connections.community_lists(section)) {
        let tag = runtime_rulesets.community_tag(name, community);
        if (runtime_rulesets.community_has_subnets(community) && !seen[tag]) {
            seen[tag] = true;
            push(result, tag);
        }
    }

    for (let reference in connections.rule_sets_with_subnets(section)) {
        let tag = runtime_rulesets.custom_reference_tag(reference);
        if (!seen[tag]) {
            seen[tag] = true;
            push(result, tag);
        }
    }

    return result;
}

// The needs_* flags name the sets the rules reference, which are the sets to create.
function matchers(section) {
    section = object_or_empty(section);

    let action = priority_action(section);
    let sources = connections.device_matchers(section, "source_ip_cidr");
    let fully = connections.device_matchers(section, "fully_routed_ips");
    let ports = connections.rule_ports_csv(section);
    let subnets = join(",", connections.destinations(section).ip_cidr);
    let tags = subnet_source_tags(section);
    let ip_matchers = subnets != "" || length(tags) > 0;
    // A port next to a destination narrows that destination instead of selecting on its own.
    let port_only = ports != "" && subnets == "" && !connections.has_dns_matchers(section);

    return {
        action: action,
        sets: set_names(section),
        subnets: subnets,
        ports: ports,
        subnet_tags: tags,
        sources: sources,
        fully: fully,
        needed: action != "" && (fully.selected || ip_matchers || port_only),
        needs_subnet_sets: ip_matchers,
        needs_port_set: ports != "" && (ip_matchers || port_only),
        needs_ip_port_sets: length(tags) > 0,
        needs_proto_port_sets: length(tags) > 0,
        needs_source_sets: length(sources.ips) > 0,
        needs_fully_source_sets: length(fully.ips) > 0
    };
}

// The sets the rule-set worker writes; a rebuilt table keeps their elements.
function provider_sets(m) {
    let s = m.sets;
    return length(m.subnet_tags) == 0 ? [] : [ s.subnets, s.subnets6, s.ip_ports, s.ip6_ports, s.proto_ports, s.proto6_ports ];
}

function with_priority_sets(sections) {
    let result = [];
    let seen = {};

    for (let section in sections) {
        section = object_or_empty(section);
        if (!enabled(section))
            continue;

        let entry = matchers(section);
        if (!entry.needed)
            continue;

        let name = section_name(section);
        if (seen[name])
            return { error: "duplicate nft section: " + name, sections: [] };
        seen[name] = true;

        push(result, { section: section, matchers: entry });
    }

    return { error: "", sections: result };
}

return {
    enabled,
    matchers,
    provider_sets,
    with_priority_sets
};
