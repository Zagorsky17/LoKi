let t = require("t"), fs = require("fs"), stub = require("stub");
let nft = require("service.preflight_nft");
function write(path, data, mode) { fs.writefile(path, data); fs.chmod(path, mode ?? 0644); }
function fixture() {
    let root = stub.tmpdir(); fs.chmod(root, 0755);
    stub.real.system("umask 022; mkdir -p '" + root + "/etc/nftables.d' '" + root + "/usr/share/nftables.d/chain-pre/input' '" + root + "/usr/share/nftables.d/table-post'");
    return root;
}
function check(root, sections, own_files) {
    let result = nft.persisted(root, sections ?? [], own_files);
    t.excludes(sprintf("%J", result), "synthetic-private");
    t.excludes(sprintf("%J", result), root);
    return result;
}

t.test("empty and inert automatic includes are checked without executing their contents", () => {
    let root = fixture();
    t.eq(check(root).state, "checked");
    write(root + "/etc/nftables.d/10-custom.nft", "# synthetic-private inert\n\n");
    write(root + "/usr/share/nftables.d/chain-pre/input/10-stock.nft", "# inert\n");
    write(root + "/usr/share/nftables.d/chain-pre/README", "not a chain directory\n");
    write(root + "/usr/share/nftables.d/table-post/ignored.txt", "synthetic-private active text\n");
    t.eq(check(root).state, "checked");
    write(root + "/usr/share/nftables.d/table-post/active.nft", "add table inet synthetic-private\n");
    t.eq(check(root).reason, "nft-persisted-active-include-unverified");
    t.eq(check(root, [ { ".type": "defaults", auto_includes: "0" } ]).state, "checked");
    write(root + "/etc/nftables.d/active.nft", "include \"/synthetic-private\"\n");
    t.eq(check(root, [ { ".type": "defaults", auto_includes: "0" } ]).state, "incomplete");
});

t.test("fw4 wildcard includes ignore dot files while explicit includes still inspect them", () => {
    let root = fixture();
    for (let directory in [ "/etc/nftables.d", "/usr/share/nftables.d/table-post", "/usr/share/nftables.d/chain-pre/input" ])
        write(root + directory + "/.hidden.nft", "include \"/synthetic-private\"\n");
    t.eq(check(root).state, "checked");
    let explicit = [ { ".type": "include", type: "nftables", path: "/etc/nftables.d/.hidden.nft" } ];
    t.eq(check(root, explicit).reason, "nft-persisted-active-include-unverified");
});

t.test("disabled and incompatible scripts are inert while enabled scripts and nft text stay unverified", () => {
    let root = fixture(); write(root + "/etc/firewall.user", "echo synthetic-private\n");
    let entry = { ".type": "include", path: "/etc/firewall.user" };
    t.eq(check(root, [ entry ]).state, "checked");
    t.eq(check(root, [ { ...entry, fw4_compatible: "1", enabled: "no" } ]).state, "checked");
    t.eq(check(root, [ { ...entry, fw4_compatible: "yes" } ]).reason, "nft-persisted-active-include-unverified");
    write(root + "/etc/firewall.user", "#!/bin/sh\n# synthetic-private\nexit 0\n");
    t.eq(check(root, [ { ...entry, fw4_compatible: "on" } ]).state, "checked");
    t.eq(check(root, [ { ...entry, type: "nftables" } ]).state, "incomplete");
    t.eq(check(root, [ { ".type": "include", path: "/etc/missing" } ]).state, "checked");
    for (let entry in [ { ".type": "include", path: "../synthetic-private" },
        { ".type": "include", path: "/etc/../synthetic-private" },
        { ".type": "include", path: "/etc/firewall.user", fw4_compatible: "bad" },
        { ".type": "include", enabled: [ "0" ] }, { ".type": "defaults", auto_includes: "bad" } ])
        t.eq(check(root, [ entry ]).state, "incomplete");
});

t.test("unsafe includes, failed closure and changes between reads refuse", () => {
    for (let fault in [ "link", "hardlink", "mode", "directory", "close", "changed", "added" ]) {
        let root = fixture(), path = root + "/etc/nftables.d/10-custom.nft";
        write(path, "# synthetic-private\n");
        let open = fs.open, reads = 0;
        if (fault == "link") { fs.rename(path, path + ".keep"); fs.symlink(path + ".keep", path); }
        if (fault == "hardlink") stub.real.system("ln '" + path + "' '" + path + ".keep'");
        if (fault == "mode") fs.chmod(path, 0666);
        if (fault == "directory") fs.chmod(root + "/etc/nftables.d", 0777);
        if (index([ "close", "changed", "added" ], fault) >= 0) fs.open = (name, mode) => {
            let file = open(name, mode); if (file == null || name != path) return file;
            return { fileno: () => file.fileno(), error: () => file.error(), close: () => { let closed = file.close(); return fault == "close" ? false : closed; },
                read: (count) => {
                    let data = file.read(count); reads++;
                    if (fault == "changed" && reads == 2) return replace(data, "private", "changed");
                    if (fault == "added") write(path + "-new.nft", "# added\n");
                    return data;
                } };
        };
        let result, error;
        try { result = check(root); } catch (e) { error = e; }
        fs.open = open; if (error != null) die(error);
        t.eq(result.state, "incomplete", fault);
    }
});

t.test("file, byte and directory entry limits are finite and fail closed", () => {
    let root = fixture();
    for (let i = 0; i < 64; i++) write(root + "/etc/nftables.d/file" + i + ".nft", "# inert\n");
    t.eq(check(root).state, "checked");
    write(root + "/etc/nftables.d/extra.nft", "# inert\n");
    t.eq(check(root).reason, "nft-persisted-file-limit");
    root = fixture(); write(root + "/etc/nftables.d/large.nft", sprintf("#%1048576s", "x"));
    t.eq(check(root).state, "incomplete");
    let opendir = fs.opendir;
    fs.opendir = (path) => {
        let directory = opendir(path); if (directory == null || path != root + "/etc/nftables.d") return directory;
        return { read: () => ".", close: () => directory.close() };
    };
    let result, error;
    try { result = check(root); } catch (e) { error = e; }
    fs.opendir = opendir; if (error != null) die(error);
    t.eq(result.state, "incomplete");
});

t.test("the exact installed own nft include is admitted only with its verified file proof", () => {
    let root = fixture(), target = "/usr/share/nftables.d/chain-pre/input/loki.nft", path = root + target;
    let body = fs.readfile("../loki/files" + target);
    t.ok(index(body, "meta mark") >= 0, "the shipped include is active");
    write(path, body);
    let file = { path: target, type: "file", mode: 0644, size: length(body), package: "loki", version: "2" };
    file.sha256 = require("singbox.runtime").file_digest(path, file);
    t.ok(file.sha256 != null);
    let own_files = { [target]: file };
    t.eq(check(root, [], own_files).state, "checked");
    t.eq(check(root).reason, "nft-persisted-active-include-unverified");
    for (let change in [ { sha256: sprintf("%064d", 0) }, { size: file.size + 1 }, { mode: 0600 }, { package: "other" } ])
        t.eq(check(root, [], { [target]: { ...file, ...change } }).state, "incomplete");
    write(path, replace(body, "counter accept", "counter drop  "));
    t.eq(check(root, [], own_files).state, "incomplete", "a changed installed file is not trusted");
    write(path, body);
    let copied = "/etc/nftables.d/copied.nft"; write(root + copied, body);
    t.eq(check(root, [], { ...own_files, [copied]: { ...file, path: copied } }).state, "incomplete", "proof cannot authorize another path");
    fs.unlink(root + copied);
    t.eq(check(root, [ { ".type": "include", path: target, fw4_compatible: "1" } ], own_files).state,
        "incomplete", "the nft file cannot be interpreted as a script");
    fs.rename(path, path + ".keep"); fs.symlink(path + ".keep", path);
    t.eq(check(root, [], own_files).state, "incomplete");
});

t.done();
