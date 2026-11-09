let t = require("t"), fs = require("fs"), stub = require("stub");
let services = require("service.preflight_services"), exec = require("core.exec");
exec.deadline = (argv, seconds, limit) => exec.combined(argv, limit);
function fixture(name) {
    let root = stub.tmpdir(); fs.chmod(root, 0755);
    stub.real.system("umask 022; mkdir -p '" + root + "/etc/init.d' '" + root + "/etc/rc.d'");
    fs.writefile(root + "/etc/init.d/" + name, "#!/bin/sh\n# synthetic-private-body\n");
    fs.chmod(root + "/etc/init.d/" + name, 0755);
    return root;
}
function proof(root, name) {
    let inventory = services.hook_inventory(root);
    return { complete: true, system: true, own: {}, claims: { ["/etc/init.d/" + name]: [ "netifd" ] }, token: inventory.token };
}
function run(root, provenance, first, second) {
    let reads = 0;
    stub.commands([[ "/usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C ubus", () => {
        return { stdout: sprintf("%J", ++reads == 1 ? first : second ?? first) };
    } ]]);
    let rows, error;
    try { rows = services.collect(root, provenance); } catch (e) { error = e; }
    stub.restore(); if (error != null) die(error);
    t.excludes(sprintf("%J", rows), "synthetic-private");
    t.excludes(sprintf("%J", rows), root);
    return rows;
}
function origin(rows) {
    let result = filter(rows, (row) => row.object == "registration-origin");
    t.eq(length(result), 1, "registration origin must be reported");
    return result[0];
}
function active() { return { instances: { main: { running: true, pid: 42, command: [ "synthetic-private-command" ], env: { TOKEN: "synthetic-private-secret" } } } }; }

t.test("stable procd registrations require the existing verified init-file ownership", () => {
    let root = fixture("network"), provenance = proof(root, "network"), snapshot = { network: active() };
    t.eq(origin(run(root, provenance, snapshot)).state, "checked");
    for (let fault in [ "missing", "foreign", "double", "partial", "system", "unsafe" ]) {
        let candidate = { ...provenance, claims: { ...provenance.claims } };
        if (fault == "missing") delete candidate.claims["/etc/init.d/network"];
        if (fault == "foreign") candidate.claims["/etc/init.d/network"] = [ "podkop" ];
        if (fault == "double") candidate.claims["/etc/init.d/network"] = [ "netifd", "podkop" ];
        if (fault == "partial") candidate.complete = false;
        if (fault == "system") candidate.system = false;
        if (fault == "unsafe") fs.chmod(root + "/etc/init.d/network", 0777);
        t.eq(origin(run(root, candidate, snapshot)).state, "incomplete", fault);
    }
});

t.test("own pending registrations need verified own hooks and every active unknown name is checked", () => {
    let root = fixture("loki-state"), provenance = proof(root, "loki-state");
    provenance.claims["/etc/init.d/loki-state"] = [ "loki" ]; provenance.own["/etc/init.d/loki-state"] = true;
    let snapshot = { "loki-state": { triggers: [ [ "synthetic-private-trigger" ] ] } };
    let rows = run(root, provenance, snapshot);
    t.eq(origin(rows).state, "checked");
    t.eq(length(filter(rows, (row) => row.kind == "services" && row.state != "checked")), 0);
    delete provenance.own["/etc/init.d/loki-state"];
    t.eq(origin(run(root, provenance, snapshot)).state, "incomplete");
    for (let name in [ "unknown", "../network", "podkop" ])
        t.eq(origin(run(root, provenance, { [name]: active() })).state, "incomplete");
    t.eq(origin(run(root, provenance, { unknown: {} })).state, "checked", "an inert registration is not a conflict");
    t.eq(origin(run(root, provenance, { unknown: { autostart: true } })).state, "incomplete");
});

t.test("a changed command, service set or unavailable second snapshot preserves refusal", () => {
    let root = fixture("network"), provenance = proof(root, "network"), first = { network: active() };
    let changed = active(); changed.instances.main.command = [ "synthetic-private-changed" ];
    for (let second in [ {}, { network: changed }, { network: { instances: [] } } ])
        t.eq(origin(run(root, provenance, first, second)).state, "incomplete");
});

t.done();
