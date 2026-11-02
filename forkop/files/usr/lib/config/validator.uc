// Modified for LoKi on 2026-11-01: warn about known list overlaps after validating references.
let fs = require("fs");
let core_common = require("core.common");
let core_exec = require("core.exec");
let core_url = require("core.url");
let core_ip = require("core.ip");
let uci_core = require("core.uci");
let constants = require("core.constants");
let rule_config = require("config.rule");
let core_version = require("core.version");
let packages = require("core.packages");
let connections = require("config.connections");
let singbox_constants = require("singbox.constants");
let rulesets = require("singbox.rulesets");
let runtime_dns = require("singbox.dns");
let features = require("singbox.features");
let runtime_urltest = require("singbox.urltest");
let subscription_headers_module = require("singbox.subscription_headers");
let nft_state = require("nft.state");

let as_string = core_common.as_string;
let object_or_empty = core_common.object_or_empty;
let array_or_empty = core_common.array_or_empty;
let option = core_common.option;
let list_option = core_common.list_option;
let bool_option = core_common.bool_option;
let parse_number = core_common.parse_number;

const CONFIG_NAME = "forkop";
const DEFAULT_LATENCY_TEST_URL = "https://www.gstatic.com/generate_204";
const TAILSCALE_FWMARK_MASK = 0x00ff0000;

function string_starts_with(value, prefix) {
    value = as_string(value);
    prefix = as_string(prefix);
    return substr(value, 0, length(prefix)) == prefix;
}

function whitespace_values(value) {
    let result = [];
    for (let item in split(trim(as_string(value)), /[ \t\r\n]+/))
        if (item != "")
            push(result, item);
    return result;
}

function option_list_values(section, key) {
    let value = type(section) == "object" ? section[key] : null;
    if (type(value) == "array")
        return value;
    return whitespace_values(value);
}

function contains(values, needle) {
    for (let value in array_or_empty(values))
        if (value == needle)
            return true;
    return false;
}

function file_executable(path) {
    let stat = fs.stat(as_string(path));
    if (stat == null || stat.mode == null)
        return false;

    return (int(stat.mode) & 73) != 0;
}

function command_exists(name) {
    return core_exec.ok([ "sh", "-c", "command -v \"$1\"", "sh", name ]);
}

// Why a pattern sing-box matches with RE2 cannot be matched the same way here, or null.
function regex_problem(pattern) {
    try {
        runtime_urltest.compile(pattern);
        return null;
    }
    catch (e) {
        return e.message;
    }
}

function remote_reference(value) {
    return string_starts_with(value, "http://") || string_starts_with(value, "https://");
}

function absolute_reference(value) {
    value = as_string(value);
    return string_starts_with(value, "/");
}

function ruleset_reference_valid(reference) {
    reference = as_string(reference);
    let path = lc(replace(reference, /[?#].*$/, ""));
    if (match(path, /\.ya?ml$/) != null)
        return false;

    return reference == "" ||
        rulesets.is_community(reference) ||
        remote_reference(reference) ||
        absolute_reference(reference);
}

function fail_validation(message) {
    die(message);
}

function dhcp_has_https_dns_proxy_options(path) {
    let data = fs.readfile(as_string(path));
    if (data == null)
        return null;

    return index(data, "doh_backup_noresolv") >= 0 ||
        index(data, "doh_backup_server") >= 0 ||
        index(data, "doh_server") >= 0;
}

function settings_section() {
    return object_or_empty(uci_core.get_all(CONFIG_NAME, "settings"));
}

function sections_by_type(type_name) {
    return uci_core.section_objects(CONFIG_NAME, type_name);
}

function section_name(section) {
    return option(section, ".name", "");
}

function section_label(section) {
    return connections.section_display_name(section);
}

function section_enabled(section) {
    return bool_option(section, "enabled", true);
}

function validate_runtime_display_names(sections, kind, seen) {
    let reserved = object_or_empty(singbox_constants.RESERVED_TAGS);
    for (let section in sections) {
        let name = trim(option(section, "label", "")) || section_name(section);
        if (name == "")
            fail_validation(kind + " has no display name");
        if (index(name, "/") >= 0)
            fail_validation(kind + " display name '" + name + "' contains '/'. Use another character");
        if (reserved[name])
            fail_validation(kind + " display name '" + name + "' is reserved by Forkop. Choose another name");
        if (seen[name])
            fail_validation("Duplicate " + lc(kind) + " display name '" + name + "'. Display names must be unique");
        seen[name] = true;
    }
}

function validate_subscription_tags(section) {
    let seen = {};
    for (let tag_name in connections.subscription_tags(section)) {
        if (trim(tag_name) == "")
            fail_validation("A subscription in section '" + section_label(section) + "' has no name. Set one in its settings");
        if (index(tag_name, "/") >= 0)
            fail_validation("Subscription name '" + tag_name + "' in section '" + section_label(section) + "' contains '/'. Use another character");
        if (seen[tag_name])
            fail_validation("Duplicate subscription name '" + tag_name + "' in section '" + section_label(section) + "'");
        seen[tag_name] = true;
    }
}

// The core reads http(s)://[user:pass@]host[:port][#name] as an HTTP proxy only when
// it names credentials, a port or a node; a path means a web page. Mirrors validateProxyUrl.ts.
function subscription_address(uri) {
    let parts = match(uri, /^https?:\/\/([^\/?#]*)([^?#]*)[^#]*(#(.*))?$/i);
    if (parts == null)
        return false;

    let authority = parts[1], path = parts[2];
    let proxy = index(authority, "@") >= 0 || match(authority, /:[0-9]+$/) != null || length(parts[4] ?? "") > 0;
    return (path != "" && path != "/") || !proxy;
}

function validate_connection_links(section) {
    for (let link in connections.connection_link_items(section)) {
        let link_name = option(link, "name", "");
        let uri = trim(option(link, "uri", ""));
        if (uri == "")
            fail_validation("A link in section '" + section_label(section) + "' is empty. Paste the link in its settings");
        if (subscription_address(uri))
            fail_validation("Link '" + link_name + "' in section '" + section_label(section) + "' is probably a subscription URL. Paste it into Subscription");
        if (trim(link_name) == "")
            fail_validation("A link in section '" + section_label(section) + "' has no name. Set one in its settings");
    }
}

const CHILD_KINDS = {
    link: [ "a link", "link" ],
    interface: [ "an interface", "interface" ],
    json: [ "a JSON outbound", "JSON outbound" ],
    urltest: [ "a URLTest", "URLTest" ],
    fallback: [ "a fallback group", "fallback group" ]
};

// Children run as "<section>/<name>", so a name is unique in its section and holds no "/".
function validate_section_child_names(section) {
    let owners = {};
    for (let child in connections.section_child_names(section)) {
        let name = child.name;
        if (index(name, "/") >= 0)
            fail_validation("Name '" + name + "' in section '" + section_label(section) + "' contains '/'. Use another character");
        let owner = owners[name];
        if (owner == child.kind)
            fail_validation("Section '" + section_label(section) + "' has more than one " + CHILD_KINDS[owner][1] + " named '" + name + "'");
        if (owner != null)
            fail_validation("Section '" + section_label(section) + "' has " + CHILD_KINDS[owner][0] + " and " +
                CHILD_KINDS[child.kind][0] + " named '" + name + "'. Rename one of them");
        owners[name] = child.kind;
    }
}

function rule_action(section) {
    return option(section, "action", "");
}

function rule_action_supported(action) {
    return contains([ "connection", "bypass", "block", "dns" ], as_string(action));
}

function find_section(sections, name) {
    for (let section in sections)
        if (section_name(section) == name)
            return section;
    return null;
}

// The runtime leaves out a section without servers, so a reference to one would name an
// outbound that does not exist.
function outbound_section(sections, label, target_name) {
    let target = find_section(sections, target_name);
    let reason = target == null ? "section '" + target_name + "', which does not exist"
        : !section_enabled(target) ? "section '" + section_label(target) + "', which is disabled"
        : !connections.is_connections_action(rule_action(target)) ? "section '" + section_label(target) + "', whose action is '" + rule_action(target) + "'"
        : !connections.has_connection_sources(target) ? "section '" + section_label(target) + "', which has no servers"
        : null;
    if (reason != null)
        fail_validation(label + " points to " + reason + ". Select an enabled Connection section with servers");
    return target;
}

function section_cascades(section) {
    let owner = " in section '" + section_label(section) + "'";
    let result = [];
    let add = (label, target) => {
        if (target != "")
            push(result, { label, target });
    };
    for (let link in connections.connection_link_items(section))
        add("The cascade of link '" + option(link, "name", "") + "'" + owner, connections.cascade_section(link));
    for (let subscription in connections.subscription_items(section))
        add("The cascade of subscription '" + option(subscription, "tag", "") + "'" + owner, connections.cascade_section(subscription));
    return result;
}

function cascade_neighbours(sections, name) {
    let section = find_section(sections, name);
    if (section == null || !section_enabled(section) || !connections.is_connections_action(rule_action(section)))
        return [];
    let result = map(section_cascades(section), (item) => item.target);
    return result;
}

function cascade_reaches(sections, from, to) {
    let seen = {};
    for (let queue = [ from ]; length(queue) > 0;) {
        let current = shift(queue);
        if (current == to)
            return true;
        if (seen[current])
            continue;
        seen[current] = true;
        push(queue, ...cascade_neighbours(sections, current));
    }
    return false;
}

function validate_cascades(sections) {
    for (let section in sections) {
        if (!section_enabled(section) || !connections.is_connections_action(rule_action(section)))
            continue;
        let name = section_name(section);
        for (let item in section_cascades(section)) {
            if (item.target == name)
                fail_validation(item.label + " cannot point to its own section");
            let target = outbound_section(sections, item.label, item.target);
            if (cascade_reaches(sections, item.target, name))
                fail_validation(item.label + " loops back through section '" + section_label(target) + "'");
        }
    }
}

function validate_download_section(sections, target_name) {
    if (as_string(target_name) == "")
        fail_validation("Downloading external resources through a section is enabled, but no download section is selected");
    outbound_section(sections, "Downloading external resources through a section", target_name);
}

function validate_duration_option(value, label) {
    if (as_string(value) == "")
        return;

    if (core_common.duration_to_seconds(value) != null)
        return;

    fail_validation("Invalid duration value for " + label + ": " + value + ". Use sing-box duration format like 1d, 12h or 30m");
}

function validate_required_duration_option(value, label) {
    if (as_string(value) == "")
        fail_validation("Missing duration value for " + label + ". Use sing-box duration format like 1d, 12h or 30m");

    validate_duration_option(value, label);
}

function dns_setting_values(settings, key) {
    let values = [];
    for (let value in option_list_values(settings, key)) {
        value = trim(as_string(value));
        if (value != "")
            push(values, value);
    }
    return values;
}

function validate_dns_settings(settings, sections, context) {
    validate_required_duration_option(option(settings, "dns_timeout", "10s"), "'DNS timeout' in Settings");
    let dns_strategy = option(settings, "dns_strategy", "prefer_ipv4");
    if (!contains([ "prefer_ipv4", "ipv4_only", "prefer_ipv6", "ipv6_only" ], dns_strategy))
        fail_validation("Unsupported DNS strategy '" + dns_strategy + "'. Use prefer_ipv4, ipv4_only, prefer_ipv6, or ipv6_only");

    for (let strategy_option in [ [ "dns_main_fallback_strategy", "Main DNS Query Mode" ], [ "dns_bootstrap_fallback_strategy", "Bootstrap DNS Query Mode" ] ]) {
        let fallback_strategy = option(settings, strategy_option[0], "parallel");
        if (!contains([ "sequential", "parallel" ], fallback_strategy))
            fail_validation("Unsupported value '" + fallback_strategy + "' of '" + strategy_option[1] + "' in Settings. Use sequential or parallel");
    }

    let main_servers = dns_setting_values(settings, "dns_server");
    let bootstrap_servers = dns_setting_values(settings, "bootstrap_dns_server");
    if (length(main_servers) == 0)
        fail_validation("At least one main DNS server is required");
    if (length(bootstrap_servers) == 0)
        fail_validation("At least one Bootstrap DNS server is required");
    for (let i, value in main_servers) {
        let parsed = runtime_dns.parse_server_uri(value, false);
        if (parsed.unsupported)
            fail_validation("Invalid main DNS server #" + (i + 1) + ": " + parsed.unsupported);
    }
    for (let i, value in bootstrap_servers) {
        let parsed = runtime_dns.parse_server_uri(value, true);
        if (parsed.unsupported)
            fail_validation("Invalid Bootstrap DNS server #" + (i + 1) + ": " + parsed.unsupported);
    }

    let encryption_error = runtime_dns.encryption_error(settings);
    if (encryption_error != "")
        fail_validation(encryption_error);

    let static_hosts = runtime_dns.static_hosts(settings);
    if (static_hosts.unsupported)
        fail_validation("Static DNS records are invalid: " + static_hosts.unsupported);

    if (!bool_option(settings, "dns_detour_enabled", false))
        return;

    let target_name = option(settings, "dns_detour_section", "");
    if (target_name == "")
        fail_validation("DNS through a section is enabled, but no section is selected");

    outbound_section(sections, "DNS through a section", target_name);
}

// Accepts exactly what config/rule.uc can normalize.
function validate_port_condition_value(value, section) {
    if (rule_config.normalize_port_condition_value(value) != null)
        return;

    fail_validation("Invalid port condition '" + value + "' in section '" + section_label(section) + "'. Use a single port or range like 80 or 1000-2000");
}

function valid_http_url(value) {
    value = trim(as_string(value));
    if (value == "" || match(value, /[ \t\r\n]/) != null)
        return false;

    let scheme = lc(core_url.scheme(value));
    if (scheme != "http" && scheme != "https")
        return false;

    return core_url.host(value) != "";
}

function valid_local_subscription_path(value) {
    value = trim(as_string(value));
    return match(value, /^\/[-a-zA-Z0-9_\/.]+$/) != null;
}

function validate_subscription_source_entry_value(entry, section) {
    if (index(as_string(entry), "|") >= 0)
        fail_validation("Invalid subscription URL in section '" + section_label(section) + "': set the User-Agent in the subscription headers instead");

    if (valid_http_url(entry) || valid_local_subscription_path(entry))
        return;

    fail_validation("Invalid subscription source '" + entry + "' in section '" + section_label(section) + "'. Use an http:// or https:// URL or an absolute local path");
}

function validate_http_url_option(value, label) {
    if (valid_http_url(value))
        return;

    fail_validation("Invalid URL value for " + label + ": " + value + ". Use http:// or https:// URL");
}

function validate_filter_regex_value(value, owner) {
    let problem = as_string(value) == "" ? null : regex_problem(value);
    if (problem != null)
        fail_validation("Invalid regular expression '" + value + "' in " + owner + ": " + problem);
}

function validate_urltest_tolerance_value(value, owner) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]+$/) != null) {
        let parsed = int(value, 10);
        if (parsed >= 0 && parsed <= 10000)
            return;
    }

    fail_validation("Invalid tolerance '" + value + "' of " + owner + ". Use a number from 0 to 10000");
}

function validate_fallback_level_order(value, owner) {
    value = trim(as_string(value));
    if (match(value, /^[0-9]+$/) != null)
        return;

    fail_validation("Invalid order '" + value + "' of " + owner + ". Use a non-negative integer");
}

function expected_status_valid(value) {
    value = trim(as_string(value));
    if (value == "" || value == "*")
        return true;

    let parts = split(replace(value, /,/g, "/"), "/");
    if (length(parts) > 28)
        return false;

    for (let part in parts) {
        part = trim(as_string(part));
        if (part == "")
            continue;

        let bounds = split(part, "-");
        if (length(bounds) < 1 || length(bounds) > 2)
            return false;
        let parsed_bounds = [];
        for (let bound in bounds) {
            bound = replace(trim(as_string(bound)), /[\[\] ]/g, "");
            if (match(bound, /^[0-9]+$/) == null)
                return false;
            let parsed = int(bound, 10);
            if (parsed < 100 || parsed > 599)
                return false;
            push(parsed_bounds, parsed);
        }
        if (length(parsed_bounds) == 2 && parsed_bounds[0] > parsed_bounds[1])
            return false;
    }
    return true;
}

function validate_server_filter_mode(value, context, direct_allowed) {
    if (contains([ "all", "exclude", "include" ], value) ||
        (direct_allowed && value == "direct"))
        return;

    fail_validation("Invalid server filter mode '" + value + "' in " + context);
}

function validate_server_filter_regexes(mode, include_regex, exclude_regex, owner) {
    if (mode == "include")
        validate_filter_regex_value(include_regex, owner);
    if (mode == "include" || mode == "exclude")
        validate_filter_regex_value(exclude_regex, owner);
}

function validate_server_filter_types(values, allowed, context) {
    let supported = {};
    for (let value in array_or_empty(allowed))
        supported[value] = true;

    for (let value in array_or_empty(values)) {
        value = trim(as_string(value));
        if (value != "" && !supported[lc(value)])
            fail_validation("Server type '" + value + "' is not available in " + context);
    }
}

function validate_fallback_group(section, group_id) {
    let group_name = trim(connections.fallback_group_display_name(section, group_id));
    if (group_name == "")
        fail_validation("A fallback group in section '" + section_label(section) + "' has no name");

    let group = "fallback group '" + group_name + "' in section '" + section_label(section) + "'";
    let health_check_interval = connections.fallback_group_health_check_interval(section, group_id);
    let idle_timeout = connections.fallback_group_idle_timeout(section, group_id);
    validate_http_url_option(connections.fallback_group_health_check_url(section, group_id), "'Check URL' of " + group);
    validate_required_duration_option(health_check_interval, "'Check interval' of " + group);
    validate_required_duration_option(connections.fallback_group_health_check_timeout(section, group_id), "'Check timeout' of " + group);
    validate_required_duration_option(connections.fallback_group_attempt_timeout(section, group_id), "'Connection timeout' of " + group);
    let expected_status = connections.fallback_group_expected_status(section, group_id);
    if (!expected_status_valid(expected_status))
        fail_validation("Invalid 'Expected status' of " + group + ". Use *, status codes, or ranges such as 204/200-299");
    validate_required_duration_option(idle_timeout, "'Idle timeout' of " + group);
    if (core_common.duration_to_seconds(health_check_interval) > core_common.duration_to_seconds(idle_timeout))
        fail_validation("The check interval of " + group + " is longer than its idle timeout. Increase the idle timeout or shorten the check interval");

    let levels = connections.fallback_levels(group_id);
    if (length(levels) == 0)
        fail_validation("The " + group + " has no server groups. Add at least one server group");

    let level_names = {};
    for (let level_id in levels) {
        let level_name = trim(connections.fallback_level_display_name(group_id, level_id));
        if (level_name == "")
            fail_validation("A server group of " + group + " has no name");
        if (level_names[level_name])
            fail_validation("The " + group + " has more than one server group named '" + level_name + "'");
        level_names[level_name] = true;

        let level = "server group '" + level_name + "' of " + group;
        validate_fallback_level_order(connections.fallback_level_order(group_id, level_id), level);
        let mode = connections.fallback_level_mode(group_id, level_id);
        validate_server_filter_mode(mode, level, true);
        validate_server_filter_regexes(
            mode,
            connections.fallback_level_include_regex(group_id, level_id),
            connections.fallback_level_exclude_regex(group_id, level_id),
            level
        );
        validate_server_filter_types(
            connections.fallback_level_exclude_types(group_id, level_id),
            singbox_constants.FILTERABLE_GROUP_TYPES,
            level
        );
    }
}

// Only a Fallback level may hold a group, and only a URLTest, so references stay one level
// deep and cannot form a cycle.
function validate_section_group_references(section) {
    let urltest_names = {};
    for (let urltest_id in connections.urltests(section)) {
        let display_name = trim(as_string(connections.urltest_display_name(section, urltest_id)));
        if (display_name != "")
            urltest_names[display_name] = true;
    }

    for (let group_id in connections.fallback_groups(section))
        for (let level_id in connections.fallback_levels(group_id))
            for (let value in array_or_empty(connections.fallback_level_include_groups(group_id, level_id))) {
                value = trim(as_string(value));
                if (value != "" && !urltest_names[value])
                    fail_validation("Server group '" + connections.fallback_level_display_name(group_id, level_id) + "' of fallback group '" +
                        connections.fallback_group_display_name(section, group_id) + "' in section '" + section_label(section) +
                        "' includes URLTest '" + value + "', which does not exist");
            }
}

// A DNS section matches a query's name, which carries no address.
function validate_destinations(section, action) {
    for (let value in rule_config.text_list_values(option(section, "destinations", ""), "comma-space")) {
        let parsed = rule_config.destination_kind_value(value);
        if (parsed == null || (parsed.kind == "domain_regex" && regex_problem(parsed.value) != null))
            fail_validation("Invalid condition '" + value + "' in section '" + section_label(section) +
                "'. Use a domain, a full:, keyword: or regex: prefix, an IP address or a subnet");
        if (parsed.kind == "ip_cidr" && action == "dns")
            fail_validation("Section '" + section_label(section) + "' matches DNS queries by domain only, so it cannot use the address '" + value + "'");
    }
}

function validate_service_value(service, section) {
    if (rulesets.is_community(service))
        return;

    fail_validation("Section '" + section_label(section) + "' names an unknown built-in list '" + service + "'");
}

function validate_ruleset_reference_value(reference, section) {
    if (ruleset_reference_valid(reference))
        return;

    fail_validation("Rule set '" + reference + "' in section '" + section_label(section) +
        "' is neither an http(s) URL nor an absolute path, or is a YAML list");
}

function validate_common_rule_references(section) {
    for (let value in connections.community_lists(section))
        validate_service_value(value, section);
    for (let value in connections.rule_sets(section))
        validate_ruleset_reference_value(value, section);
    for (let value in connections.rule_sets_with_subnets(section))
        validate_ruleset_reference_value(value, section);
    let label = replace(section_label(section), /[[:cntrl:]]/g, " ");
    for (let overlap in rulesets.overlaps(connections.community_lists(section),
        [ ...connections.rule_sets(section), ...connections.rule_sets_with_subnets(section) ]))
        core_exec.log("warn", "Section '" + label + "': external list '" + overlap.external + "'" +
            (overlap.relation == "same_source" ? " uses the same source as " : " may overlap ") +
            "built-in '" + overlap.builtin + "'; compare domains and subnets before removing a list");
}

function outbound_json_object(value) {
    try {
        value = json(as_string(value));
    }
    catch (e) {
        return null;
    }

    return type(value) == "object" ? value : null;
}

// sing-box judges a JSON field and logs what it refuses; Forkop needs an object and its tag.
function validate_outbound_json_values(section) {
    let name = section_name(section);
    for (let value in connections.outbound_jsons(section)) {
        if (as_string(value) == "")
            fail_validation("Section '" + section_label(name) + "' has empty JSON outbound");

        let outbound = outbound_json_object(value);
        if (outbound == null)
            fail_validation("Section '" + section_label(name) + "' has a JSON outbound that is not a JSON object");

        if (singbox_constants.removed_vpn_type(outbound.type))
            fail_validation("VPN tunnel and server types are not supported");

        if (trim(as_string(outbound.tag || "")) == "")
            fail_validation("Section '" + section_label(name) + "' has JSON outbound without a non-empty tag");
    }
}

function subscription_update_interval_for_source(subscription) {
    if (!connections.subscription_update_enabled(subscription))
        return "";
    let value = connections.subscription_update_interval(subscription);
    return value != "" ? value : "1h";
}

function validate_subscription_request_profile(section, subscription) {
    let parsed = subscription_headers_module.parse_header_lines(
        connections.subscription_headers(subscription)
    );
    if (!parsed.valid)
        fail_validation("A subscription in section '" + section_label(section) + "' has invalid " + parsed.message);
}

function validate_subscription_override(section, subscription) {
    let settings = connections.subscription_override(subscription);
    let context = "a subscription in section '" + section_label(section) + "'";

    for (let value in array_or_empty(settings.rename)) {
        let rule = connections.parse_rename_rule(value);
        if (rule == null)
            fail_validation("Rename rule '" + trim(as_string(value)) + "' in " + context +
                " must be written as 'pattern => replacement'");
        if (regex_problem(rule.pattern) != null)
            fail_validation("Invalid rename pattern '" + rule.pattern + "' in " + context);
        // A group reference reaches as far as the letters, digits and
        // underscores behind it, so '$1x' asks for a group named '1x' and
        // leaves the name empty. '${1}' ends the number instead, and '$$' is
        // a literal dollar sign that never starts a reference.
        if (match(replace(rule.target, "$$", ""), /[$][0-9]+[A-Za-z_]/) != null)
            fail_validation("Rename replacement '" + rule.target + "' in " + context +
                " must write '${1}' where a letter follows the group number");
    }

    let patch = trim(as_string(settings.patch));
    if (patch == "")
        return;

    let parsed;
    try {
        parsed = json(patch);
    }
    catch (e) {
        fail_validation("Additional parameters in " + context + " are not valid JSON");
    }
    if (type(parsed) != "object")
        fail_validation("Additional parameters in " + context + " must be a JSON object");
    for (let path in array_or_empty(singbox_constants.RESERVED_OVERRIDE_PATCH_PATHS)) {
        let node = parsed;
        for (let segment in split(path, ".")) {
            if (type(node) != "object") {
                node = null;
                break;
            }
            node = node[segment];
        }
        if (node != null)
            fail_validation("Additional parameters in " + context + " must not set '" + path +
                "': the cascade connection of the subscription fills it in");
    }
}

function validate_subscription_filter(section, subscription) {
    let owner = "a subscription in section '" + section_label(section) + "'";
    let mode = option(subscription, "server_filter_mode", "all");
    validate_server_filter_mode(mode, owner, false);
    validate_server_filter_regexes(
        mode,
        option(subscription, "include_regex", ""),
        option(subscription, "exclude_regex", ""),
        owner
    );
    validate_server_filter_types(
        connections.subscription_exclude_types(subscription),
        singbox_constants.FILTERABLE_PROVIDER_TYPES,
        owner
    );
}

function validate_interface_domain_resolvers(section, sections, context) {
    let name = section_name(section);
    for (let interface_name in connections.interfaces(section)) {
        if (!connections.interface_domain_resolver_enabled(section, interface_name))
            continue;

        let label = "The resolver of interface '" + interface_name + "' in section '" + section_label(section) + "'";
        let strategy = connections.interface_domain_resolver_dns_fallback_strategy(section, interface_name);
        if (!contains([ "sequential", "parallel" ], strategy))
            fail_validation(label + " uses unsupported DNS query mode '" + strategy + "'. Use sequential or parallel");

        for (let i, value in connections.interface_domain_resolver_dns_servers(section, interface_name)) {
            let parsed = runtime_dns.parse_server_uri(value, false);
            if (parsed.unsupported)
                fail_validation(label + " has an invalid DNS server #" + (i + 1) + ": " + parsed.unsupported);
        }

        if (!connections.interface_domain_resolver_dns_detour_enabled(section, interface_name))
            continue;

        let target_name = connections.interface_domain_resolver_dns_detour_section(section, interface_name);
        if (target_name == "")
            fail_validation(label + " routes DNS through a section, but no section is selected");
        if (target_name == name)
            fail_validation(label + " cannot send DNS through its own section");

        outbound_section(sections, label, target_name);
    }
}

function validate_dns_action(section, sections, context) {
    let name = section_name(section);
    let fallback_strategy = option(section, "dns_fallback_strategy", "parallel");
    if (!contains([ "sequential", "parallel" ], fallback_strategy))
        fail_validation("Section '" + section_label(name) + "' uses unsupported DNS query mode '" + fallback_strategy + "'. Use sequential or parallel");
    let dns_servers = dns_setting_values(section, "dns_server");
    if (length(dns_servers) == 0)
        fail_validation("Section '" + section_label(name) + "' must contain at least one DNS server");
    for (let i, dns_server in dns_servers) {
        let parsed = runtime_dns.parse_server_uri(dns_server, false);
        if (parsed.unsupported)
            fail_validation("Section '" + section_label(name) + "' has an invalid DNS server #" + (i + 1) + ": " + parsed.unsupported);
    }
    if (length(connections.rule_sets_with_subnets(section)) > 0)
        fail_validation("Section '" + section_label(name) + "' can use domain-only rule sets, but subnet extraction is enabled. Disable 'Include IP addresses and subnets'");
    if (!connections.has_dns_matchers(section) && length(list_option(section, "fully_routed_ips")) == 0)
        fail_validation("DNS section '" + section_label(name) + "' needs a domain, a built-in list, a rule set or a device");
    if (!bool_option(section, "dns_detour_enabled", false))
        return;

    let target_name = option(section, "dns_detour_section", "");
    if (target_name == "")
        fail_validation("Section '" + section_label(name) + "' routes DNS through a section, but no section is selected");
    if (target_name == name)
        fail_validation("Section '" + section_label(name) + "' cannot send DNS through itself");

    outbound_section(sections, "Section '" + section_label(name) + "'", target_name);
}

function validate_rule(section, sections, context) {
    if (!section_enabled(section))
        return;

    let name = section_name(section);
    let action = rule_action(section);
    if (action == "")
        fail_validation("Section '" + section_label(name) + "' has no action");
    if (!rule_action_supported(action))
        fail_validation("Section '" + section_label(name) + "' uses unsupported action '" + action + "'");

    if (action != "dns")
        for (let value in list_option(section, "ports"))
            validate_port_condition_value(value, name);
    validate_destinations(section, action);

    if (action == "dns")
        validate_dns_action(section, sections, context);

    if (connections.is_connections_action(action)) {
        for (let urltest_id in connections.urltests(section)) {
            let urltest = "URLTest '" + connections.urltest_display_name(section, urltest_id) + "' in section '" + section_label(section) + "'";
            let check_interval = connections.urltest_check_interval(section, urltest_id);
            validate_required_duration_option(check_interval, "'Check interval' of " + urltest);
            validate_urltest_tolerance_value(connections.urltest_tolerance(section, urltest_id), urltest);
            validate_http_url_option(connections.urltest_testing_url(section, urltest_id), "'Check URL' of " + urltest);
            if (!expected_status_valid(connections.urltest_expected_status(section, urltest_id)))
                fail_validation("Invalid 'Expected status' of " + urltest + ". Use *, status codes, or ranges such as 204/200-299");
            let idle_timeout = connections.urltest_idle_timeout(section, urltest_id);
            if (idle_timeout != "")
                validate_required_duration_option(idle_timeout, "'Idle timeout' of " + urltest);
            let effective_idle_timeout = idle_timeout != ""
                ? idle_timeout
                : as_string(singbox_constants.URLTEST_DEFAULT_IDLE_TIMEOUT || "30m");
            if (core_common.duration_to_seconds(check_interval) > core_common.duration_to_seconds(effective_idle_timeout))
                fail_validation("The check interval of " + urltest + " is longer than its idle timeout. Increase the idle timeout or shorten the check interval");

            let filter_mode = connections.urltest_filter_mode(section, urltest_id);
            validate_server_filter_mode(filter_mode, urltest, false);
            validate_server_filter_regexes(
                filter_mode,
                connections.urltest_include_regex(section, urltest_id),
                connections.urltest_exclude_regex(section, urltest_id),
                urltest
            );
            validate_server_filter_types(
                connections.urltest_exclude_types(section, urltest_id),
                singbox_constants.FILTERABLE_GROUP_TYPES,
                urltest
            );
        }

        for (let group_id in connections.fallback_groups(section))
            validate_fallback_group(section, group_id);

        validate_connection_links(section);
        for (let subscription in connections.subscription_items(section)) {
            validate_subscription_source_entry_value(connections.subscription_source(subscription), name);
            validate_subscription_request_profile(section, subscription);
            validate_subscription_filter(section, subscription);
            validate_subscription_override(section, subscription);
            let subscription_update_interval = subscription_update_interval_for_source(subscription);
            if (subscription_update_interval != "")
                validate_required_duration_option(subscription_update_interval, "'Update interval' of a subscription in section '" + section_label(section) + "'");
        }

        validate_section_group_references(section);
        validate_outbound_json_values(section);
        validate_section_child_names(section);
        validate_interface_domain_resolvers(section, sections, context);
    }

    validate_common_rule_references(section);
    if (connections.is_connections_action(action) && !connections.has_connection_sources(section))
        core_exec.log("warn", "Section '" + section_label(section) + "' has no servers and is skipped");
}

function validate_subscription_download_sections(sections, context) {
    for (let section in sections) {
        section = object_or_empty(section);
        if (!section_enabled(section))
            continue;

        let name = section_name(section);
        for (let subscription in connections.subscription_items(section)) {
            let target = connections.subscription_download_section(subscription);
            if (target == "")
                continue;

            if (target == name)
                fail_validation("A subscription in section '" + section_label(section) + "' is downloaded through its own section. Select another section or download it directly");

            validate_download_section(sections, target);
        }
    }
}


function validate_native_rule_set_update_settings(settings) {
    if (!bool_option(settings, "list_update_enabled", true))
        return;

    let update_interval = option(settings, "update_interval", "1d");
    if (update_interval == "")
        update_interval = "1d";
    validate_required_duration_option(update_interval, "'List update interval' in Settings");
}

function validate_runtime_mark_ranges_context(context) {
    let fakeip_mark = parse_number(context.nft_fakeip_mark);
    let outbound_mark = parse_number(context.nft_outbound_mark);
    let router_mark = parse_number(context.nft_router_mark);

    if (fakeip_mark == null || outbound_mark == null || router_mark == null)
        fail_validation("Forkop marks contain invalid numeric constants");
    if ((fakeip_mark & TAILSCALE_FWMARK_MASK) != 0)
        fail_validation("FakeIP mark overlaps Tailscale fwmark mask 0x00ff0000");
    if ((outbound_mark & TAILSCALE_FWMARK_MASK) != 0)
        fail_validation("Outbound mark overlaps Tailscale fwmark mask 0x00ff0000");
    if ((router_mark & TAILSCALE_FWMARK_MASK) != 0)
        fail_validation("Router mark overlaps Tailscale fwmark mask 0x00ff0000");
    if (fakeip_mark == outbound_mark)
        fail_validation("FakeIP mark and outbound mark are the same value");
    if ((router_mark & (fakeip_mark | outbound_mark)) != 0)
        fail_validation("Router mark shares bits with the FakeIP or outbound mark");
}

function refuse_without(feature, core_tags, what) {
    let reason = features.unavailable_reason(feature, core_tags);
    if (reason != "")
        fail_validation(what + ", but " + reason + ". Disable it or install a sing-box build that has it");
}

// The core refuses to start on a link or DNS server of a type it was built
// without; a subscription's servers it skips and logs instead.
function validate_core_features(settings, sections, core_tags) {
    for (let section in sections) {
        if (!section_enabled(section) || !connections.is_connections_action(rule_action(section)))
            continue;
        for (let item in connections.connection_link_items(section)) {
            let link = connections.option(item, "uri", "");
            let label = core_url.scheme(link) + ":// link '" + connections.option(item, "name", "") + "'";
            for (let feature in features.link_features(link))
                refuse_without(feature, core_tags, "Section '" + section_label(section) + "' has a " + label +
                    (feature == "utls" ? " that uses Reality or a TLS fingerprint"
                        : feature == "quic" && features.link_uses_xhttp_http3(link) ? " that uses XHTTP over HTTP/3" : ""));
        }
    }

    let dns_servers = [ ...dns_setting_values(settings, "dns_server"), ...dns_setting_values(settings, "bootstrap_dns_server") ];
    for (let section in sections) {
        if (!section_enabled(section))
            continue;
        if (rule_action(section) == "dns")
            push(dns_servers, ...dns_setting_values(section, "dns_server"));
        if (!connections.is_connections_action(rule_action(section)))
            continue;
        for (let interface_name in connections.interfaces(section))
            if (connections.interface_domain_resolver_enabled(section, interface_name))
                push(dns_servers, ...connections.interface_domain_resolver_dns_servers(section, interface_name));
    }
    for (let value in dns_servers) {
        let parsed = runtime_dns.parse_server_uri(value, false);
        if (parsed.type == "quic" || parsed.type == "h3")
            refuse_without("quic", core_tags, "A configured DNS server uses " + (parsed.type == "quic" ? "DNS over QUIC" : "DNS over HTTP/3"));
    }

}

function validate_runtime_config(context) {
    let settings = settings_section();
    let sections = sections_by_type("section");

    let display_names = {};
    validate_runtime_display_names(sections, "Section", display_names);
    if (context.core_tags != null)
        validate_core_features(settings, sections, context.core_tags);
    validate_runtime_mark_ranges_context(context);
    validate_dns_settings(settings, sections, context);
    validate_native_rule_set_update_settings(settings);
    validate_http_url_option(option(settings, "latency_test_url", DEFAULT_LATENCY_TEST_URL) || DEFAULT_LATENCY_TEST_URL, "'Latency test URL' in Settings");

    for (let purpose in [ "lists" ])
        if (connections.download_via_proxy_enabled(settings, purpose))
            validate_download_section(sections, connections.download_via_proxy_section(settings, purpose));

    validate_cascades(sections);
    validate_subscription_download_sections(sections, context);

    for (let section in sections) {
        validate_subscription_tags(section);
        validate_rule(section, sections, context);
    }
}

function context_from_runtime() {
    return {
        nft_fakeip_mark: as_string(constants.NFT_FAKEIP_MARK),
        nft_outbound_mark: as_string(constants.NFT_OUTBOUND_MARK),
        nft_router_mark: as_string(constants.NFT_ROUTER_MARK),
        sing_box_required_version: as_string(constants.SB_REQUIRED_VERSION),
        // Unknown without a core to ask, which the requirement check refuses first.
        core_tags: features.tags()
    };
}

function service_exists(service) {
    return file_executable("/etc/init.d/" + as_string(service));
}

// Without an enabled Connection section nothing was meant to be proxied, as on a VPN server alone.
function connection_sections_proxy_nothing() {
    let wanted = false;
    for (let section in sections_by_type("section")) {
        if (!section_enabled(section) || !connections.is_connections_action(rule_action(section)))
            continue;
        if (connections.has_connection_sources(section))
            return false;
        wanted = true;
    }
    return wanted;
}

// Whether the installed system can run Forkop at all. Throws with the reason.
function check_requirements() {
    let ctx = context_from_runtime();

    // Without IPv6 in the kernel no IPv6 socket opens, the TProxy inbound on ::1 among them.
    if (nft_state.ipv6_interfaces() == null)
        die("The kernel runs without IPv6 (ipv6.disable=1 on its command line, or built without it), and sing-box needs it even with IPv6 off. " +
            "Boot without ipv6.disable=1 and turn IPv6 off with sysctl net.ipv6.conf.all.disable_ipv6=1 instead");

    if (!command_exists("sing-box"))
        die("Binary 'sing-box' is not available. Reinstall sing-box-forkop");
    // what the binary reports: a package's version file outlives a binary copied over it
    let binary_version = features.version();
    if (binary_version == "")
        die("Failed to read the version sing-box reports. Reinstall sing-box-forkop");
    if (packages.forkop_core_version(binary_version) == "")
        die("sing-box " + binary_version + " is not sing-box-forkop, the core Forkop runs on. Install sing-box-forkop");
    if (!core_version.version_at_least(binary_version, ctx.sing_box_required_version))
        die("sing-box-forkop " + binary_version + " is older than the required minimum (" + ctx.sing_box_required_version + "). Update sing-box-forkop");

    let problem = features.core_problem(ctx.core_tags);
    if (problem != "")
        die(problem);

    if (!service_exists("sing-box"))
        die("Service 'sing-box' is missing. Reinstall sing-box-forkop");

    if (dhcp_has_https_dns_proxy_options("/etc/config/dhcp") === true)
        core_exec.log("warn", "https-dns-proxy is configured in /etc/config/dhcp, and Forkop conflicts with it. Remove https-dns-proxy or its settings in /etc/config/dhcp");

    connections.load();
    if (connection_sections_proxy_nothing())
        core_exec.log("warn", "No enabled Connection section has servers, so no traffic is proxied");
}

// Throws the reason when sing-box could not run the configuration. overrides replace values
// of the runtime context.
function validate(overrides) {
    connections.load();
    validate_runtime_config({ ...context_from_runtime(), ...object_or_empty(overrides) });
}

return { validate, check_requirements, connection_sections_proxy_nothing };
