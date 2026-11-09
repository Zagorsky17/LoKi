let t = require("t"), fs = require("fs"), stub = require("stub");
let services = require("service.preflight_services"), exec = require("core.exec");
exec.deadline = (argv, seconds, limit) => exec.combined(argv, limit);
function write(path, text, mode) { fs.writefile(path, text); fs.chmod(path, mode ?? 0644); }
function fixture() {
    let root = stub.tmpdir(); fs.chmod(root, 0755);
    stub.real.system("umask 022; mkdir -p '" + root + "/etc/init.d' '" + root + "/etc/rc.d' '" + root + "/etc/hotplug.d/iface' '" + root + "/etc/uci-defaults'");
    write(root + "/etc/init.d/network", "#!/bin/sh\n# synthetic-private-init\n", 0755);
    fs.symlink("../init.d/network", root + "/etc/rc.d/S20network");
    write(root + "/etc/hotplug.d/iface/20-network", "# synthetic-private-hotplug\n");
    write(root + "/etc/uci-defaults/10-stock", "# synthetic-private-defaults\n", 0755);
    write(root + "/etc/rc.local", "# user configuration\nexit 0\n");
    return root;
}
function proof(root) {
    let inventory = services.hook_inventory(root), claims = {};
    for (let path in inventory.paths) claims[path] = [ index(path, "network") >= 0 ? "netifd" : "base-files" ];
    return { complete: inventory.error == null, system: true, own: {}, claims, token: inventory.token };
}
function collect(root, provenance) {
    stub.commands([[ "/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C ubus", { stdout: "{}" } ]]);
    let result, error;
    try { result = services.collect(root, provenance); } catch (e) { error = e; }
    stub.restore(); if (error != null) die(error);
    return filter(result, (row) => row.kind == "hooks" || row.kind == "autostart");
}
function has(rows, reason, state) { return length(filter(rows, (row) => row.reason == reason && (state == null || row.state == state))) > 0; }

t.test("stock package claims and explicit own content admit hooks without running their bodies", () => {
    let root = fixture(), provenance = proof(root), result = collect(root, provenance);
    t.eq(length(filter(result, (row) => row.state != "checked")), 0);
    t.ok(has(result, "trusted-system-hook-checked")); t.ok(has(result, "startup-local-inert"));
    t.excludes(sprintf("%J", result), "synthetic-private"); t.excludes(sprintf("%J", result), root);
    write(root + "/etc/init.d/loki", "# synthetic-private-own\n", 0755);
    fs.symlink("../init.d/loki", root + "/etc/rc.d/S99loki"); provenance = proof(root);
    provenance.claims["/etc/init.d/loki"] = [ "loki" ]; provenance.own["/etc/init.d/loki"] = true;
    t.ok(has(collect(root, provenance), "hook-own-content-checked"));
    delete provenance.own["/etc/init.d/loki"];
    t.ok(has(collect(root, provenance), "hook-package-origin-unverified", "incomplete"));
});

t.test("foreign or ambiguous hooks, missing database coverage and an untrusted system remain incomplete", () => {
    for (let fault in [ "foreign", "double", "missing", "partial", "system" ]) {
        let root = fixture(), provenance = proof(root);
        if (fault == "foreign") provenance.claims["/etc/hotplug.d/iface/20-network"] = [ "podkop" ];
        if (fault == "double") provenance.claims["/etc/init.d/network"] = [ "netifd", "podkop" ];
        if (fault == "missing") delete provenance.claims["/etc/uci-defaults/10-stock"];
        if (fault == "partial") provenance.complete = false;
        if (fault == "system") provenance.system = false;
        let result = collect(root, provenance);
        t.ok(length(filter(result, (row) => row.state == "incomplete")) > 0, fault);
        t.excludes(sprintf("%J", result), "synthetic-private");
        t.eq(fs.readfile(root + "/etc/hotplug.d/iface/20-network"), "# synthetic-private-hotplug\n");
    }
});

t.test("arbitrary rc.local commands and executable regular rc entries cannot borrow an absent init proof", () => {
    let root = fixture(); write(root + "/etc/rc.local", "echo synthetic-private-command\n");
    let result = collect(root, proof(root)); t.ok(has(result, "startup-local-unverified", "incomplete"));
    t.excludes(sprintf("%J", result), "synthetic-private");
    write(root + "/etc/rc.local", "# inert\nreturn 0\n");
    write(root + "/etc/rc.d/S98unknown", "echo synthetic-private-command\n", 0755);
    result = collect(root, proof(root)); t.ok(has(result, "hook-package-owner-unverified", "incomplete"));
});

t.test("unsafe and changed hook snapshots refuse even when package names remain trusted", () => {
    for (let fault in [ "mode", "link", "hardlink", "directory", "changed", "added" ]) {
        let root = fixture(), provenance = proof(root), path = root + "/etc/hotplug.d/iface/20-network";
        if (fault == "mode") fs.chmod(path, 0666);
        if (fault == "link") { fs.rename(path, path + ".keep"); fs.symlink(path + ".keep", path); }
        if (fault == "hardlink") stub.real.system("ln '" + path + "' '" + path + ".keep'");
        if (fault == "directory") fs.chmod(root + "/etc/hotplug.d", 0777);
        if (fault == "changed") write(path, "changed-private-data\n");
        if (fault == "added") write(path + "-new", "private-new-hook\n");
        let result = collect(root, provenance); t.ok(has(result, "hook-inventory-changed-or-unavailable", "incomplete"), fault);
        t.excludes(sprintf("%J", result), "private");
    }
});

t.test("failed closure, entry exhaustion and changes during rc.local reading cannot preserve hook admission", () => {
    for (let fault in [ "close", "entries", "during-read" ]) {
        let root = fixture(), provenance = proof(root), opendir = fs.opendir, open = fs.open;
        if (fault != "during-read") fs.opendir = (path) => {
            let directory = opendir(path); if (path != root + "/etc/hotplug.d/iface" || directory == null) return directory;
            let count = 0;
            return { read: () => fault == "entries" && count++ < 4097 ? "." : directory.read(),
                close: () => { let closed = directory.close(); return fault == "close" ? false : closed; } };
        };
        else fs.open = (path, mode) => {
            let file = open(path, mode); if (path != root + "/etc/rc.local" || file == null) return file;
            return { fileno: () => file.fileno(), error: () => file.error(), close: () => file.close(), read: (count) => {
                let data = file.read(count); write(root + "/etc/hotplug.d/iface/20-network", "changed while reading another file\n"); return data;
            } };
        };
        let result, error;
        try { result = collect(root, provenance); } catch (e) { error = e; }
        fs.opendir = opendir; fs.open = open; if (error != null) die(error);
        t.ok(has(result, "hook-inventory-changed-or-unavailable", "incomplete"), fault);
        t.excludes(sprintf("%J", result), "private");
    }
});

t.test("read access timestamps do not invalidate an otherwise stable protected inventory", () => {
    let root = fixture(), lstat = fs.lstat, reads = 0, result, error;
    fs.lstat = (path) => {
        let node = lstat(path);
        if (node != null && path == root + "/etc/rc.local") node.atime = ++reads;
        return node;
    };
    try { result = collect(root, proof(root)); } catch (e) { error = e; }
    fs.lstat = lstat; if (error != null) die(error);
    t.eq(length(filter(result, (row) => row.state != "checked")), 0);
});

t.test("the stock entropy seed init hook uses its own system package ownership", () => {
    let root = fixture(), target = "/etc/init.d/urandom_seed";
    write(root + target, "#!/bin/sh /etc/rc.common\n# synthetic-private stock entropy hook\n", 0755);
    fs.symlink("../init.d/urandom_seed", root + "/etc/rc.d/S99urandom_seed");
    let provenance = proof(root); provenance.claims[target] = [ "urandom-seed" ];
    t.eq(length(filter(collect(root, provenance), (row) => row.state != "checked")), 0);
    for (let claims in [ [], [ "other" ], [ "urandom-seed", "other" ] ]) {
        let changed = { ...provenance, claims: { ...provenance.claims, [target]: claims } };
        t.ok(length(filter(collect(root, changed), (row) => row.state != "checked")) > 0);
    }
    t.ok(length(filter(collect(root, { ...provenance, system: false }), (row) => row.state != "checked")) > 0);
});

t.done();
