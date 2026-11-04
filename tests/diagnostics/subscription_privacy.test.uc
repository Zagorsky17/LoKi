let t = require("t");
let stub = require("stub");
let fs = require("fs");
let fixture = require("fixture");
let report = require("diagnostics.report");

// A provider cache holds the original profile, including fields that are never applied.
t.test("masked diagnostics never read or attach the raw subscription cache", () => {
    let dir = stub.tmpdir();
    let runtime = dir + "/runtime.json";
    let cache = dir + "/cache.db";
    let cache_dir = cache + ".rule-sets";
    let body = cache_dir + "/subscription-body";
    let secret = "CacheOnlyAster47";
    fs.writefile(cache, secret);
    fs.mkdir(cache_dir);
    fs.writefile(body, sprintf("%J", { outbounds: [ { type: "http", password: secret } ],
        log: { output: "client-only-path" }, dns: { client_token: "CacheOnlyBirch58" } }));
    fs.writefile(runtime, sprintf("%J", {
        providers: [ { type: "remote", tag: "main/Profile", url: "https://source.example/sub?token=SourceOnlyCedar69",
            headers: { Authorization: [ "ConfiguredBearer73" ] } } ],
        experimental: { cache_file: { enabled: true, path: cache }, clash_api: { secret: "ConfiguredApi82" } }
    }));
    fixture.seed({ settings: { config_path: runtime } });
    report.paths.loki_config = dir + "/loki";
    fs.writefile(report.paths.loki_config, "config settings 'settings'\n");
    stub.commands([ [ () => true, { stdout: "ConfiguredBearer73 ConfiguredApi82 https://source.example/sub?token=SourceOnlyCedar69\n" } ] ]);
    let reads = [];
    let readfile = fs.readfile;
    fs.readfile = (path) => {
        push(reads, path);
        if (path == cache || path == body)
            die("masked diagnostics tried to inspect a raw subscription cache");
        return readfile(path);
    };
    let value;
    try {
        value = report.report("masked", "ConfiguredBearer73 ConfiguredApi82");
    }
    catch (e) {
        fs.readfile = readfile;
        stub.restore();
        die(e.message);
    }
    fs.readfile = readfile;
    stub.restore();
    t.eq(value.visibility, "masked");
    t.ok(index(reads, runtime) >= 0, "the guard observes actual configuration reads");
    for (let token in [ secret, "CacheOnlyBirch58", "SourceOnlyCedar69", "ConfiguredBearer73", "ConfiguredApi82" ])
        t.excludes(sprintf("%J", value), token);
});

t.done();
