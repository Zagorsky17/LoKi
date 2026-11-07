let fs = require("fs");
let process = require("core.process");
let netstat = require("core.netstat");
let nft_state = require("nft.state");
let runtime_constants = require("singbox.constants");

let paths = {
    proc: "/proc",
    tcp: "/proc/net/tcp",
    tcp6: "/proc/net/tcp6",
    udp6: "/proc/net/udp6"
};

function as_string(value) {
    return value == null ? "" : "" + value;
}

function shell_quote(value) {
    return "'" + replace(as_string(value), /'/g, "'\\''") + "'";
}

function command_from_args(args) {
    let parts = [];
    for (let arg in args)
        push(parts, shell_quote(arg));
    return join(" ", parts);
}

function command_output_from_args(args) {
    let pipe = fs.popen(command_from_args(args), "r");
    if (!pipe)
        return "";

    let data = pipe.read("all");
    let status = pipe.close();
    return status == 0 && data != null ? as_string(data) : "";
}

function sing_box_service_pid_from_value(value) {
    let service = type(value) == "object" ? value["loki-core"] : null;
    let instances = service && type(service.instances) == "object" ? service.instances : {};
    for (let _, instance in instances)
        if (type(instance) == "object" && instance.running === true && int(instance.pid || 0) > 0)
            return int(instance.pid);
    return 0;
}

// One ubus connection, reused for every question of the process.
let ubus_connection = null;
let ubus_connection_tried = false;

function ubus_connect() {
    if (ubus_connection_tried)
        return ubus_connection;

    ubus_connection_tried = true;
    try {
        ubus_connection = require("ubus").connect();
    }
    catch (e) {
        ubus_connection = null;
    }
    return ubus_connection;
}

// procd's entry for the loki-core service: {} when it holds none, null when it did not answer.
function sing_box_service_list(verbose) {
    let connection = ubus_connect();
    let parameters = { name: "loki-core" };
    if (verbose) parameters.verbose = true;
    try {
        return connection == null
            ? json(command_output_from_args([ "ubus", "call", "service", "list",
                verbose ? sprintf("%J", parameters) : "{\"name\":\"loki-core\"}" ]))
            : connection.call("service", "list", parameters);
    }
    catch (e) {
        return null;
    }
}

function sing_box_service_pid_runtime() {
    return sing_box_service_pid_from_value(sing_box_service_list());
}

// Running or not; a service procd gave no answer about counts as held.
function sing_box_service_registered() {
    let value = sing_box_service_list();
    return type(value) != "object" || value["loki-core"] != null;
}

function path_basename(path) {
    path = as_string(path);
    let slash = rindex(path, "/");
    return slash >= 0 ? substr(path, slash + 1) : path;
}

function pid_is_sing_box(pid) {
    pid = as_string(pid);
    if (match(pid, /^[0-9]+$/) == null)
        return false;
    try {
        return path_basename(fs.readlink("/proc/" + pid + "/exe")) == "loki-core";
    }
    catch (e) {
        return false;
    }
}

function process_start_ticks(stat) {
    let fields = process.stat_fields(as_string(stat));
    return fields == null ? null : int(fields[19]);
}

// When the process started, in ticks since boot, or null once it is gone.
function start_ticks(pid) {
    return process.start_ticks(pid);
}

// Processor ticks and anonymous memory: the resident total also counts the binary's pages, a
// file cache the kernel drops, which for loki-core is over half of it.
function process_usage(pid) {
    let dir = paths.proc + "/" + pid;
    let fields = process.stat_fields(fs.readfile(dir + "/stat"));
    let anon = match(fs.readfile(dir + "/status") ?? "", /(^|\n)RssAnon:[ \t]*([0-9]+) kB/);
    if (fields == null || anon == null)
        return null;
    return { started: int(fields[19]), cpu_ticks: int(fields[11]) + int(fields[12]), memory_kb: int(anon[2]) };
}

function cpu_count() {
    let count = 0;
    for (let line in split(fs.readfile(paths.proc + "/stat") ?? "", "\n"))
        if (match(line, /^cpu[0-9]+ /))
            count++;
    return count || 1;
}

// Read on the monotonic clock, the scale the kernel stamps a process start on, so the load is
// timed by the router and the same reading gives the core's age.
function sing_box_usage() {
    let pid = sing_box_service_pid_runtime();
    let usage = pid > 0 && pid_is_sing_box(pid) ? process_usage(pid) : null;
    if (usage == null)
        return { running: false };
    let now = clock(true);
    return { running: true, ...usage, cpus: cpu_count(), clock_ms: now[0] * 1000 + int(now[1] / 1000000) };
}

function process_age_seconds_from_ticks(start_ticks, current_ticks) {
    start_ticks = as_string(start_ticks);
    current_ticks = as_string(current_ticks);
    if (match(start_ticks, /^[0-9]+$/) == null || match(current_ticks, /^[0-9]+$/) == null)
        return null;

    start_ticks = int(start_ticks);
    current_ticks = int(current_ticks);
    return current_ticks < start_ticks ? null : int((current_ticks - start_ticks) / 100);
}

// Timed against a fresh child's start time, on the same scale as the target's: lxcfs
// virtualizes /proc/uptime in containers but not that field.
function process_age_seconds(pid, expected_start_ticks) {
    pid = as_string(pid);
    if (match(pid, /^[0-9]+$/) == null)
        return null;

    let start_ticks = process_start_ticks(fs.readfile("/proc/" + pid + "/stat"));
    if (start_ticks == null ||
        (expected_start_ticks != null && start_ticks != int(expected_start_ticks)))
        return null;

    let current_ticks = process_start_ticks(command_output_from_args([ "cat", "/proc/self/stat" ]));
    return process_age_seconds_from_ticks(start_ticks, current_ticks);
}

function sing_box_service_running() {
    let pid = sing_box_service_pid_runtime();
    return pid > 0 && pid_is_sing_box(pid);
}

function sing_box_service_stable(min_age) {
    min_age = int(min_age || 2);
    let pid = sing_box_service_pid_runtime();
    if (pid <= 0 || !pid_is_sing_box(pid))
        return false;

    let age = process_age_seconds(pid);
    return age != null && age >= min_age;
}

function sing_box_runtime_ports_ready() {
    let tcp6 = fs.readfile(paths.tcp6);
    let dns_address = [ runtime_constants.SOURCE_DNS_INBOUND_ADDRESS ];
    let dns_port = as_string(runtime_constants.SOURCE_DNS_INBOUND_PORT);
    return netstat.sing_box_standard_ports_listening_proc(
        fs.readfile(paths.tcp),
        tcp6,
        runtime_constants.DNS_INBOUND_ADDRESS,
        "" + runtime_constants.TPROXY_INBOUND_PORT,
        runtime_constants.TPROXY_INBOUND6_ADDRESS
    ) && netstat.proc_socket_listening(tcp6, dns_address, dns_port) &&
        netstat.proc_socket_listening(fs.readfile(paths.udp6), dns_address, dns_port, "07");
}

function loki_runtime_network_configured(rt_table, nft_table, mark) {
    return nft_state.runtime_network_configured(nft_table, rt_table, mark);
}

function loki_running(rt_table, nft_table, mark) {
    return sing_box_service_running() && sing_box_runtime_ports_ready() &&
        loki_runtime_network_configured(rt_table, nft_table, mark);
}

function loki_stably_running(rt_table, nft_table, mark, min_age) {
    return sing_box_service_stable(min_age) && sing_box_runtime_ports_ready() &&
        loki_runtime_network_configured(rt_table, nft_table, mark);
}

// Shared by the LuCI state feed and the diagnostics status command.
function service_status_text(running, enabled) {
    running = running === true || running == "true" || running == "1" || running == 1;
    enabled = enabled === true || enabled == "true" || enabled == "1" || enabled == 1;

    if (running)
        return enabled ? "running & enabled" : "running but disabled";
    return enabled ? "stopped but enabled" : "stopped & disabled";
}

return {
    paths,
    service_status_text,
    sing_box_service_pid_from_value,
    sing_box_service_list,
    sing_box_service_pid_runtime,
    sing_box_service_registered,
    pid_is_sing_box,
    start_ticks,
    process_usage,
    sing_box_usage,
    process_age_seconds,
    process_age_seconds_from_ticks,
    sing_box_service_running,
    sing_box_service_stable,
    sing_box_runtime_ports_ready,
    loki_runtime_network_configured,
    loki_running,
    loki_stably_running
};
