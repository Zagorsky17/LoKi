let t = require("t");
let stub = require("stub");
let fs = require("fs");
let listeners = require("service.preflight_listeners");

function header(name) {
    return "sl local_address " + (substr(name, -1) == "6" ? "remote_address" : "rem_address") +
        " st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode" +
        (substr(name, 0, 3) == "udp" ? " ref pointer drops" : "") + "\n";
}

function row(name, port, state, inode) {
    let address = substr(name, -1) == "6" ? "20010DB8000000000000000000000001" : "2A7100CB";
    let zero = substr(name, -1) == "6" ? "00000000000000000000000000000000" : "00000000";
    return "0: " + address + ":" + (port || "0035") + " " + zero + ":0000 " +
        (state || (substr(name, 0, 3) == "udp" ? "07" : "0A")) +
        " 00000000:00000000 00:00000000 00000000 1000 0 " + (inode || "12345") +
        " 1 0000000000000000" + (substr(name, 0, 3) == "udp" ? " 0" : "") + "\n";
}

function fixture() {
    let root = stub.tmpdir();
    fs.chmod(root, 0755);
    stub.real.system("umask 022; mkdir -p '" + root + "/proc/self/net'");
    for (let name in [ "tcp", "tcp6", "udp", "udp6" ]) {
        fs.writefile(root + "/proc/self/net/" + name, header(name) + row(name));
        fs.chmod(root + "/proc/self/net/" + name, 0644);
    }
    return root;
}

function has(result, reason, object) {
    return length(filter(result, (item) => item.reason == reason && (object == null || item.object == object))) > 0;
}

t.test("clear candidate bindings need a checked environment scope before listener admission", () => {
    let root = fixture(), scope = { identities: { net: "net:[123]" } };
    t.eq(length(filter(listeners.collect(root, scope), (item) => item.state != "checked")), 0);
    for (let value in [ null, {}, { error: "environment-namespace-differs-from-pid1", identities: {} } ])
        t.ok(has(listeners.collect(root, value), "listener-process-ownership-unverified"));
    for (let name in [ "tcp", "tcp6", "udp", "udp6" ]) {
        fs.writefile(root + "/proc/self/net/" + name, header(name));
        t.ok(has(listeners.collect(root, scope), "listener-candidate-ports-clear"));
    }
    fs.writefile(root + "/proc/self/net/tcp", header("tcp") + replace(row("tcp"), "2A7100CB", "00000000"));
    t.ok(has(listeners.collect(root, scope), "listener-candidate-port-occupied-unverified"));
    t.eq(has(listeners.collect(root, scope), "listener-candidate-ports-clear"), false);
    fs.unlink(root + "/proc/self/net/tcp");
    t.eq(has(listeners.collect(root, scope), "listener-candidate-ports-clear"), false);
});

t.test("a prior unrelated filesystem error cannot poison a successful listener stream read", () => {
    let root = fixture(), open = fs.open, result, error;
    fs.open = (path, mode) => {
        let file = open(path, mode);
        if (file != null && index(path, root + "/proc/self/net/") == 0) fs.lstat(root + "/missing-private");
        return file;
    };
    try { result = listeners.collect(root, { identities: {} }); } catch (e) { error = e; }
    fs.open = open; if (error != null) die(error);
    t.eq(length(filter(result, (item) => item.state != "checked")), 0);
});

t.test("four table formats retain exact opaque endpoint and inode identities", () => {
    for (let name in [ "tcp", "tcp6", "udp", "udp6" ]) {
        let result = listeners.parse(header(name) + row(name, "FFFF", null, "18446744073709551615"), name);
        t.eq(result.error, null);
        t.eq(result.rows, 1);
        t.eq(result.bindings[0].port, 65535);
        t.eq(result.bindings[0].inode, "18446744073709551615");
        t.eq(result.bindings[0].uid, "1000");
    }
});

t.test("established and time-wait TCP rows do not become listeners", () => {
    let result = listeners.parse(header("tcp") + row("tcp", null, "01") + row("tcp", null, "06") + row("tcp"), "tcp");
    t.eq(result.rows, 3);
    t.eq(length(result.bindings), 1);
    t.eq(result.bindings[0].state, 10);
});

t.test("connected UDP and reuse-port sockets survive repeated bucket numbers", () => {
    let result = listeners.parse(header("udp") + row("udp", null, "01", "1") + row("udp", null, "07", "2"), "udp");
    t.eq(result.error, null);
    t.eq(length(result.bindings), 2);
    t.eq(result.bindings[0].state, 1);
    t.eq(listeners.parse(header("udp") + row("udp") + row("udp"), "udp").error, "listener-table-duplicate-binding");
});

t.test("header-only tables are valid but missing, truncated and unknown formats are not", () => {
    t.eq(listeners.parse(header("tcp"), "tcp").bindings, []);
    for (let data in [ null, 42, "", "\n", "not-a-header\n", header("tcp") + "\n", header("udp"),
        header("tcp") + substr(row("tcp"), 0, length(row("tcp")) - 1), header("tcp") + row("tcp") + "\u0000" ])
        t.ok(listeners.parse(data, "tcp").error != null);
    t.eq(listeners.parse(header("tcp"), "../../private").error, "listener-table-kind-invalid");
});

t.test("malformed endpoints, counters and unknown socket states refuse the entire table", () => {
    let good = header("tcp") + row("tcp");
    for (let bad in [ replace(good, "2A7100CB", "2A7100CZ"), replace(good, ":0035", ":0000"),
        replace(good, ":0035", ":10000"), replace(good, " 0A ", " 0D "),
        replace(good, " 1000 ", " 4294967296 "), replace(good, " 12345 ", " -1 "),
        replace(good, "00000000:00000000", "00000000:invalid"), replace(good, "\n0:", "\n;touch-private:"),
        replace(good, " 0A ", "\r0A "), replace(good, "12345", "00012345") ])
        t.ok(listeners.parse(bad, "tcp").error != null);
    t.eq(listeners.parse(header("udp") + row("udp", null, "0A"), "udp").error, "listener-table-state-invalid");
});

t.test("row and byte budgets reject one extra input instead of returning a partial set", () => {
    let data = header("tcp");
    for (let i = 0; i < 2048; i++) data += row("tcp", null, "01", "" + (i + 1));
    t.eq(listeners.parse(data, "tcp").rows, 2048);
    t.eq(listeners.parse(data + row("tcp", null, "01"), "tcp").error, "listener-table-row-limit");
    t.eq(listeners.parse(header("tcp") + sprintf("%262144s", "") + "\n", "tcp").error, "listener-table-size-limit");
});

t.test("discovery reports fixed roles and mandatory gaps without addresses or process identifiers", () => {
    let root = fixture();
    for (let name in [ "tcp", "tcp6", "udp", "udp6" ]) {
        let before = substr(name, -1) == "6" ? "20010DB8000000000000000000000001" : "2A7100CB";
        let after = substr(name, -1) == "6" ? "0000000000000000FFFF00002A00007F" : "2A00007F";
        fs.writefile(root + "/proc/self/net/" + name, header(name) + replace(row(name), before, after));
    }
    let result = listeners.collect(root);
    t.eq(length(filter(result, (item) => item.reason == "listener-table-read-complete")), 4);
    t.ok(has(result, "listener-candidate-port-occupied-unverified", "ipv4-tcp-dns"));
    t.ok(has(result, "listener-candidate-port-occupied-unverified", "ipv6-udp-dns"));
    t.ok(has(result, "listener-process-ownership-unverified"));
    t.ok(has(result, "listener-namespace-and-bind-configuration-unverified"));
    for (let secret in [ "2A7100CB", "20010DB8", "12345", root ]) t.excludes(sprintf("%J", result), secret);
    t.eq(listeners.collect(root), result);
});

t.test("each known port uses its shared constants without leaking unrelated bound ports", () => {
    let root = fixture();
    let data = header("tcp");
    let inode = 10;
    for (let port in [ "0035", "0642", "0643", "0644", "0645", "2384", "BEEF" ])
        data += row("tcp", port, null, "" + inode++);
    fs.writefile(root + "/proc/self/net/tcp", replace(data, "2A7100CB", "00000000"));
    let result = listeners.collect(root);
    for (let role in [ "dns", "tproxy", "source-dns", "system-tproxy", "system-dns" ])
        t.ok(has(result, "listener-candidate-port-occupied-unverified", "ipv4-tcp-" + role));
    t.ok(!has(result, "listener-candidate-port-occupied-unverified", "ipv4-tcp-controller"));
    t.excludes(sprintf("%J", result), "48879");
});

t.test("unsafe fixture parents, linked leaves and absent tables are not empty inventories", () => {
    let root = fixture();
    fs.chmod(root + "/proc/self", 0777);
    t.ok(has(listeners.collect(root), "listener-table-path-unavailable"));
    fs.chmod(root + "/proc/self", 0755);
    fs.unlink(root + "/proc/self/net/tcp");
    fs.symlink(root + "/proc/self/net/udp", root + "/proc/self/net/tcp");
    t.ok(has(listeners.collect(root), "listener-table-path-unavailable", "ipv4-tcp"));
    fs.unlink(root + "/proc/self/net/tcp6");
    t.ok(has(listeners.collect(root), "listener-table-path-unavailable", "ipv6-tcp"));
});

t.test("opened inode substitution refuses before reading and still closes its descriptor", () => {
    let root = fixture();
    let path = root + "/proc/self/net/tcp";
    let open = fs.open;
    let read = false;
    let closed = false;
    fs.open = (name, mode) => {
        if (name != path) return open(name, mode);
        let file = open(root + "/proc/self/net/udp", mode);
        return { fileno: () => file.fileno(), read: () => { read = true; return ""; },
            close: () => { closed = true; return file.close(); } };
    };
    let result = listeners.collect(root);
    fs.open = open;
    t.ok(has(result, "listener-table-changed-during-read", "ipv4-tcp"));
    t.eq(read, false);
    t.eq(closed, true);
});

function failed_table_close(thrown) {
    let root = fixture();
    let path = root + "/proc/self/net/tcp";
    let open = fs.open;
    let closed = 0;
    fs.open = (name, mode) => {
        let file = open(name, mode);
        if (name != path) return file;
        return { fileno: () => file.fileno(), read: (limit) => file.read(limit), error: () => file.error(),
            close: () => { closed++; file.close(); if (thrown) die("synthetic-private-close"); return false; } };
    };
    let result;
    let exception = null;
    try { result = listeners.collect(root); }
    catch (e) { exception = e.message; }
    fs.open = open;
    t.eq(exception, null);
    t.eq(closed, 1);
    t.ok(has(result, "listener-table-read-failed", "ipv4-tcp"));
    t.eq(has(result, "listener-table-read-complete", "ipv4-tcp"), false);
    t.excludes(sprintf("%J", result), "synthetic-private");
    t.ok(has(listeners.collect(root), "listener-table-read-complete", "ipv4-tcp"));
}

t.test("a false table close refuses listener coverage", () => failed_table_close(false));
t.test("a throwing table close refuses listener coverage privately", () => failed_table_close(true));

t.test("read errors and exceptions close handles and keep raw details private", () => {
    for (let thrown in [ false, true ]) {
        let root = fixture();
        let path = root + "/proc/self/net/tcp";
        let open = fs.open;
        let closed = false;
        fs.open = (name, mode) => {
            let file = open(name, mode);
            if (name != path) return file;
            return { fileno: () => file.fileno(), read: () => { if (thrown) die("synthetic-private-read"); return header("tcp"); },
                error: () => "synthetic-private-error", close: () => { closed = true; return file.close(); } };
        };
        let result = listeners.collect(root);
        fs.open = open;
        t.eq(closed, true);
        t.ok(has(result, "listener-table-read-failed", "ipv4-tcp"));
        t.excludes(sprintf("%J", result), "synthetic-private");
    }
});

t.test("a changed live binding is rejected while queue-only changes remain valid", () => {
    for (let changed_binding in [ false, true ]) {
        let root = fixture();
        let path = root + "/proc/self/net/tcp";
        let open = fs.open;
        let reads = 0;
        fs.open = (name, mode) => {
            let file = open(name, mode);
            if (name != path) return file;
            return { fileno: () => file.fileno(), read: (limit) => {
                let value = file.read(limit);
                if (++reads == 2) value = replace(value, changed_binding ? "12345" : "00000000:00000000",
                    changed_binding ? "12346" : "00000001:00000000");
                return value;
            }, error: () => file.error(), close: () => file.close() };
        };
        let result = listeners.collect(root);
        fs.open = open;
        t.eq(has(result, "listener-bindings-changed", "ipv4-tcp"), changed_binding);
        t.eq(has(result, "listener-table-read-complete", "ipv4-tcp"), !changed_binding);
    }
});

t.test("the gateway candidate TCP port is observed without treating an unrelated UDP socket as a conflict", () => {
    let root = fixture();
    for (let name in [ "tcp", "tcp6", "udp", "udp6" ])
        fs.writefile(root + "/proc/self/net/" + name, header(name) + row(name, "2383"));
    let result = listeners.collect(root);
    for (let family in [ "ipv4", "ipv6" ]) {
        t.eq(has(result, "listener-candidate-port-occupied-unverified", family + "-tcp-gateway"), true,
            "gateway TCP binding must be reported");
        t.eq(has(result, "listener-candidate-port-occupied-unverified", family + "-udp-gateway"), false,
            "an unrelated UDP socket does not occupy the HTTPS port");
    }
});

t.test("a different IPv4 loopback listener does not occupy the candidate DNS address", () => {
    let root=fixture();
    for(let name in ["tcp","tcp6","udp","udp6"])fs.writefile(root+"/proc/self/net/"+name,header(name));
    let data=replace(row("tcp"),"2A7100CB","0100007F");
    fs.writefile(root+"/proc/self/net/tcp",header("tcp")+data);
    t.eq(has(listeners.collect(root),"listener-candidate-port-occupied-unverified","ipv4-tcp-dns"),false);
});

t.test("DNS wildcards and mapped candidates are retained in both host word orders", () => {
    let root=fixture();
    for(let name in ["tcp","tcp6","udp","udp6"])fs.writefile(root+"/proc/self/net/"+name,header(name));
    for(let pair in [
        ["tcp","2A00007F",true],["tcp","7F00002A",true],["tcp","00000000",true],
        ["tcp","0100007F",false],["tcp","7F000001",false],
        ["tcp6","0000000000000000FFFF00002A00007F",true],
        ["tcp6","00000000000000000000FFFF7F00002A",true],
        ["tcp6","00000000000000000000000000000000",true],
        ["tcp6","00000000000000000000000001000000",false]
    ]) {
        let original=pair[0]=="tcp"?"2A7100CB":"20010DB8000000000000000000000001";
        fs.writefile(root+"/proc/self/net/"+pair[0],header(pair[0])+replace(row(pair[0]),original,pair[1]));
        t.eq(has(listeners.collect(root),"listener-candidate-port-occupied-unverified",pair[0]=="tcp"?"ipv4-tcp-dns":"ipv6-tcp-dns"),pair[2]);
        fs.writefile(root+"/proc/self/net/"+pair[0],header(pair[0]));
    }
});

t.test("an unsupported candidate DNS address keeps bound ports unverified", () => {
    let constants=require("singbox.constants"),before=constants.DNS_INBOUND_ADDRESS;
    let root=fixture(),result,error;
    constants.DNS_INBOUND_ADDRESS="synthetic-private-invalid-address";
    try {result=listeners.collect(root);}catch(e){error=e;}
    constants.DNS_INBOUND_ADDRESS=before;
    if(error!=null)die(error);
    t.ok(has(result,"listener-candidate-port-occupied-unverified","ipv4-tcp-dns"));
    t.excludes(sprintf("%J",result),"synthetic-private-invalid-address");
});

t.done();
