let t = require("t");
let fs = require("fs");
let repo = require("repo");

function permissions() {
    return json(fs.readfile(repo.path("luci-app-forkop/root/usr/share/rpcd/acl.d/luci-app-forkop.json")))["luci-app-forkop"];
}

t.test("a read session cannot select an interpreter environment through file.exec", () => {
    let read = permissions().read;
    for (let path, grants in read.file ?? {})
        t.eq(index(grants, "exec"), -1, path);
    for (let method in read.ubus?.file ?? [])
        t.ok(method != "exec" && method != "*", method);
});

t.test("a read session cannot fetch raw connection credentials from the UCI provider", () => {
    t.eq(index(permissions().read.uci ?? [], "forkop"), -1);
    t.eq(index(permissions().read.uci ?? [], "*"), -1);
});

t.test("a writer can read and edit the own UCI package without granting that read to viewers", () => {
    let acl = permissions();
    let granted = (section, object, operation, level) => type(section.uci) == "array"
        ? operation == level && index(section.uci, object) >= 0
        : index(section.uci?.[object] ?? [], operation) >= 0;
    for (let operation in [ "read", "write" ]) {
        t.eq(granted(acl.read, "forkop", operation, "read"), false, operation);
        t.eq(granted(acl.write, "forkop", operation, "write"), true, operation);
    }
});

t.done();
