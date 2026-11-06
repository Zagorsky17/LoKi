let t = require("t");
let fs = require("fs");
let stub = require("stub");
let context = require("service.ruleset_context");
let credential = require("service.gateway_secret");

let sequence = 100;
credential.generate = () => sprintf("%064x", ++sequence);
let token = (number) => sprintf("%064x", number);

function fixture() {
    let root = stub.tmpdir();
    fs.chmod(root, 0755);
    context.paths.base = root + "/runtime";
    t.ok(context.ensure());
    return root + "/runtime/rulesets";
}

function candidate(number) {
    let name = "main";
    let sets = {};
    for (let suffix in [ "subnets", "subnets6", "ip_ports", "ip6_ports", "proto_ports", "proto6_ports" ])
        sets[suffix] = "loki_rule_" + name + "_" + suffix;
    return { generation: token(number), sections: [
        { section: { ".name": name }, matchers: { subnets: "192.0.2.0/24,2001:db8::/64", ports: "80,443-445",
            subnet_tags: [ "inline-custom-0123456789ab-ruleset" ], sets } }
    ], controller: { endpoint: "/tmp/loki/controller.sock", secret: token(90) },
        config_path: "/etc/loki-core/config.json", config_digest: token(91), nft_digest: token(92) };
}

function ready(value, pid) {
    return { ...value, pid: pid ?? "123", start_ticks: "456",
        command: [ "/usr/bin/loki-core", "run", "-c", value.config_path ] };
}

function applying(value, active) {
    return { schema: 1, phase: "applying", active: active ?? null, candidate: value };
}

function committed(value) {
    return { schema: 1, phase: "ready", active: ready(value), candidate: null };
}

t.test("only a completed applying generation can become ready in private storage", () => {
    let directory = fixture();
    t.eq(context.read().error, "ruleset-context-missing");
    let first = candidate(1);
    t.eq(context.write(committed(first)), false);
    t.ok(context.write(applying(first)));
    let loaded = context.read();
    t.eq(loaded.model.phase, "applying");
    t.eq(loaded.model.candidate.generation, token(1));
    t.ok(context.write(committed(first)));
    t.eq(context.read().model.active.generation, token(1));
    t.eq(fs.stat(directory + "/context.json").mode & 07777, 0600);
    t.eq(fs.stat(directory).mode & 07777, 0700);
    t.eq(fs.stat(context.paths.base).mode & 07777, 0700);
    t.eq(fs.lsdir(directory), [ "context.json" ]);
});

t.test("mixed or reused generations cannot replace a confirmed context", () => {
    fixture();
    let first = candidate(1), second = candidate(2);
    t.ok(context.write(applying(first)));
    t.ok(context.write(committed(first)));
    let before = fs.readfile(context.paths.base + "/rulesets/context.json");
    t.eq(context.write(applying(first, ready(first))), false);
    t.eq(context.write(committed(second)), false);
    t.eq(fs.readfile(context.paths.base + "/rulesets/context.json"), before);
    t.ok(context.write(applying(second, ready(first))));
    let altered = candidate(2);
    altered.sections[0].matchers.ports = "8080";
    t.eq(context.write(committed(altered)), false);
    t.eq(context.read().model.phase, "applying");
    t.ok(context.write(committed(second)));
    t.ok(context.write({ schema: 1, phase: "stopped", active: null, candidate: null }));
    t.eq(context.read().model.phase, "stopped");
});

t.test("a pinned ready file becomes stale after atomic replacement", () => {
    fixture();
    let value = candidate(1);
    t.ok(context.write(applying(value)));
    t.ok(context.write(committed(value)));
    let pinned = context.open();
    t.eq(pinned.error, null);
    t.ok(context.unchanged(pinned));
    t.ok(context.write(applying(candidate(2), ready(value))));
    t.eq(context.unchanged(pinned), false);
    t.ok(context.close(pinned));
    t.eq(context.unchanged(pinned), false);
});

t.test("malformed and foreign context files remain untouched without exposing their contents", () => {
    let directory = fixture();
    let path = directory + "/context.json";
    fs.writefile(path, "SYNTHETIC_PRIVATE_FOREIGN\n");
    fs.chmod(path, 0600);
    let captured = stub.capture(() => context.read());
    t.eq(captured.stdout, "");
    t.eq(captured.stderr, "");
    t.eq(context.read().error, "ruleset-context-invalid");
    t.eq(context.write(applying(candidate(1))), false);
    t.eq(fs.readfile(path), "SYNTHETIC_PRIVATE_FOREIGN\n");
    fs.chmod(path, 0644);
    t.eq(context.open().error, "ruleset-context-unavailable");
});

t.test("symlinks and unsafe private directories are refused without repairing foreign objects", () => {
    let directory = fixture();
    let victim = stub.tmpdir() + "/victim";
    fs.writefile(victim, "foreign-data");
    fs.symlink(victim, directory + "/context.json");
    t.eq(context.write(applying(candidate(1))), false);
    t.eq(fs.readfile(victim), "foreign-data");
    t.eq(fs.lstat(directory + "/context.json").type, "link");
    fs.unlink(directory + "/context.json");
    fs.chmod(directory, 0755);
    t.eq(context.ensure(), false);
    t.eq(fs.stat(directory).mode & 0777, 0755);
});

t.test("corrupt JSON framing and decoded NUL values never become a trusted document", () => {
    fixture();
    let value = candidate(1);
    t.ok(context.write(applying(value)));
    let path = context.paths.base + "/rulesets/context.json";
    let valid = fs.readfile(path);
    for (let data in [ "", "null", "[]", valid + "{}", valid + "/* private */",
        replace(valid, '"schema":1', '"schema":1,"schema":1'), valid + "\u0000" ])
        t.ok(context.parse(data).error != null);
    for (let key in [ "config_path", "generation", "config_digest" ]) {
        let changed = candidate(1);
        changed[key] += "\u0000private";
        t.eq(context.write(applying(changed)), false);
    }
    t.eq(fs.readfile(path), valid);
});

t.test("depth and token bounds refuse data before the native JSON decoder", () => {
    let decode = global.json;
    let calls = 0;
    global.json = (data) => { calls++; return decode(data); };
    let deep = "0";
    for (let i = 0; i < 20; i++) deep = "[" + deep + "]";
    let many = "null";
    for (let i = 0; i < 19; i++) many = many + "," + many;
    let header = '{"schema":1,"write_id":"' + token(1) + '","phase":"ready","active":';
    let results = [ context.parse(header + deep + ',"candidate":null}\n'),
        context.parse(header + "[" + many + '],"candidate":null}\n') ];
    global.json = decode;
    t.eq(calls, 0);
    for (let result in results) t.ok(result.error != null);
    t.eq(context.parse(sprintf("%4194305s", "")).error, "ruleset-context-size-limit");
});

t.test("read and close failures refuse a snapshot and explicitly close its file", () => {
    let directory = fixture();
    let value = candidate(1);
    t.ok(context.write(applying(value)));
    let original = fs.open;
    for (let failure in [ "read", "error", "close-false", "close-throw" ]) {
        let closes = 0;
        fs.open = (path, mode) => {
            let file = original(path, mode);
            if (path != directory + "/context.json") return file;
            return { fileno: () => file.fileno(),
                read: (n) => { if (failure == "read") die("SYNTHETIC_PRIVATE_READ"); return file.read(n); },
                error: () => failure == "error" ? "SYNTHETIC_PRIVATE_IO" : file.error(),
                close: () => { closes++; file.close();
                    if (failure == "close-throw") die("SYNTHETIC_PRIVATE_CLOSE");
                    return failure != "close-false"; } };
        };
        let result = stub.capture(() => context.read());
        fs.open = original;
        t.eq(result.result.error, "ruleset-context-unavailable", failure);
        t.eq(closes, 1, failure);
        t.eq(result.stdout + result.stderr, "", failure);
        t.eq(context.read().model.phase, "applying", failure + " can be retried");
    }
});

t.test("an unrelated earlier filesystem failure does not poison a complete context read", () => {
    fixture();
    t.ok(context.write(applying(candidate(1))));
    fs.lstat(context.paths.base + "/missing-object");
    t.eq(context.read().model?.phase, "applying");
});

t.test("failed rename preserves ready state and removes only the created temporary", () => {
    let directory = fixture();
    let value = candidate(1);
    t.ok(context.write(applying(value)));
    t.ok(context.write(committed(value)));
    let before = fs.readfile(directory + "/context.json");
    let rename = fs.rename;
    for (let failure in [ "false", "throw" ]) {
        fs.rename = () => { if (failure == "throw") die("SYNTHETIC_RENAME"); return false; };
        let result = stub.capture(() => context.write(applying(candidate(2), ready(value))));
        fs.rename = rename;
        t.eq(result.result, false);
        t.eq(result.stdout + result.stderr, "");
        t.eq(fs.readfile(directory + "/context.json"), before);
        t.eq(fs.lsdir(directory), [ "context.json" ]);
    }
    t.ok(context.write(applying(candidate(2), ready(value))));
});

t.test("temporary collection preserves foreign names, links and unmatched headers", () => {
    let directory = fixture();
    let owned = directory + "/.context-" + token(500) + ".tmp";
    let foreign = directory + "/.context-" + token(501) + ".tmp";
    let linked = directory + "/.context-" + token(502) + ".tmp";
    let header = '{"schema":1,"write_id":"' + token(500) + '","phase":';
    fs.writefile(owned, header + '"applying"');
    fs.writefile(foreign, "foreign sentinel");
    fs.chmod(owned, 0600);
    fs.chmod(foreign, 0600);
    fs.symlink(foreign, linked);
    t.ok(context.write(applying(candidate(1))));
    t.eq(fs.lstat(owned), null);
    t.eq(fs.readfile(foreign), "foreign sentinel");
    t.eq(fs.lstat(linked).type, "link");
});

t.test("a hardlinked context is preserved and refused for reads and replacement", () => {
    let directory = fixture();
    t.ok(context.write(applying(candidate(1))));
    let path = directory + "/context.json";
    let before = fs.readfile(path);
    let extra = directory + "/second-link";
    t.eq(stub.real.system(require("core.exec").command_line([ "ln", path, extra ])), 0);
    t.eq(context.read().error, "ruleset-context-unavailable");
    t.eq(context.write(committed(candidate(1))), false);
    t.eq(fs.readfile(path), before);
    t.eq(fs.readfile(extra), before);
    t.eq(fs.lstat(path).nlink, 2);
});

t.test("a changed private parent before rename cannot replace the prior ready file", () => {
    let directory = fixture();
    let value = candidate(1);
    t.ok(context.write(applying(value)));
    t.ok(context.write(committed(value)));
    let before = fs.readfile(directory + "/context.json");
    let original = { open: fs.open, lstat: fs.lstat };
    let created = false;
    fs.open = (path, mode, permissions) => {
        let file = original.open(path, mode, permissions);
        if (file != null && index(path, directory + "/.context-") == 0) created = true;
        return file;
    };
    fs.lstat = (path) => {
        let stat = original.lstat(path);
        return path == directory && created ? { ...stat, inode: stat.inode + 1 } : stat;
    };
    let result = context.write(applying(candidate(2), ready(value)));
    fs.open = original.open; fs.lstat = original.lstat;
    t.eq(result, false);
    t.eq(fs.readfile(directory + "/context.json"), before);
    t.eq(fs.lsdir(directory), [ "context.json" ]);
});

t.done();
