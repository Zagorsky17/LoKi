// Real temporary files; nft and logging are intercepted before any system change.
let t = require("t");
let fs = require("fs");
let stub = require("stub");
let fixture = require("fixture");
let common = require("core.common");
let exec = require("core.exec");
let rulesets = require("singbox.rulesets");
let sync = require("nft.ruleset_sync");
let nft_sections = require("nft.sections");
let serial = 0;

function exercise(options) {
    let nonce = ++serial;
    let base = sprintf("/tmp/loki-ruleset-sync.%d.123456.%d", common.own_pid(), nonce);
    let old_path = sprintf("/tmp/loki-ruleset-sync.123456.%d.nft", nonce);
    t.eq(fs.lstat(base), null);
    t.eq(fs.lstat(old_path), null);
    let dir = stub.tmpdir();
    let victim = dir + "/victim";
    fs.writefile(victim, "preserved synthetic data");
    let section = { ".name": "file_case_" + nonce, enabled: "1", action: "connection",
        rule_set_with_subnets: [ "https://example.invalid/test.srs" ] };
    fixture.seed({ settings: { config_path: "/not-read-by-sync" }, section: [ section ] });
    let provider = { revision: 1, ip_cidr: { digest: "one", ipv4: [ "192.0.2.1/32" ],
        ipv6: [], scoped_ipv4: [], scoped_ipv6: [] } };
    let snapshot = { revision: 1, providers: { [rulesets.custom_reference_tag(section.rule_set_with_subnets[0])]: provider } };
    if (options?.legacy)
        t.eq(exec.status([ "ln", "-s", victim, old_path ]), 0);
    if (options?.collision == "directory") {
        fs.mkdir(base, 0700);
        fs.writefile(base + "/keep", "preserved");
    }
    else if (options?.collision == "file")
        fs.writefile(base, "preserved");
    else if (options?.collision)
        t.eq(exec.status([ "ln", "-s", options.collision == "dangling" ? dir + "/absent" : options.collision == "directory_link" ? dir : victim, base ]), 0);

    let open = fs.open, stat = fs.stat;
    let failure = options?.failure ?? "";
    let opened = [], transactions = [], modes = [], logs = [];
    fs.open = (path, mode) => {
        if (index(path, "/tmp/loki-ruleset-sync.") != 0)
            return open(path, mode);
        if (failure == "open")
            return null;
        let file = open(path, mode);
        if (!file)
            return null;
        push(opened, file);
        let logical = 0;
        return {
            write: (text) => {
                if (failure == "write_null") return null;
                if (failure == "write_short") return file.write(substr(text, 0, length(text) - 1));
                logical += length(text);
                if (failure == "buffered_loss") {
                    if (index(text, "flush set ") == 0) file.write(text);
                    return length(text);
                }
                return file.write(text);
            },
            tell: () => failure == "tell" ? null : failure == "buffered_loss" ? logical : file.tell(),
            close: () => { let closed = file.close(); return failure == "close" ? null : closed; }
        };
    };
    fs.stat = (path) => failure == "stat" && index(path, "/tmp/loki-ruleset-sync.") == 0 ? null : stat(path);
    global.clock = () => [ 123456, nonce ];
    stub.commands([
        [ "nft -f", (argv) => {
            push(transactions, fs.readfile(argv[2]));
            push(modes, (stat(base)?.mode ?? 0) & 0777);
            return { status: options?.nft_status ?? 0 };
        } ],
        stub.logger(logs)
    ]);
    let descriptors = nft_sections.with_priority_sets([ section ]).sections;
    let result = sync.sync(snapshot, descriptors);
    let recovered = null;
    if (options?.recover) {
        failure = "";
        provider.ip_cidr.digest = "two";
        provider.ip_cidr.ipv4 = [ "198.51.100.1/32" ];
        recovered = sync.sync(snapshot, descriptors);
    }
    else if (options?.repeat)
        recovered = sync.sync(snapshot, descriptors);
    stub.restore();
    fs.open = open;
    fs.stat = stat;
    for (let file in opened) file.close();
    let observation = { result, recovered, transactions, modes, logs, opened: length(opened),
        victim: fs.readfile(victim), old_link: fs.readlink(old_path) == victim,
        left: fs.lstat(base), collision_file: options?.collision == "file" ? fs.readfile(base) : null,
        kept: options?.collision == "directory" ? fs.readfile(base + "/keep") : null };
    fs.unlink(old_path);
    if (options?.collision == "directory") { fs.unlink(base + "/keep"); fs.rmdir(base); }
    else if (options?.collision) fs.unlink(base);
    else { fs.unlink(base + "/transaction.nft"); fs.rmdir(base); }
    return observation;
}

t.test("a complete private transaction applies once and is removed", () => {
    let value = exercise({ repeat: true });
    t.eq(value.result.written, 1);
    t.eq(value.recovered.written, 0);
    t.eq(length(value.transactions), 1);
    t.contains(value.transactions[0], "192.0.2.1/32");
    t.eq(value.modes, [ 0700 ]);
    t.eq(value.left, null);
});

t.test("the legacy shared-path symlink and its target are untouched", () => {
    let value = exercise({ legacy: true });
    t.eq(value.result.written, 1);
    t.eq(value.victim, "preserved synthetic data");
    t.ok(value.old_link, "an unrelated legacy-path symlink was removed");
    t.eq(value.left, null);
});

t.test("existing parent paths refuse the transaction before opening or invoking nft", () => {
    for (let collision in [ "directory", "file", "link", "dangling", "directory_link" ]) {
        let value = exercise({ collision });
        t.eq(value.result.written, 0, collision);
        t.eq(value.transactions, [], collision);
        t.eq(value.opened, 0, collision);
        t.ok(value.left != null, collision + " was removed");
        t.eq(value.victim, "preserved synthetic data");
        if (collision == "directory") t.eq(value.kept, "preserved");
        if (collision == "file") t.eq(value.collision_file, "preserved");
    }
});

t.test("failed, short or buffered writes and unknown final size never reach nft", () => {
    for (let failure in [ "open", "write_null", "write_short", "buffered_loss", "tell", "close", "stat" ]) {
        let value = exercise({ failure });
        t.eq(value.result.written, 0, failure);
        t.eq(value.transactions, [], failure);
        t.eq(value.left, null, failure + " left a temporary directory");
        t.eq(length(value.logs), 1, failure);
        t.contains(value.logs[0], "[error]");
    }
});

t.test("a changed valid snapshot recovers after a refused write without applying the failed plan", () => {
    let value = exercise({ failure: "write_null", recover: true });
    t.eq(value.result.written, 0);
    t.eq(value.recovered.written, 1);
    t.eq(length(value.transactions), 1);
    t.contains(value.transactions[0], "198.51.100.1/32");
    t.excludes(value.transactions[0], "192.0.2.1/32");
    t.eq(value.left, null);
});

t.test("nft rejection cleans the private candidate and leaves the key unapplied", () => {
    let value = exercise({ nft_status: 1 });
    t.eq(value.result.written, 0);
    t.eq(length(value.transactions), 1);
    t.eq(value.modes, [ 0700 ]);
    t.eq(value.left, null);
});

t.done();
