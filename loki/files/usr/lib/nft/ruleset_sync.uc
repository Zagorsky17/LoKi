// Modified for LoKi on 2026-11-03: protect and verify temporary nft transactions before applying them.
// Fills the sets of provider-fed sections, one nft transaction per section, so nft never
// holds more than the largest one.

let fs = require("fs");
let common = require("core.common");
let exec = require("core.exec");
let constants = require("core.constants");
let core_ip = require("core.ip");
let library = require("core.library");
let worker_process = require("service.worker");
let context = require("service.ruleset_context");
let runtime = require("singbox.runtime");
let health = require("service.health");
let lock = require("service.lock");
let clash_api = require("singbox.clash_api");
let nft_apply = require("nft.apply");
let connections = require("config.connections");

const TABLE = constants.NFT_TABLE_NAME;
const MAX_ELEMENTS_PER_LINE = 256;
const MAX_LINE_LENGTH = 8192;
const EVENT_WAIT_SECONDS = 60;
const RETRY_MIN_SECONDS = 3;
const RETRY_MAX_SECONDS = 300;

let as_string = common.as_string;

// Per section: the key its sets were last filled from and the key that was refused; a
// refused key is not tried again until a provider or the section changes.
let applied = {};
let refused = {};
let paths = { lock: "/var/run/loki/start.lock", planned_stop: "/var/run/loki/loki-core-watch.planned-stop" };

function normalize_ranges(ranges) {
    sort(ranges, (left, right) => left.start == right.start ? left.end - right.end : left.start - right.start);

    let result = [];
    for (let current in ranges) {
        let last = length(result) > 0 ? result[length(result) - 1] : null;
        if (last != null && current.start <= last.end + 1) {
            if (current.end > last.end)
                last.end = current.end;
            continue;
        }
        push(result, { start: current.start, end: current.end });
    }
    return result;
}

function section_ranges(csv) {
    let ranges = [];
    for (let value in split(as_string(csv), ",")) {
        let matched = match(value, /^([0-9]+)(-([0-9]+))?$/);
        if (matched != null)
            push(ranges, { start: int(matched[1]), end: int(matched[3] ?? matched[1]) });
    }
    return normalize_ranges(ranges);
}

function snapshot_ranges(values, label) {
    if (type(values) != "array")
        die(label + ": port_ranges must be an array");
    for (let value in values)
        if (type(value) != "object" || type(value.start) != "int" || type(value.end) != "int" ||
            value.start < 1 || value.end > 65535 || value.start > value.end)
            die(label + ": invalid port range");
    return normalize_ranges(map(values, (value) => ({ start: value.start, end: value.end })));
}

// The only transports the core exports and nft can match.
function snapshot_protocols(values, label) {
    if (values == null)
        return [];
    if (type(values) != "array")
        die(label + ": networks must be an array");
    for (let value in values)
        if (value != "tcp" && value != "udp")
            die(label + ": unsupported network " + as_string(value));
    return uniq(values);
}

function intersect_ranges(first, second) {
    let result = [];
    for (let left in first)
        for (let right in second) {
            let start = max(left.start, right.start);
            let end = min(left.end, right.end);
            if (start <= end)
                push(result, { start, end });
        }
    return normalize_ranges(result);
}

function port_text(range) {
    return range.start == range.end ? "" + range.start : range.start + "-" + range.end;
}

// A provider prefix goes into the transaction unquoted.
function prefix_is_nft_safe(prefix, family) {
    return type(prefix) == "string" && (family == 4
        ? index(prefix, ".") >= 0 && match(prefix, /[^0-9.\/]/) == null
        : index(prefix, ":") >= 0 && match(prefix, /[^0-9A-Fa-f:.\/]/) == null);
}

function compare_addresses(left, right) {
    for (let i = 0; i < length(left); i++)
        if (left[i] != right[i])
            return left[i] - right[i];
    return 0;
}

function step_address(address, delta) {
    let result = [ ...address ];
    for (let i = length(result) - 1; i >= 0; i--) {
        let value = result[i] + delta;
        if (value >= 0 && value <= 255) {
            result[i] = value;
            return result;
        }
        result[i] = delta > 0 ? 0 : 255;
    }
    return null;
}

function block_bounds(address, bits) {
    let low = [], high = [];
    for (let i = 0; i < length(address); i++) {
        let kept = min(max(bits - i * 8, 0), 8);
        let mask = (0xff << (8 - kept)) & 0xff;
        push(low, address[i] & mask);
        push(high, (address[i] & mask) | (~mask & 0xff));
    }
    return { low, high };
}

function prefix_bounds(prefix, family, label) {
    let parts = split(as_string(prefix), "/");
    let address = length(parts) <= 2 ? iptoarr(parts[0]) : null;
    let bits = length(parts) == 2 && match(parts[1], /^[0-9]+$/) ? int(parts[1]) : length(parts) == 1 ? 128 : -1;
    if (address == null || length(address) != (family == 4 ? 4 : 16) || bits < 0 || bits > 128 ||
        (length(parts) == 2 && bits > length(address) * 8))
        die(label + ": invalid IP prefix " + as_string(prefix));
    return block_bounds(address, min(bits, length(address) * 8));
}

function segment_text(low, high) {
    if (compare_addresses(low, high) == 0)
        return arrtoip(low);
    for (let bits = length(low) * 8 - 1; bits >= 0; bits--) {
        let block = block_bounds(low, bits);
        if (compare_addresses(block.low, low) != 0)
            break;
        if (compare_addresses(block.high, high) == 0)
            return arrtoip(low) + "/" + bits;
    }
    return arrtoip(low) + "-" + arrtoip(high);
}

// The kernel refuses overlapping address.port intervals in one set, so the boxes are swept
// into disjoint address segments carrying the union of their port ranges.
function disjoint(boxes) {
    let events = [];
    for (let box in boxes) {
        push(events, { at: box.low, box, open: true });
        let after = step_address(box.high, 1);
        if (after != null)
            push(events, { at: after, box, open: false });
    }
    sort(events, (left, right) => compare_addresses(left.at, right.at));

    let segments = [];
    let active = [];
    for (let i = 0; i < length(events);) {
        let at = events[i].at;
        for (; i < length(events) && compare_addresses(events[i].at, at) == 0; i++) {
            let event = events[i];
            active = event.open ? [ ...active, event.box ] : filter(active, (box) => box != event.box);
        }
        if (length(active) == 0)
            continue;

        let ranges = {};
        for (let box in active)
            ranges[box.key] = [ ...(ranges[box.key] ?? []), ...box.ranges ];
        let groups = map(sort(keys(ranges)), (key) => [ key, normalize_ranges(ranges[key]) ]);
        let signature = sprintf("%J", groups);
        let high = i < length(events) ? step_address(events[i].at, -1) : map(at, () => 255);

        let last = length(segments) > 0 ? segments[length(segments) - 1] : null;
        if (last != null && last.signature == signature && compare_addresses(step_address(last.high, 1) ?? [], at) == 0)
            last.high = high;
        else
            push(segments, { low: at, high, signature, groups });
    }

    let elements = [];
    for (let segment in segments) {
        let address = segment_text(segment.low, segment.high);
        for (let group in segment.groups)
            for (let range in group[1])
                push(elements, address + (group[0] == "" ? "" : " . " + group[0]) + " . " + port_text(range));
    }
    return { elements, count: length(segments) };
}

function add_groups(boxes, groups, family, ports, label) {
    if (type(groups) != "array")
        die(label + " must be an array");

    for (let i = 0; i < length(groups); i++) {
        let group = groups[i];
        let where = label + "[" + i + "]";
        if (type(group) != "object" || type(group.prefixes) != "array" || length(group.prefixes) == 0)
            die(where + ": invalid prefixes");
        let protocols = snapshot_protocols(group.networks, where);
        let ranges = snapshot_ranges(group.port_ranges, where);
        if (length(ranges) == 0 && length(protocols) == 0)
            die(where + ": unconstrained group");

        if (length(ports) > 0)
            ranges = length(ranges) > 0 ? intersect_ranges(ranges, ports) : ports;
        else if (length(ranges) == 0)
            ranges = [ { start: 1, end: 65535 } ];
        if (length(ranges) == 0)
            continue;

        for (let prefix in group.prefixes) {
            let bounds = prefix_bounds(prefix, family, where);
            if (length(protocols) == 0)
                push(boxes.pairs, { ...bounds, key: "", ranges });
            for (let protocol in protocols)
                push(boxes.triples, { ...bounds, key: protocol, ranges });
        }
    }
}

// null while a provider has not loaded. A section address nft cannot match is dropped, as
// the table drops it, instead of failing the section.
function section_plan(snapshot, entry) {
    let m = entry.matchers;
    let ports = section_ranges(m.ports);
    let plain = { "4": [], "6": [] };
    let boxes = { "4": { pairs: [], triples: [] }, "6": { pairs: [], triples: [] } };

    for (let value in split(m.subnets, ",")) {
        let family = core_ip.ip_family(value);
        if (family != 0)
            push(plain[family], value);
    }

    for (let tag in m.subnet_tags) {
        let provider = snapshot.providers[tag];
        let label = "provider " + tag;
        if (provider == null)
            die("missing rule-set provider: " + tag);
        if (type(provider) != "object" || type(provider.revision) != "int")
            die(label + ": malformed snapshot");
        if (provider.revision < 1)
            return null;
        let ip_cidr = provider.ip_cidr;
        if (type(ip_cidr) != "object")
            die(label + ": missing ip_cidr snapshot");
        if (type(ip_cidr.digest) != "string" || ip_cidr.digest == "")
            die(label + ": ip_cidr snapshot carries no digest");

        for (let family in [ 4, 6 ]) {
            let prefixes = ip_cidr[family == 4 ? "ipv4" : "ipv6"];
            if (type(prefixes) != "array")
                die(label + ".ip_cidr.ipv" + family + " must be an array");
            for (let prefix in prefixes) {
                if (!prefix_is_nft_safe(prefix, family))
                    die(label + ": invalid IP prefix " + as_string(prefix));
                push(plain["" + family], prefix);
            }
            add_groups(boxes["" + family], ip_cidr[family == 4 ? "scoped_ipv4" : "scoped_ipv6"], family, ports,
                label + ".ip_cidr.scoped_ipv" + family);
        }
    }

    let s = m.sets;
    let pairs4 = disjoint(boxes["4"].pairs), pairs6 = disjoint(boxes["6"].pairs);
    let triples4 = disjoint(boxes["4"].triples), triples6 = disjoint(boxes["6"].triples);
    return {
        section: as_string(entry.section[".name"]),
        sets: [
            [ s.subnets, plain["4"] ], [ s.subnets6, plain["6"] ],
            [ s.ip_ports, pairs4.elements ], [ s.ip6_ports, pairs6.elements ],
            [ s.proto_ports, triples4.elements ], [ s.proto6_ports, triples6.elements ]
        ],
        scoped: pairs4.count + pairs6.count + triples4.count + triples6.count
    };
}

function write_exact(handle, text) {
    if (handle.write(text) != length(text))
        die("cannot write the complete nft transaction");
}

// The flush and the new elements land in one transaction, so the set is never seen empty.
function write_set(handle, set_name, elements) {
    write_exact(handle, "flush set inet " + TABLE + " " + set_name + "\n");
    let prefix = "add element inet " + TABLE + " " + set_name + " { ";
    let line = [];
    let line_length = 0;
    let written = 0;
    let last = null;

    for (let element in sort(elements)) {
        if (element == last)
            continue;
        last = element;
        written++;
        if (length(line) >= MAX_ELEMENTS_PER_LINE || line_length + length(element) + 2 > MAX_LINE_LENGTH) {
            write_exact(handle, prefix + join(", ", line) + " }\n");
            line = [];
            line_length = 0;
        }
        push(line, element);
        line_length += length(element) + 2;
    }
    if (length(line) > 0)
        write_exact(handle, prefix + join(", ", line) + " }\n");
    return written;
}

// Written to a file, so what this process holds is released before nft starts allocating.
function apply_plan(plan, guard) {
    let now = clock();
    let base = sprintf("/tmp/loki-ruleset-sync.%d.%d.%d", common.own_pid(), now[0], now[1]);
    if (!fs.mkdir(base, 0700))
        die("cannot write the nft transaction");
    let path = base + "/transaction.nft";
    let handle = null;
    let count = plan.scoped;
    try {
        handle = fs.open(path, "w");
        if (!handle)
            die("cannot write the nft transaction");
        for (let i = 0; i < length(plan.sets); i++) {
            let written = write_set(handle, plan.sets[i][0], plan.sets[i][1]);
            if (i < 2)
                count += written;
            plan.sets[i] = null;
        }
        let expected = handle.tell();
        let closed = handle.close();
        handle = null;
        // Older fs.close() ignores a failed buffered flush; verify the resulting file as well.
        if (expected == null || !closed || fs.stat(path)?.size != expected)
            die("cannot finish the complete nft transaction");
        let owner = common.own_pid();
        let acquired = false;
        let permitted = false;
        try {
            acquired = guard == null || lock.acquire(paths.lock, owner);
            permitted = acquired && (guard == null || guard());
        }
        catch (e) {}
        try {
            if (permitted) {
                let result = exec.combined([ "nft", "-f", path ]);
                if (result.status != 0)
                    die(nft_apply.refusal({ status: result.status, stderr: result.output }));
            }
        }
        catch (e) {
            if (guard != null && acquired) lock.release(paths.lock, owner);
            die(e.message);
        }
        if (guard != null && acquired) lock.release(paths.lock, owner);
        if (!permitted) count = null;
    }
    catch (e) {
        if (handle)
            handle.close();
        fs.unlink(path);
        fs.rmdir(base);
        die(e.message);
    }
    fs.unlink(path);
    fs.rmdir(base);
    return count;
}

// A provider's revision restarts with every core; only the digest tells written content from new.
function plan_key(snapshot, entry) {
    let m = entry.matchers;
    let parts = [ m.subnets, m.ports ];
    for (let tag in m.subnet_tags)
        push(parts, tag + ":" + (snapshot.providers[tag]?.ip_cidr?.digest ?? ""));
    return join("\t", parts);
}

function sync(snapshot, native, guard) {
    let loaded = 0, written = 0;
    let deferred = false;
    for (let entry in native) {
        let name = as_string(entry.section[".name"]);
        let key = plan_key(snapshot, entry);
        if (applied[name] == key || refused[name] == key)
            continue;

        try {
            let plan = section_plan(snapshot, entry);
            if (plan == null)
                continue;
            let count = apply_plan(plan, guard == null ? null : () => guard(entry));
            if (count == null) { deferred = true; continue; }
            loaded += count;
            applied[name] = key;
            delete refused[name];
            written++;
        }
        catch (e) {
            delete applied[name];
            refused[name] = key;
            exec.log("error", "Failed to load the rule-set subnets of section '" + connections.section_display_name(entry.section) + "' into nftables: " + e.message);
        }
    }

    if (written > 0)
        exec.log("info", "Loaded " + loaded + " rule-set subnets into nftables" +
            (written == length(native) ? "" : " for " + written + " of " + length(native) + " sections"));
    return { loaded, written, deferred };
}

// Decoded as it arrives, so a country-sized list is never held twice.
function snapshot(api) {
    let reply = clash_api.exchange(api, "GET", "/providers/rules", { connect_seconds: 2, seconds: 10, decode: json });
    let value = reply?.status == 200 ? reply.value : null;
    return type(value?.providers) == "object" && type(value?.revision) == "int" ? value : null;
}

// The revision synced, null without a snapshot, false when no section reads a provider.
function sync_once(api, sections, guard) {
    if (length(sections) == 0)
        return false;
    let value = snapshot(api);
    if (value == null)
        return null;
    return sync(value, sections, guard).deferred ? null : value.revision;
}

// true on a provider change, false when the wait ran out, null when the controller is unreachable.
function next_change(api, revision, seconds) {
    let reply = clash_api.exchange(api, "GET", "/providers/rules/events?since=" + revision, { connect_seconds: 2, seconds });
    if (reply === false)
        return false;
    return reply?.status == 200 && type(common.parse_json(reply.body)?.revision) == "int" ? true : null;
}

function worker_spec(generation) {
    return {
        name: "loki-ruleset-sync",
        instance: "sync",
        command: generation == null ? [ constants.LOKI_BIN, "sync_rule_sets" ] :
            [ constants.LOKI_BIN, "sync_rule_sets", generation ],
        env: { LOKI_LIB: library.dir() },
        pid_file: "/var/run/loki/ruleset-sync.pid",
        data: generation == null ? null : { generation }
    };
}

function same_identity(first, second) {
    return first != null && second != null && first.pid == second.pid &&
        first.start_ticks == second.start_ticks && sprintf("%J", first.command) == sprintf("%J", second.command);
}

function sets_present(entry) {
    for (let _, name in entry.matchers.sets)
        if (!exec.ok([ "nft", "-t", "list", "set", "inet", TABLE, name ])) return false;
    return true;
}

function ready_context(snapshot) {
    try {
        if (!lock.unmarked(paths.planned_stop)) return null;
        if (snapshot != null && !context.unchanged(snapshot)) return null;
        let state = snapshot ?? context.read();
        let active = state.model?.phase == "ready" ? state.model.active : null;
        if (active == null || !health.sing_box_runtime_ports_ready()) return null;
        let identity = runtime.identity(active.config_path);
        if (identity == null || sprintf("%J", identity.command) != sprintf("%J", active.command) ||
            runtime.file_digest(active.config_path) != active.config_digest) return null;
        if (!same_identity(active, identity)) {
            active = { ...active, ...identity };
            if (!context.write({ schema: 1, phase: "ready", active, candidate: null })) return null;
        }
        return active;
    }
    catch (e) { return null; }
}

function worker(generation) {
    if (type(generation) != "string" || length(generation) != 64 ||
        !match(generation, /^[a-f0-9]{64}$/) || generation == sprintf("%064d", 0)) return 1;
    let spec = worker_spec(generation);
    if (!worker_process.announce(spec)) return 1;
    let delay = RETRY_MIN_SECONDS;
    let pinned = null;
    let revision = null;
    while (true) {
        if (pinned != null && !context.unchanged(pinned)) {
            if (!context.close(pinned)) break;
            pinned = null;
            revision = null;
            applied = {}; refused = {};
        }
        if (pinned == null) {
            let loaded = context.open();
            if (loaded.error == null) {
                let owner = common.own_pid();
                let acquired = false;
                try {
                    acquired = lock.acquire(paths.lock, owner);
                    let active = acquired ? ready_context(loaded) : null;
                    if (active?.generation == generation && context.unchanged(loaded)) pinned = loaded;
                }
                catch (e) {}
                if (acquired) lock.release(paths.lock, owner);
                if (pinned == null && !context.close(loaded)) break;
            }
        }
        if (pinned == null || pinned.model?.phase != "ready" || pinned.model.active.generation != generation) {
            sleep(delay * 1000);
            delay = min(delay * 2, RETRY_MAX_SECONDS);
            continue;
        }
        let active = pinned.model.active;
        if (length(active.sections) == 0) break;
        let api = active.controller;
        let change = revision == null ? true : next_change(api, revision, EVENT_WAIT_SECONDS);
        if (change === false) continue;
        if (change == null) {
            context.close(pinned); pinned = null; revision = null;
            sleep(delay * 1000); delay = min(delay * 2, RETRY_MAX_SECONDS);
            continue;
        }
        revision = sync_once(api, active.sections, (entry) => context.unchanged(pinned) &&
            lock.unmarked(paths.planned_stop) && same_identity(active, runtime.identity(active.config_path)) &&
            health.sing_box_runtime_ports_ready() && sets_present(entry));
        if (revision != null)
            delay = RETRY_MIN_SECONDS;
        else {
            context.close(pinned); pinned = null;
            sleep(delay * 1000); delay = min(delay * 2, RETRY_MAX_SECONDS);
        }
    }
    if (pinned != null) context.close(pinned);
    worker_process.retire(spec);
    return 0;
}

function stop_worker() {
    return worker_process.stop(worker_spec());
}

function start_worker(active) {
    if (active == null) return false;
    if (length(active.sections) == 0)
        return stop_worker();
    return worker_process.start(worker_spec(active.generation));
}

function worker_current(active) {
    if (active == null) return false;
    let spec = worker_spec(active.generation);
    if (length(active.sections) == 0)
        return !worker_process.running(spec);
    return worker_process.current(spec);
}

return { paths, sync, worker_spec, worker, start_worker, stop_worker, worker_current, ready_context };
