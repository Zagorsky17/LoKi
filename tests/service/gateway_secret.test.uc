let t = require("t");
let stub = require("stub");
let fs = require("fs");
let storage = require("core.cache_path");
let common = require("core.common");
let secret = require("service.gateway_secret");

const VALUE = "123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0";

function isolated(fn) {
    let original = storage.ensure;
    let original_validate = storage.validate;
    let directory = stub.tmpdir() + "/private";
    t.ok(fs.mkdir(directory, 0700));
    let path = directory + "/controller.secret";
    let gates = [];
    storage.ensure = (settings) => {
        push(gates, settings);
        return original({ cache_path: path });
    };
    storage.validate = (settings) => original_validate({ cache_path: path });
    let failure;
    try { fn(path, gates); }
    catch (e) { failure = e; }
    storage.ensure = original;
    storage.validate = original_validate;
    if (failure != null)
        die(failure.message);
}

t.test("a fresh credential is private, stable across calls and outside UCI", () => {
    isolated((path, gates) => {
        let value = secret.load();
        t.matches(value, /^[a-f0-9]{64}$/);
        t.eq(length(value), 64);
        t.eq(fs.lstat(path).mode & 0777, 0600);
        t.eq(secret.load(), value);
        t.eq(fs.readfile(path), value);
        t.eq(gates, [ { cache_path: "/tmp/loki/controller.secret" }, { cache_path: "/tmp/loki/controller.secret" } ]);
    });
});

t.test("unsafe or corrupt existing credentials are preserved and refused", () => {
    for (let value in [ "", "abc", sprintf("%064d", 0), VALUE + "\n", uc(VALUE), VALUE + "\u0000" ]) {
        isolated((path) => {
            t.ok(common.write_private_file(path, value));
            t.throws(() => secret.load());
            t.eq(fs.readfile(path), value);
        });
    }
    isolated((path) => {
        t.ok(common.write_private_file(path, VALUE));
        fs.chmod(path, 0644);
        t.throws(() => secret.load());
        t.eq(fs.readfile(path), VALUE);
        t.eq(fs.lstat(path).mode & 0777, 0644);
    });
});

t.test("symbolic and hard links never change the unrelated target", () => {
    isolated((path) => {
        let target = path + ".keep";
        t.ok(common.write_private_file(target, VALUE));
        t.ok(fs.symlink(target, path));
        t.throws(() => secret.load());
        t.eq(fs.readfile(target), VALUE);
        t.eq(fs.lstat(path).type, "link");
    });
    isolated((path) => {
        let target = path + ".keep";
        t.ok(common.write_private_file(target, VALUE));
        t.eq(stub.real.system(require("core.exec").command_line([ "ln", target, path ])), 0);
        t.throws(() => secret.load());
        t.eq(fs.readfile(target), VALUE);
        t.eq(fs.lstat(target).nlink, 2);
    });
});

t.test("a concurrent complete winner is reused without overwriting it", () => {
    isolated((path) => {
        let original = common.write_private_file;
        common.write_private_file = (name, value) => {
            original(name, VALUE);
            return false;
        };
        let result;
        let failure;
        try { result = secret.load(); }
        catch (e) { failure = e; }
        common.write_private_file = original;
        if (failure != null)
            die(failure.message);
        t.eq(result, VALUE);
        t.eq(fs.readfile(path), VALUE);
    });
});

t.test("metadata changes during a read are refused without repairing the file", () => {
    for (let changed in [
        (s) => ({ inode: s.inode + 1 }), (s) => ({ dev: { ...s.dev, major: s.dev.major + 1 } }),
        (s) => ({ dev: { ...s.dev, minor: s.dev.minor + 1 } }), (s) => ({ uid: s.uid + 1 }),
        (s) => ({ nlink: 2 }), (s) => ({ mode: 0644 }), (s) => ({ size: 1 }),
        (s) => ({ mtime: s.mtime + 1 }), (s) => ({ ctime: s.ctime + 1 })
    ]) {
        isolated((path) => {
            t.ok(common.write_private_file(path, VALUE));
            let original_open = fs.open;
            let original_stat = fs.lstat;
            let opened = false;
            fs.open = (name, mode, permissions) => {
                let result = original_open(name, mode, permissions);
                if (name == path && mode == "re")
                    opened = true;
                return result;
            };
            fs.lstat = (name) => {
                let stat = original_stat(name);
                return name == path && opened ? { ...stat, ...changed(stat) } : stat;
            };
            let failure;
            try { secret.load(); }
            catch (e) { failure = e; }
            fs.open = original_open;
            fs.lstat = original_stat;
            t.ok(failure != null);
            t.eq(fs.readfile(path), VALUE);
        });
    }
});

t.test("entropy errors and failed writes cannot publish a weak or partial credential", () => {
    let zeros = "";
    for (let i = 0; i < 32; i++)
        zeros += chr(0);
    for (let entropy in [ null, "", "short", zeros ]) {
        isolated((path) => {
            let original = fs.open;
            fs.open = (name, mode, permissions) => name == "/dev/urandom"
                ? { read: () => entropy, close: () => true } : original(name, mode, permissions);
            let failure;
            try { secret.load(); }
            catch (e) { failure = e; }
            fs.open = original;
            t.ok(failure != null);
            t.eq(fs.lstat(path), null);
        });
    }
    isolated((path) => {
        let original = common.write_private_file;
        common.write_private_file = () => false;
        let failure;
        try { secret.load(); }
        catch (e) { failure = e; }
        common.write_private_file = original;
        t.ok(failure != null);
        t.eq(fs.lstat(path), null);
    });
});

t.test("log redaction reads only an existing credential and preserves unrelated raw user data", () => {
    isolated((path) => {
        t.eq(secret.redactor()("user-password"), "user-password");
        t.eq(fs.lstat(path), null, "reading logs must not create a credential");
        t.ok(common.write_private_file(path, VALUE));
        let value = secret.redactor()("user-password " + VALUE + " " + VALUE);
        t.eq(value, "user-password SERVER_ONLY SERVER_ONLY");
        t.eq(fs.readfile(path), VALUE);
        t.eq(fs.lstat(path).mode & 0777, 0600);
    });
});

t.test("uncertain private storage refuses log content without disclosing the original or repairing state", () => {
    for (let data in [ "partial", VALUE ]) {
        isolated((path) => {
            t.ok(common.write_private_file(path, data));
            if (data == VALUE)
                fs.chmod(path, 0644);
            let value = secret.redactor()("user-password " + VALUE);
            t.contains(value, "credential inspection failed");
            t.excludes(value, VALUE);
            t.excludes(value, "user-password");
            t.eq(fs.readfile(path), data);
            t.eq(fs.lstat(path).mode & 0777, data == VALUE ? 0644 : 0600);
        });
    }
    isolated((path) => {
        t.ok(common.write_private_file(path, VALUE));
        fs.chmod(require("core.common").parent_dir(path), 0755);
        t.contains(secret.redactor()(VALUE), "credential inspection failed");
        t.eq(fs.readfile(path), VALUE);
    });
});

t.test("ephemeral credentials read entropy without opening persistent controller state", () => {
    let original = [ fs.open, storage.ensure, common.write_private_file ];
    let requests = [];
    storage.ensure = () => die("persistent storage accessed");
    common.write_private_file = () => die("persistent storage written");
    fs.open = (name, mode) => {
        t.eq(name, "/dev/urandom");
        t.eq(mode, "re");
        return { read: (bytes) => { push(requests, bytes); return "0123456789abcdef0123456789abcdef"; }, close: () => true };
    };
    let value = secret.generate();
    fs.open = original[0];
    storage.ensure = original[1];
    common.write_private_file = original[2];
    t.eq(requests, [ 32 ]);
    t.matches(value, /^[a-f0-9]{64}$/);
    t.ok(value != sprintf("%064d", 0));
});

t.test("failed closure refuses both persisted and ephemeral credentials", () => {
    for (let failure in [ "false", "throw" ])
        isolated((path) => {
            t.ok(common.write_private_file(path, VALUE));
            let original = fs.open;
            fs.open = (name, ...args) => {
                let file = original(name, ...args);
                if (file == null || (name != path && name != "/dev/urandom")) return file;
                return { read: (bytes) => file.read(bytes), close: () => {
                    file.close();
                    if (failure == "throw") die("synthetic-secret");
                    return false;
                } };
            };
            let persisted = null;
            let ephemeral = null;
            try { secret.load(); }
            catch (e) { persisted = e.message; }
            try { secret.generate(); }
            catch (e) { ephemeral = e.message; }
            let redacted = secret.redactor()("synthetic-secret " + VALUE);
            fs.open = original;
            t.ok(persisted != null);
            t.ok(ephemeral != null);
            t.excludes(persisted, "synthetic-secret");
            t.excludes(ephemeral, "synthetic-secret");
            t.contains(redacted, "credential inspection failed");
            t.excludes(redacted, "synthetic-secret");
            t.excludes(redacted, VALUE);
            t.eq(fs.readfile(path), VALUE);
        });
});

t.test("ephemeral credentials refuse absent, short, zero and failed entropy reads", () => {
    let original = fs.open;
    for (let value in [ null, "short", b64dec("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="), "throw" ]) {
        fs.open = (name, mode) => value == null ? null : {
            read: () => { if (value == "throw") die("synthetic-secret"); return value; }, close: () => true
        };
        let failure = null;
        try { secret.generate(); }
        catch (e) { failure = e.message; }
        fs.open = original;
        t.ok(failure != null);
        t.excludes(failure, "synthetic-secret");
    }
});

t.test("the update snapshot reads a credential without creating or repairing it", () => {
    isolated((path, gates) => {
        t.eq(secret.current(), null);
        t.eq(fs.lstat(path), null);
        t.eq(gates, []);
        t.ok(common.write_private_file(path, VALUE));
        t.eq(secret.current(), VALUE);
        fs.chmod(path, 0644);
        t.throws(() => secret.current());
        t.eq(fs.readfile(path), VALUE);
        t.eq(fs.lstat(path).mode & 0777, 0644);
    });
});

t.done();
