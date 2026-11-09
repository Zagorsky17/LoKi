let t = require("t"), fs = require("fs"), stub = require("stub");
let config = require("service.preflight_config"), services = require("service.preflight_services");
let query = require("core.exec");
query.deadline = (argv, seconds, limit) => query.combined(argv, limit);

function write(path, data, mode) { fs.writefile(path, data); fs.chmod(path, mode ?? 0644); }
function fixture() {
    let root = stub.tmpdir(); fs.chmod(root, 0755);
    stub.real.system("umask 022; mkdir -p '" + root + "/tmp/etc' '" + root + "/tmp/dnsmasq.cfg01.d' '" + root + "/tmp/resolv.conf.d' '" +
        root + "/etc/rc.d' '" + root + "/usr/sbin' '" + root + "/proc/123/fd' '" + root + "/proc/123/ns' '" + root + "/proc/1/ns' '" + root + "/proc/self/net'");
    fs.symlink("tmp", root + "/var");
    write(root + "/tmp/etc/dnsmasq.conf.cfg01", "# generated\nbind-dynamic\nresolv-file=/tmp/resolv.conf.d/resolv.conf.auto\nconf-file=/etc/dnsmasq.conf\nconf-dir=/tmp/dnsmasq.cfg01.d\n");
    write(root + "/etc/dnsmasq.conf", "# default\n");
    write(root + "/tmp/resolv.conf.d/resolv.conf.auto", "# Interface wan\nnameserver 192.0.2.53\n");
    write(root + "/usr/sbin/dnsmasq", "synthetic-private-executable", 0755);
    fs.symlink(root + "/usr/sbin/dnsmasq", root + "/proc/123/exe");
    let fields = [ "S" ]; for (let i = 1; i < 50; i++) push(fields, i == 19 ? "12345" : "0");
    write(root + "/proc/123/stat", "123 (dnsmasq) " + join(" ", fields) + "\n");
    for (let pid in [ "1", "123" ]) fs.symlink("net:[123]", root + "/proc/" + pid + "/ns/net");
    for (let pair in [ [ "tcp", "110" ], [ "udp", "111" ], [ "tcp6", "112" ], [ "udp6", "113" ] ]) {
        let name = pair[0], ipv6 = substr(name, -1) == "6", udp = substr(name, 0, 3) == "udp";
        let header = "sl local_address " + (ipv6 ? "remote_address" : "rem_address") + " st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode" + (udp ? " ref pointer drops" : "") + "\n";
        let local = ipv6 ? "00000000000000000000000001000000" : "0100007F", remote = ipv6 ? sprintf("%032d", 0) : "00000000";
        write(root + "/proc/self/net/" + name, header + "0: " + local + ":0035 " + remote + ":0000 " + (udp ? "07" : "0A") + " 00000000:00000000 00:00000000 00000000 1000 0 " + pair[1] + " 1 0000000000000000" + (udp ? " 0" : "") + "\n");
        fs.symlink("socket:[" + pair[1] + "]", root + "/proc/123/fd/" + pair[1]);
    }
    return root;
}
function reply() { return { dnsmasq: { instances: { cfg01: { running: true, pid: 123,
    command: [ "/usr/sbin/dnsmasq", "-C", "/var/etc/dnsmasq.conf.cfg01", "-k", "-x", "/var/run/dnsmasq/dnsmasq.cfg01.pid" ],
    env: { TOKEN: "synthetic-private-token" } } } } }; }
function collect(root, value) {
    stub.commands([[ "/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C ubus", { stdout: sprintf("%J", value ?? reply()) } ]]);
    let rows, error;
    try { rows = services.collect(root); } catch (e) { error = e; }
    stub.restore(); if (error != null) die(error);
    return filter(rows, (row) => row.kind == "dns-runtime")[0];
}

t.test("stock runtime includes and kernel socket identities admit DNS without exposing metadata", () => {
    let root = fixture();
    t.eq(collect(root), { kind: "dns-runtime", object: "dnsmasq-config", state: "checked", reason: "dns-runtime-config-checked" });
    for (let name in [ ".hidden", "backup~", "#editor#" ]) write(root + "/tmp/dnsmasq.cfg01.d/" + name, "conf-script=/synthetic-private\n");
    t.eq(collect(root).state, "checked");
    write(root + "/tmp/dnsmasq.cfg01.d/forward", "server=/example.org/198.51.100.53#5353\n");
    t.eq(collect(root).state, "checked");
    write(root + "/tmp/dnsmasq.cfg01.d/forward", "server=127.0.0.42#53\n");
    let result = collect(root); t.eq(result.state, "conflict"); t.eq(result.reason, "dnsmasq-forwards-to-candidate");
    t.excludes(sprintf("%J", result), "synthetic-private");
});

t.test("unsupported runtime inputs refuse instead of executing scripts or silently ignoring includes", () => {
    for (let data in [ "conf-script=/synthetic-private\n", "conf-file=/missing\n", "conf-file=../private\n", "conf-file=/etc/dnsmasq.conf\n",
        "conf-dir=/tmp/dnsmasq.cfg01.d,*.conf\n", "port=5353\n", "server=127.0.0.1\n", "server=[::1]#5353\n", "enable-dbus\n", "rev-server=192.0.2.0/24,127.0.0.1\n", "bad syntax\n" ]) {
        let root = fixture(); write(root + "/etc/dnsmasq.conf", data);
        let result = collect(root); t.eq(result.state, "incomplete", data); t.excludes(sprintf("%J", result), "synthetic-private");
    }
    let root = fixture(); write(root + "/tmp/resolv.conf.d/resolv.conf.auto", "nameserver 127.0.0.42\n");
    t.eq(collect(root).state, "conflict");
    write(root + "/tmp/resolv.conf.d/resolv.conf.auto", "nameserver malformed\n"); t.eq(collect(root).state, "incomplete");
});

t.test("missing or foreign processes, incomplete sockets and altered command lines remain incomplete", () => {
    for (let fault in [ "exe", "mode", "net", "tcp", "udp", "fd", "command", "stopped", "duplicate" ]) {
        let root = fixture(), value = reply();
        if (fault == "exe") { fs.unlink(root + "/proc/123/exe"); fs.symlink("/bin/sh", root + "/proc/123/exe"); }
        if (fault == "mode") fs.chmod(root + "/usr/sbin/dnsmasq", 0777);
        if (fault == "net") { fs.unlink(root + "/proc/123/ns/net"); fs.symlink("net:[456]", root + "/proc/123/ns/net"); }
        if (fault == "tcp" || fault == "udp") for (let name in [ fault, fault + "6" ]) fs.unlink(root + "/proc/self/net/" + name);
        if (fault == "fd") for (let name in fs.lsdir(root + "/proc/123/fd")) fs.unlink(root + "/proc/123/fd/" + name);
        if (fault == "command") push(value.dnsmasq.instances.cfg01.command, "--conf-script=/synthetic-private");
        if (fault == "stopped") value.dnsmasq.instances = {};
        if (fault == "duplicate") value.dnsmasq.instances.second = value.dnsmasq.instances.cfg01;
        let result = collect(root, value); t.eq(result.state, "incomplete", fault); t.excludes(sprintf("%J", result), "synthetic-private");
    }
});

t.test("symlinks, hardlinks, writable include directories and same-length content changes refuse", () => {
    for (let fault in [ "link", "hardlink", "directory", "changed" ]) {
        let root = fixture(), path = root + "/etc/dnsmasq.conf", open = fs.open;
        if (fault == "link") { fs.rename(path, path + ".keep"); fs.symlink(path + ".keep", path); }
        if (fault == "hardlink") stub.real.system("ln '" + path + "' '" + path + ".keep'");
        if (fault == "directory") fs.chmod(root + "/tmp/dnsmasq.cfg01.d", 0777);
        let reads = 0;
        if (fault == "changed") fs.open = (name, mode) => {
            let file = open(name, mode); if (name != path || file == null) return file;
            return { fileno: () => file.fileno(), error: () => file.error(), close: () => file.close(),
                read: (count) => { let data = file.read(count); return ++reads == 2 ? replace(data, "default", "changed") : data; } };
        };
        let result, error;
        try { result = collect(root); } catch (e) { error = e; }
        fs.open = open; if (error != null) die(error);
        t.eq(result.state, "incomplete", fault); t.excludes(sprintf("%J", result), "synthetic-private");
    }
});

t.test("connected UDP clients do not prove a listening DNS server", () => {
    let root = fixture();
    for (let name in [ "udp", "udp6" ]) {
        let path = root + "/proc/self/net/" + name, text = fs.readfile(path);
        text = replace(text, ":0035 " + (name == "udp" ? "00000000" : sprintf("%032d", 0)) + ":0000 07", ":0035 " +
            (name == "udp" ? "350200C0" : "00000000000000000000000001000000") + ":0035 01");
        write(path, text);
    }
    t.eq(collect(root).state, "incomplete");
});

t.test("runtime bounds and failed directory closure preserve a specific private refusal", () => {
    for (let count in [ 125, 126 ]) {
        let root = fixture();
        for (let i = 0; i < count; i++) write(root + "/tmp/dnsmasq.cfg01.d/file" + i, "# fixture\n");
        t.eq(collect(root).state, count == 125 ? "checked" : "incomplete");
    }
    for (let failure in [ "bytes", "entries", "close" ]) {
        let root = fixture(), opendir = fs.opendir;
        if (failure == "bytes") write(root + "/etc/dnsmasq.conf", sprintf("#%1048576s", "x"));
        else fs.opendir = (path) => {
            let directory = opendir(path);
            if (path != root + "/tmp/dnsmasq.cfg01.d" || directory == null) return directory;
            let count = 0;
            return { read: () => failure == "entries" && count < 4097 ? "file" + ++count : directory.read(),
                close: () => { let closed = directory.close(); return failure == "close" ? false : closed; } };
        };
        let result, error;
        try { result = collect(root); } catch (e) { error = e; }
        fs.opendir = opendir; if (error != null) die(error);
        t.eq(result.state, "incomplete", failure); t.excludes(sprintf("%J", result), "synthetic-private");
    }
});

function supervisor(root, pid, children) {
    stub.real.system("umask 022; mkdir -p '" + root + "/sbin' '" + root + "/proc/" + pid + "/task/" + pid + "' '" + root + "/proc/" + pid + "/ns'");
    if (fs.lstat(root + "/sbin/ujail") == null) write(root + "/sbin/ujail", "synthetic-private-supervisor", 0755);
    fs.symlink(root + "/sbin/ujail", root + "/proc/" + pid + "/exe");
    let fields = [ "S" ]; for (let i = 1; i < 50; i++) push(fields, i == 19 ? "45678" : "0");
    write(root + "/proc/" + pid + "/stat", pid + " (ujail) " + join(" ", fields) + "\n");
    fs.symlink("net:[123]", root + "/proc/" + pid + "/ns/net");
    write(root + "/proc/" + pid + "/task/" + pid + "/children", children);
}

t.test("existing stock ujail supervisors bind DNS admission to the real child instead of the wrapper PID", () => {
    for (let nested in [ false, true ]) {
        let root = fixture(), value = reply(); value.dnsmasq.instances.cfg01.pid = 43;
        supervisor(root, "43", nested ? "44 " : "123 ");
        if (nested) supervisor(root, "44", "123 ");
        t.eq(collect(root, value).state, "checked");
    }
});

t.test("supervisor limits, foreign executables and ambiguous or changed child trees remain incomplete", () => {
    for (let fault in [ "empty", "unknown", "multiple", "invalid", "duplicate", "cycle", "bytes", "count", "depth", "directory", "changed", "close" ]) {
        let root = fixture(), value = reply(); value.dnsmasq.instances.cfg01.pid = 43;
        supervisor(root, "43", "123 ");
        let path = root + "/proc/43/task/43/children", open = fs.open;
        if (fault == "empty") write(path, "");
        if (fault == "unknown") { fs.unlink(root + "/proc/43/exe"); fs.symlink("/bin/sh", root + "/proc/43/exe"); }
        if (fault == "multiple") {
            stub.real.system("cp -a '" + root + "/proc/123' '" + root + "/proc/124'");
            write(root + "/proc/124/stat", replace(fs.readfile(root + "/proc/123/stat"), "123 (", "124 ("));
            write(path, "123 124 ");
        }
        if (fault == "invalid") write(path, "../123 ");
        if (fault == "duplicate") write(path, "123 123 ");
        if (fault == "cycle") write(path, "43 ");
        if (fault == "bytes") write(path, sprintf("%4097s", "x"));
        if (fault == "count") { let pids = []; for (let i = 100; i < 117; i++) push(pids, "" + i); write(path, join(" ", pids)); }
        if (fault == "depth") { write(path, "44 "); supervisor(root, "44", "45 "); supervisor(root, "45", "46 "); supervisor(root, "46", "123 "); }
        if (fault == "directory") fs.chmod(root + "/sbin", 0777);
        if (fault == "changed" || fault == "close") fs.open = (name, mode) => {
            let file = open(name, mode);
            if (file == null || name != (fault == "close" ? path : root + "/etc/dnsmasq.conf")) return file;
            return { fileno: () => file.fileno(), error: () => file.error(), close: () => { let closed = file.close(); return fault == "close" ? false : closed; },
                read: (count) => { let data = file.read(count); if (fault == "changed") write(path, ""); return data; } };
        };
        let result, error;
        try { result = collect(root, value); } catch (e) { error = e; }
        fs.open = open; if (error != null) die(error);
        t.eq(result.state, "incomplete", fault); t.excludes(sprintf("%J", result), "synthetic-private");
        if (fault == "count" || fault == "depth") t.eq(result.reason, "dns-runtime-supervisor-limit");
        if (fault == "cycle") t.eq(result.reason, "dns-runtime-supervisor-cycle");
        if (fault == "multiple") t.eq(result.reason, "dns-runtime-child-ambiguous");
    }
});

t.done();
