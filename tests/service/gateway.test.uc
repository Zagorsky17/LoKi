let t = require("t");
let fs = require("fs");
let stub = require("stub");
let fixture = require("fixture");
let uci = require("uci");
let ubus = require("ubus");
let common = require("core.common");
let storage = require("core.cache_path");
let secret = require("service.gateway_secret");
let gateway = require("service.gateway");

function seed(options) {
    options ??= {};
    fixture.seed({ settings: options.settings ?? {} });
    uci.__seed("uhttpd", [ { ".name": "main", ".type": "uhttpd", cert: "/etc/uhttpd.crt", key: "/etc/uhttpd.key",
        listen_https: [ "0.0.0.0:443", "[::]:443", "127.0.0.1:8443" ], ...(options.http ?? {}) } ]);
    uci.__seed("system", [ { ".type": "system", hostname: options.hostname ?? "Router" } ]);
    uci.__seed("dhcp", [ { ".type": "dnsmasq", domain: options.domain ?? "lan" } ]);
    ubus.__reset();
    ubus.__on("network.interface.lan.status", options.status ?? { up: true,
        "ipv4-address": [ { address: "192.0.2.1", mask: 24 }, { address: "192.0.2.2", mask: 24 } ] });
}

function isolated(fn) {
    seed();
    let directory = stub.tmpdir() + "/private";
    t.ok(fs.mkdir(directory, 0700));
    let path = directory + "/gateway.json";
    let original = { ensure: storage.ensure, secret: secret.load };
    let loads = 0;
    let paths = [];
    storage.ensure = (settings) => {
        push(paths, settings);
        return original.ensure({ cache_path: path });
    };
    secret.load = () => { loads++; return fixture.CONTROLLER_SECRET; };
    let error;
    try { fn(path, () => loads, paths); }
    catch (e) { error = e; }
    storage.ensure = original.ensure;
    secret.load = original.secret;
    if (error != null)
        die(error.message);
}

t.test("root-owned LAN and HTTPS settings produce a bounded private configuration without credentials", () => {
    seed();
    t.eq(gateway.configuration(), { format: "loki-gateway-1", listen: [ "192.0.2.1:9091", "192.0.2.2:9091" ],
        hosts: [ "192.0.2.1", "192.0.2.2", "router", "router.lan" ], luci_https_ports: [ 443, 8443 ],
        certificate: "/etc/uhttpd.crt", key: "/etc/uhttpd.key" });
    t.eq(ubus.__calls(), [ { object: "network.interface.lan", method: "status", args: {} } ]);
    t.eq(uci.__commits(), []);
    seed({ settings: { service_listen_address: "192.0.2.2" }, http: { listen_https: "[::]:443" }, hostname: "", domain: "" });
    t.eq(gateway.configuration().listen, [ "192.0.2.2:9091" ]);
    t.eq(gateway.configuration().hosts, [ "192.0.2.1", "192.0.2.2" ]);
});

t.test("missing or unready LAN never falls back to wildcard, WAN or external discovery", () => {
    for (let status in [ {}, { up: false, "ipv4-address": [] }, { up: true, "ipv4-address": [] },
        { up: true, "ipv4-address": "192.0.2.1" }, { up: true, "ipv4-address": [ { address: "127.0.0.1" } ] },
        { up: true, "ipv4-address": [ { address: "224.0.0.1" } ] }, { up: true, "ipv4-address": [ { address: "192.000.2.1" } ] } ]) {
        seed({ status });
        t.throws(() => gateway.configuration());
    }
    for (let address in [ "0.0.0.0", "198.51.100.1", "[::]", "192.0.2.1;echo canary" ]) {
        seed({ settings: { service_listen_address: address } });
        t.throws(() => gateway.configuration());
    }
    seed();
    ubus.__refuse_connections();
    t.throws(() => gateway.configuration());
});

t.test("dual-stack LAN uses assigned host addresses, not delegated prefixes or wildcard binds", () => {
    seed({ status: { up: true,
        "ipv4-address": [ { address: "192.0.2.1" } ],
        "ipv6-address": [ { address: "FD00:0:0:0:0:0:0:1" }, { address: "fe80::1" } ],
        "ipv6-prefix-assignment": [ { address: "2001:db8:1::", "local-address": { address: "2001:db8:1::1" } },
            { address: "fd00::", "local-address": { address: "fd00::1" } }, { address: "2001:db8:2::" } ] } });
    t.eq(gateway.configuration().listen, [ "192.0.2.1:9091", "[fd00::1]:9091", "[2001:db8:1::1]:9091" ]);
    t.eq(gateway.configuration().hosts, [ "192.0.2.1", "fd00::1", "2001:db8:1::1", "router", "router.lan" ]);
    seed({ status: { up: true, "ipv6-address": [ { address: "fd00::1" } ] } });
    t.eq(gateway.configuration().listen, [ "[fd00::1]:9091" ]);
    seed({ settings: { service_listen_address: "FD00:0:0:0:0:0:0:1" }, status: { up: true,
        "ipv4-address": [ { address: "192.0.2.1" } ], "ipv6-address": [ { address: "fd00::1" } ] } });
    t.eq(gateway.configuration().listen, [ "[fd00::1]:9091" ]);
    t.eq(uci.__commits(), []);
});

t.test("malformed, unscoped and excessive IPv6 state cannot widen the gateway bind", () => {
    for (let entry in [ { address: "::" }, { address: "::1" }, { address: "ff02::1" },
        { address: "::ffff:192.0.2.1" }, { address: "fe80::1%br-lan" }, { address: "fd00::gg" }, {} ]) {
        seed({ status: { up: true, "ipv4-address": [ { address: "192.0.2.1" } ], "ipv6-address": [ entry ] } });
        t.throws(() => gateway.configuration());
    }
    for (let status in [ { "ipv6-address": "fd00::1" }, { "ipv6-prefix-assignment": {} },
        { "ipv6-prefix-assignment": [ { "local-address": "fd00::1" } ] },
        { "ipv6-prefix-assignment": [ { "local-address": { address: "::" } } ] },
        { "ipv6-address": [ { address: "fe80::1" } ] } ]) {
        seed({ status: { up: true, ...status } });
        t.throws(() => gateway.configuration());
    }
    let entries = [];
    for (let i = 1; i <= 17; i++)
        push(entries, { address: "fd00::" + i });
    seed({ status: { up: true, "ipv6-address": entries } });
    t.throws(() => gateway.configuration());
    seed({ status: { up: true, "ipv6-address": slice(entries, 0, 16) } });
    t.throws(() => gateway.configuration(), "names and both address families share the host ceiling");
});

t.test("TLS is required and malformed shared configuration is refused without repair", () => {
    for (let http in [ { cert: "" }, { key: "" }, { cert: "relative.pem" }, { key: "/etc/../tmp/key" },
        { cert: "/etc//cert" }, { key: "/etc/key\ncanary" }, { listen_https: [] }, { listen_https: "443" },
        { listen_https: [ "localhost:443" ] }, { listen_https: [ "0.0.0.0:0" ] },
        { listen_https: [ "0.0.0.0:65536" ] }, { listen_https: [ "[::gg]:443" ] } ]) {
        seed({ http });
        t.throws(() => gateway.configuration());
        t.eq(uci.__commits(), []);
    }
    for (let options in [ { hostname: "router.evil/" }, { hostname: "-router" }, { hostname: "192.0.2.9" },
        { domain: "lan\r\ncanary" }, { domain: ".lan" } ]) {
        seed(options);
        t.throws(() => gateway.configuration());
    }
});

t.test("address, host, listener and port counts have actual resource ceilings", () => {
    let addresses = [];
    for (let i = 1; i <= 17; i++)
        push(addresses, { address: "192.0.2." + i });
    seed({ status: { up: true, "ipv4-address": addresses } });
    t.throws(() => gateway.configuration());
    seed({ status: { up: true, "ipv4-address": slice(addresses, 0, 16) } });
    t.throws(() => gateway.configuration(), "two names must not overrun the combined host ceiling");
    let listeners = [];
    for (let i = 1; i <= 17; i++)
        push(listeners, "0.0.0.0:" + i);
    seed({ http: { listen_https: listeners } });
    t.throws(() => gateway.configuration());
    seed({ http: { listen_https: slice(listeners, 0, 9) } });
    t.throws(() => gateway.configuration());
    seed({ http: { listen_https: slice(listeners, 0, 8) } });
    t.eq(length(gateway.configuration().luci_https_ports), 8);
});

t.test("first preparation and repeated preparation publish only private recognized state", () => {
    isolated((path, loads, paths) => {
        let first = gateway.prepare();
        t.eq(json(fs.readfile(path)), first);
        t.eq(fs.lstat(path).mode & 0777, 0600);
        t.excludes(fs.readfile(path), fixture.CONTROLLER_SECRET);
        t.eq(gateway.prepare(), first);
        t.eq(loads(), 2);
        t.eq(paths, [ { cache_path: "/tmp/loki/gateway.json" }, { cache_path: "/tmp/loki/gateway.json" } ]);
        t.eq(uci.__commits(), []);
    });
});

t.test("unknown, corrupt and insecure prior state is preserved without being overwritten", () => {
    for (let value in [ "", "{}", "not-json", '{"format":"other"}', sprintf("%16385s", "") ]) {
        isolated((path) => {
            t.ok(common.write_private_file(path, value));
            t.throws(() => gateway.prepare());
            t.eq(fs.readfile(path), value);
        });
    }
    isolated((path) => {
        let value = sprintf("%J", gateway.prepare());
        t.eq(fs.readfile(path), value);
        fs.chmod(path, 0644);
        t.throws(() => gateway.prepare());
        t.eq(fs.readfile(path), value);
        t.eq(fs.lstat(path).mode & 0777, 0644);
    });
    isolated((path) => {
        let keep = path + ".keep";
        fs.writefile(keep, "untouched");
        fs.symlink(keep, path);
        t.throws(() => gateway.prepare());
        t.eq(fs.readfile(keep), "untouched");
        t.eq(fs.lstat(path).type, "link");
    });
});

t.test("preparation failures preserve the last usable configuration and do not reveal credentials", () => {
    isolated((path) => {
        gateway.prepare();
        let old = fs.readfile(path);
        seed({ http: { cert: "" } });
        t.throws(() => gateway.prepare());
        t.eq(fs.readfile(path), old);
        seed();
        let original = common.write_file_atomic;
        common.write_file_atomic = () => false;
        let result = stub.capture(() => t.throws(() => gateway.prepare()));
        common.write_file_atomic = original;
        t.contains(result.result.message, "cannot publish its private configuration");
        t.excludes(result.stdout + result.stderr + result.result.message, fixture.CONTROLLER_SECRET);
        t.eq(fs.readfile(path), old);
    });
});

t.test("ubus inspection has a fixed timeout and a failed disconnect denies preparation", () => {
    seed();
    let original = ubus.connect;
    let arguments;
    ubus.connect = (socket, timeout) => { arguments = [ socket, timeout ]; return original(); };
    let error;
    try { gateway.configuration(); }
    catch (e) { error = e; }
    ubus.connect = original;
    if (error != null)
        die(error.message);
    t.eq(arguments, [ null, 2 ]);
    ubus.connect = () => {
        let connection = original();
        connection.disconnect = () => die("synthetic-private-canary");
        return connection;
    };
    error = null;
    try { gateway.configuration(); }
    catch (e) { error = e; }
    ubus.connect = original;
    t.contains(error?.message, "LAN status is unavailable");
    t.excludes(error.message, "synthetic-private-canary");
});

t.test("private configuration metadata changes during reading refuse replacement", () => {
    for (let changed in [
        (s) => ({ inode: s.inode + 1 }), (s) => ({ dev: { ...s.dev, major: s.dev.major + 1 } }),
        (s) => ({ dev: { ...s.dev, minor: s.dev.minor + 1 } }), (s) => ({ uid: s.uid + 1 }),
        (s) => ({ nlink: 2 }), (s) => ({ mode: 0644 }), (s) => ({ size: 1 }),
        (s) => ({ mtime: s.mtime + 1 }), (s) => ({ ctime: s.ctime + 1 })
    ]) {
        isolated((path) => {
            gateway.prepare();
            let old = fs.readfile(path);
            let original = { open: fs.open, stat: fs.lstat };
            let opened = false;
            fs.open = (name, mode, permissions) => {
                let file = original.open(name, mode, permissions);
                if (name == path && mode == "re")
                    opened = true;
                return file;
            };
            fs.lstat = (name) => {
                let value = original.stat(name);
                return opened && name == path ? { ...value, ...changed(value) } : value;
            };
            let error;
            try { gateway.prepare(); }
            catch (e) { error = e; }
            fs.open = original.open;
            fs.lstat = original.stat;
            t.contains(error?.message, "existing private configuration is unrecognized or changed");
            t.eq(fs.readfile(path), old);
        });
    }
});

t.done();
