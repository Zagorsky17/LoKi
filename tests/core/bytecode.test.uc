// A miniature library: a leaf module the cache self-check loads, a module importing it, an
// entry script and a file that is not a module.

let t = require("t");
let stub = require("stub");
let fs = require("fs");

function write(path, text) {
    stub.real.system("mkdir -p '" + replace(path, /\/[^\/]*$/, "") + "'");
    fs.writefile(path, text);
}

// The way a package install replaces a module: a new file renamed over the old.
function replace_domain(library, marker) {
    write(library + "/config/domain.uc.new", "return { marker: \"" + marker + "\" };\n");
    fs.rename(library + "/config/domain.uc.new", library + "/config/domain.uc");
}

function new_library() {
    let dir = stub.tmpdir();
    let library = dir + "/lib";
    replace_domain(library, "domain-v1");
    write(library + "/core/probe.uc", "let domain = require(\"config.domain\");\nreturn { marker: \"probe-\" + domain.marker };\n");
    write(library + "/service/entry.uc", "let probe = require(\"core.probe\");\nprint(probe.marker, \"\\n\");\n");
    write(library + "/core/payload.txt", "payload\n");
    return { library, cache: dir + "/cache" };
}

// Validation is reused for a few seconds by default; the checks of full validation turn that off.
function bytecode(where, fn, env) {
    stub.env({
        LOKI_SOURCE_LIB: where.library,
        LOKI_BYTECODE_CACHE_DIR: where.cache,
        LOKI_BYTECODE_VALIDATION_TTL: "0",
        ...(env ?? {})
    });
    let result, failure = null;
    try {
        result = fn(stub.fresh("core.bytecode"));
    }
    catch (e) {
        failure = e;
    }
    stub.restore();
    if (failure != null)
        die(failure.message);
    return result;
}

function refresh(where, env) {
    return bytecode(where, (m) => m.refresh(), env);
}

function resolved(where, env) {
    return bytecode(where, (m) => m.library_dir(), env);
}

// A compiled module keeps its #! line in front of the bytecode signature.
function is_bytecode(path) {
    return index(fs.readfile(path, 32) ?? "", "\x1bucb") >= 0;
}

// What the entry script prints when run out of `library`.
function entry_output(library) {
    let pipe = fs.popen("ucode -L '" + library + "' '" + library + "/service/entry.uc'", "r");
    let output = pipe.read("all");
    pipe.close();
    return trim(output);
}

function files_under(dir) {
    let pipe = fs.popen("find '" + dir + "' -type f", "r");
    let output = trim(pipe.read("all"));
    pipe.close();
    return output == "" ? [] : split(output, "\n");
}

t.test("a library compiles into a cache that behaves like the sources", () => {
    let where = new_library();
    let built = refresh(where);
    t.ok(built != where.library, "resolved to a cache");
    t.ok(fs.stat(where.cache + "/manifest"), "a manifest");
    for (let module in [ "config/domain.uc", "core/probe.uc", "service/entry.uc" ])
        t.ok(is_bytecode(built + "/" + module), module + " as bytecode");
    t.eq(fs.readfile(built + "/core/payload.txt"), "payload\n", "a file that is not a module is copied");
    t.eq(entry_output(where.library), "probe-domain-v1");
    t.eq(entry_output(built), "probe-domain-v1");
    t.eq(length(files_under(built)), length(files_under(where.library)), "the cache stands in for every file");
    t.eq(refresh(where), built, "an up-to-date cache is reused");
});

t.test("a replaced, added or removed module rebuilds the cache", () => {
    let where = new_library();
    let built = refresh(where);

    replace_domain(where.library, "domain-v2");
    t.eq(resolved(where), where.library, "a cache of replaced sources is not resolved");
    let rebuilt = refresh(where);
    t.ok(rebuilt != built && rebuilt != where.library);
    t.eq(entry_output(rebuilt), "probe-domain-v2");

    write(where.library + "/core/added.uc", "return { marker: \"added-v1\" };\n");
    let added = refresh(where);
    t.ok(added != rebuilt, "adding a module rebuilds");
    t.ok(fs.stat(added + "/core/added.uc"), "the added module reaches the cache");

    fs.unlink(where.library + "/core/added.uc");
    let removed = refresh(where);
    t.ok(removed != added, "removing a module rebuilds");
    t.eq(fs.stat(removed + "/core/added.uc"), null, "the removed module does not survive");
});

t.test("a rebuild keeps the library it replaces and removes older ones", () => {
    let where = new_library();
    let first = refresh(where);
    replace_domain(where.library, "domain-v2");
    let second = refresh(where);
    replace_domain(where.library, "domain-v3");
    let third = refresh(where);

    t.eq(fs.stat(first), null, "the library two builds back is gone");
    t.ok(fs.stat(second), "the replaced library stays for a worker still loading from it");
    t.eq(entry_output(third), "probe-domain-v3");
    t.eq(sort(filter(fs.lsdir(where.cache), (name) => substr(name, 0, 4) == "lib.")),
        sort(map([ second, third ], (path) => substr(path, length(where.cache) + 1))));
});

t.test("a different interpreter invalidates the cache", () => {
    let where = new_library();
    refresh(where);
    let wrapper = stub.tmpdir() + "/ucode";
    fs.writefile(wrapper, "#!/bin/sh\nexec ucode \"$@\"\n");
    stub.real.system("chmod +x '" + wrapper + "'");
    t.eq(resolved(where, { LOKI_UCODE_BIN: wrapper }), where.library);
});

t.test("with the cache switched off the sources are used and nothing is written", () => {
    let where = new_library();
    t.eq(refresh(where, { LOKI_BYTECODE_CACHE: "0" }), where.library);
    t.eq(fs.stat(where.cache), null);
});

t.test("a module that does not compile is carried as source", () => {
    let where = new_library();
    write(where.library + "/core/broken.uc", "this is ( not ucode\n");
    let built = refresh(where);
    t.ok(fs.stat(built + "/core/broken.uc"), "present");
    t.ok(!is_bytecode(built + "/core/broken.uc"), "as source");
});

t.test("the manifest records the directories its file list was read against", () => {
    let where = new_library();
    refresh(where);
    t.matches(fs.readfile(where.cache + "/manifest"), /(^|\n)dir=/);
});

t.test("validation is reused within its window, and not past it or an install", () => {
    let where = new_library();
    let window = { LOKI_BYTECODE_VALIDATION_TTL: "30" };
    let at = (seconds, fn) => {
        stub.clock(seconds);
        return fn();
    };

    let built = at(1000, () => refresh(where, window));
    replace_domain(where.library, "domain-v22");
    t.eq(at(1029, () => resolved(where, window)), built, "reused inside the window");
    t.eq(at(1030, () => resolved(where, window)), where.library, "revalidated once it is over");

    let rebuilt = at(2000, () => refresh(where, window));
    replace_domain(where.library, "domain-v333");
    t.eq(at(2001, () => resolved(where, window)), rebuilt, "still inside the window");
    bytecode(where, (m) => m.invalidate_validation_stamp());
    t.eq(at(2001, () => resolved(where, window)), where.library, "an install drops the stamp");
});

t.done();
