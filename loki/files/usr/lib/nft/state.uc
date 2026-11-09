let fs = require("fs");
let exec = require("core.exec");
let common = require("core.common");
let constants = require("core.constants");

// iproute2, which the dependency puts at /sbin/ip: BusyBox ip mishandles Loki's table entries
const IP_BIN = "/sbin/ip";
const PAUSE_CHAIN = constants.NFT_PAUSE_CHAIN_NAME;
// Before the TProxy rules at 105.
const SOURCE_CHECK_PRIORITY = "104";

let paths = {
    ipv6_conf: "/proc/sys/net/ipv6/conf"
};

let as_string = common.as_string;
let parse_mark_number = common.parse_number;

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

// IPv6-disabled snapshots can end with a failed -6 query; retain bounded partial stdout.
function command_output(command) {
    return exec.capture([ "/bin/sh", "-c", as_string(command) ], 1048576).stdout;
}

function command_output_from_args(args) {
    let result = exec.capture(args, 1048576);
    return result.status == 0 ? result.stdout : "";
}

function command_success_from_args(args) {
    return system(command_from_args(args) + " >/dev/null 2>&1") == 0;
}

// -t leaves out the set elements, which on a real rule set are seconds of output.
function table_present(table) {
    return command_success_from_args([ "nft", "-t", "list", "table", "inet", as_string(table) ]);
}

function normalized_fields(line) {
    line = trim(replace(as_string(line), /\r/g, ""));
    line = replace(line, /[[:space:]]+/g, " ");
    return line == "" ? [] : split(line, " ");
}

function rule_line_has_fwmark(fields, expected_mark) {
    for (let i = 0; i + 1 < length(fields); i++) {
        if (fields[i] != "fwmark")
            continue;

        let parts = split(fields[i + 1], "/");
        if (length(parts) == 2 && parse_mark_number(parts[0]) == expected_mark &&
            parse_mark_number(parts[1]) == expected_mark)
            return true;
    }
    return false;
}

// Asking for one table's rules proves the table: another package may own the name iproute2
// prints for that id, e.g. `105 podkop` in /etc/iproute2/rt_tables.
function has_tproxy_marking_rule_text(rule_list, mark) {
    let expected_mark = parse_mark_number(mark);
    if (expected_mark == null)
        return false;

    for (let line in split(as_string(rule_list), "\n")) {
        let fields = normalized_fields(line);
        if (length(fields) > 0 && rule_line_has_fwmark(fields, expected_mark))
            return true;
    }
    return false;
}

// The devices of the rules nft/apply.uc keeps at the priority, as iproute2 lists them:
// "106: from all fwmark 0x8000000/0x8000000 oif eth1 [detached] lookup main".
function bound_rule_devices_text(rule_list, priority, mark) {
    let expected_mark = parse_mark_number(mark);
    let devices = [];
    for (let line in split(as_string(rule_list), "\n")) {
        let fields = normalized_fields(line);
        let count = length(fields);
        let oif = index(fields, "oif");
        if (count > 0 && fields[0] == priority + ":" && oif > 0 && oif + 1 < count && rule_line_has_fwmark(fields, expected_mark) &&
            fields[count - 2] == "lookup" && fields[count - 1] == "main")
            push(devices, fields[oif + 1]);
    }
    return devices;
}

function bound_rule_devices(family, priority, mark) {
    return bound_rule_devices_text(command_output_from_args([ IP_BIN, family, "rule", "list", "priority", priority ]), priority, mark);
}

// "104: from all fwmark 0x4000000/0x4000000 iif lo lookup main", as iproute2 lists it
function source_check_rule_text(rule_list, mark) {
    let expected_mark = parse_mark_number(mark);
    for (let line in split(as_string(rule_list), "\n")) {
        let fields = normalized_fields(line);
        let count = length(fields);
        let iif = index(fields, "iif");
        if (count > 0 && fields[0] == SOURCE_CHECK_PRIORITY + ":" && iif > 0 && fields[iif + 1] == "lo" &&
            rule_line_has_fwmark(fields, expected_mark) && fields[count - 2] == "lookup" && fields[count - 1] == "main")
            return true;
    }
    return false;
}

function source_check_rule4_present(mark) {
    return source_check_rule_text(command_output_from_args([ IP_BIN, "-4", "rule", "list", "priority", SOURCE_CHECK_PRIORITY ]), mark);
}

function has_local_default_route_text(route_list, family) {
    family = int(family || 4);
    for (let line in split(as_string(route_list), "\n")) {
        line = replace(trim(replace(as_string(line), /\r/g, "")), /[[:space:]]+/g, " ");
        if (family == 4 && index(line, "local default dev lo scope host") >= 0)
            return true;
        if (family == 6 && (index(line, "local ::") >= 0 || index(line, "local default") >= 0) &&
            index(line, " dev lo") >= 0)
            return true;
    }
    return false;
}

function rt_table_has_entry(text, table_id, table_name) {
    table_id = as_string(table_id);
    table_name = as_string(table_name);
    for (let line in split(as_string(text), "\n")) {
        let fields = normalized_fields(line);
        if (length(fields) >= 2 && fields[0] == table_id && fields[1] == table_name)
            return true;
    }
    return false;
}

// The interfaces IPv6 is enabled on, lo among them; null for a kernel booted with
// ipv6.disable=1 or built without IPv6, which has no such directory.
function ipv6_interfaces() {
    let names = fs.lsdir(paths.ipv6_conf);
    if (names == null)
        return null;
    return sort(filter(names, (name) => name != "all" && name != "default" &&
        trim(fs.readfile(paths.ipv6_conf + "/" + name + "/disable_ipv6") ?? "") == "0"));
}

function ipv6_enabled() {
    return length(ipv6_interfaces() ?? []) > 0;
}

function tproxy_route4_present(table) {
    return has_local_default_route_text(command_output_from_args([ IP_BIN, "route", "list", "table", table ]), 4);
}

function tproxy_route6_present(table) {
    return has_local_default_route_text(command_output_from_args([ IP_BIN, "-6", "route", "list", "table", table ]), 6);
}

function tproxy_marking_rule4_present(table, mark) {
    return has_tproxy_marking_rule_text(
        command_output_from_args([ IP_BIN, "-4", "rule", "list", "table", table ]), mark);
}

function tproxy_marking_rule6_present(table, mark) {
    return has_tproxy_marking_rule_text(
        command_output_from_args([ IP_BIN, "-6", "rule", "list", "table", table ]), mark);
}

// One shell collects every list the status needs. Route and rule output share a stream: a
// route line never carries fwmark, and a rule line never carries `local default dev lo`.
const IP_BATCH_COMMANDS = "route list table %s
rule list table %s
";

function batch_pipeline(family, table) {
    return "printf %s " + shell_quote(sprintf(IP_BATCH_COMMANDS, table, table)) +
        " | " + shell_quote(IP_BIN) + " " + family + " -batch - 2>/dev/null";
}

function pause_chain_command(table) {
    let chain = [ "list", "chain", "inet", as_string(table), PAUSE_CHAIN ];
    return command_from_args([ "nft", "-j", ...chain ]) + " 2>/dev/null || " + command_from_args([ "nft", ...chain ]) + " 2>/dev/null";
}

const SNAPSHOT_SEPARATOR = "@@loki-runtime-snapshot@@";

function runtime_snapshot_command(rt_table, nft_table) {
    return pause_chain_command(nft_table) +
        "; echo " + shell_quote(SNAPSHOT_SEPARATOR) +
        "; " + batch_pipeline("-4", rt_table) +
        "; echo " + shell_quote(SNAPSHOT_SEPARATOR) +
        "; " + batch_pipeline("-6", rt_table);
}

function split_snapshot(output) {
    let parts = split(as_string(output), SNAPSHOT_SEPARATOR);
    return {
        tables: length(parts) > 0 ? parts[0] : "",
        inet4: length(parts) > 1 ? parts[1] : "",
        inet6: length(parts) > 2 ? parts[2] : ""
    };
}

// The table captures while its pause chain is empty; nft built without JSON prints text.
function capture_active_output(output, table) {
    let lines = filter(map(split(as_string(output), "\n"), (line) => join(" ", normalized_fields(line))), (line) => line != "");
    if (length(lines) > 0 && lines[0] == "table inet " + table + " {")
        return index(lines, "chain " + PAUSE_CHAIN + " {") == 1 &&
            length(filter(lines, (line) => line != "}")) == 2;

    try {
        let chain = false, rules = 0;
        for (let entry in json(output)?.nftables || []) {
            let item = entry.chain ?? entry.rule;
            if (item?.family != "inet" || item.table != table)
                continue;
            if (entry.chain != null && item.name == PAUSE_CHAIN)
                chain = true;
            if (entry.rule != null && item.chain == PAUSE_CHAIN)
                rules++;
        }
        return chain && rules == 0;
    }
    catch (e) {
    }
    return false;
}

// IPv6 routing is part of the runtime unless ipv6_enabled is false.
function runtime_network_configured_snapshot(snapshot, nft_table, mark) {
    snapshot = type(snapshot) == "object" ? snapshot : {};

    return capture_active_output(snapshot.tables, nft_table) &&
        has_local_default_route_text(snapshot.inet4, 4) &&
        has_tproxy_marking_rule_text(snapshot.inet4, mark) &&
        (snapshot.ipv6_enabled === false ||
            has_local_default_route_text(snapshot.inet6, 6) && has_tproxy_marking_rule_text(snapshot.inet6, mark));
}

function runtime_network_configured(nft_table, rt_table, mark) {
    return runtime_network_configured_snapshot(
        { ...split_snapshot(command_output(runtime_snapshot_command(rt_table, nft_table))), ipv6_enabled: ipv6_enabled() },
        nft_table,
        mark
    );
}

return {
    IP_BIN,
    paths,
    ipv6_interfaces,
    ipv6_enabled,
    table_present,
    runtime_network_configured_snapshot,
    runtime_network_configured,
    rt_table_has_entry,
    bound_rule_devices,
    SOURCE_CHECK_PRIORITY,
    source_check_rule4_present,
    tproxy_route4_present,
    tproxy_route6_present,
    tproxy_marking_rule4_present,
    tproxy_marking_rule6_present,
};
