// Lookups over a generated loki-core configuration.

function as_array(value) {
    if (value == null)
        return [];
    return type(value) == "array" ? value : [ value ];
}

// Whether a matcher value - one item or a list of them - holds the needle.
function has(values, needle) {
    for (let value in as_array(values))
        if (value == needle)
            return true;
    return false;
}

function find(items, predicate) {
    for (let item in items ?? [])
        if (item != null && predicate(item))
            return item;
    return null;
}

function position(items, predicate) {
    items = items ?? [];
    for (let i = 0; i < length(items); i++)
        if (items[i] != null && predicate(items[i]))
            return i;
    return -1;
}

function by_tag(items, tag) {
    return find(items, (item) => item.tag == tag);
}

function outbound(config, tag) { return by_tag(config.outbounds, tag); }
function inbound(config, tag) { return by_tag(config.inbounds, tag); }
function endpoint(config, tag) { return by_tag(config.endpoints, tag); }
function provider(config, tag) { return by_tag(config.providers, tag); }
function ruleset(config, tag) { return by_tag(config.route.rule_set, tag); }
function ruleset_url(config, url) { return find(config.route.rule_set, (r) => r.url == url); }
function ruleset_path(config, path) { return find(config.route.rule_set, (r) => r.path == path); }
function first_remote_ruleset(config) { return find(config.route.rule_set, (r) => r.type == "remote"); }
function route_rule(config, predicate) { return find(config.route.rules, predicate); }
function route_rule_index(config, predicate) { return position(config.route.rules, predicate); }
function dns_rule(config, predicate) { return find(config.dns.rules, predicate); }
function dns_rule_index(config, predicate) { return position(config.dns.rules, predicate); }
function dns_server(config, predicate) { return find(config.dns.servers, predicate); }
function dns_server_tag(config, tag) { return by_tag(config.dns.servers, tag); }

function tags(items) {
    return map(items ?? [], (item) => item.tag);
}

function no_internal_fields(value) {
    if (type(value) == "array") {
        for (let item in value)
            if (!no_internal_fields(item))
                return false;
    }
    else if (type(value) == "object") {
        for (let key, item in value) {
            if (substr(key, 0, 2) == "__")
                return false;
            if (!no_internal_fields(item))
                return false;
        }
    }
    return true;
}

return {
    as_array, has, find, position, outbound, inbound, endpoint, provider, ruleset, ruleset_url, ruleset_path,
    first_remote_ruleset, route_rule, route_rule_index, dns_rule, dns_rule_index, dns_server, dns_server_tag,
    tags, no_internal_fields
};
