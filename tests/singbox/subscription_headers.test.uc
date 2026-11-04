let t = require("t");
let stub = require("stub");
let fs = require("fs");
let packages = require("core.packages");
let headers = require("singbox.subscription_headers");

function headers_module(release_file, version_file) {
    headers.paths.openwrt_release = release_file ?? "/nonexistent";
    packages.paths.sing_box_version = version_file ?? "/nonexistent";
    return headers;
}

function write(name, text) {
    let path = stub.tmpdir() + "/" + name;
    fs.writefile(path, text);
    return path;
}

let release = write("openwrt_release", "DISTRIB_ID='ImmortalWrt'\nDISTRIB_RELEASE='24.10.5'\n");

t.test("the default request carries the Happ/Remnawave set and nothing else", () => {
    let module = headers_module(release);
    let parsed = module.parse_header_lines(module.default_header_lines());
    t.ok(parsed.valid);
    t.eq(sort(keys(parsed.headers)), [ "User-Agent", "X-Device-Model", "X-Device-OS", "X-HWID", "X-Ver-OS" ]);
    t.eq(parsed.headers["User-Agent"], [ "sing-box" ], "without an installed core there is no version to claim");
    t.ok(parsed.headers["X-HWID"][0] != "");
    t.eq(parsed.headers["X-Ver-OS"], [ "24.10.5" ], "X-Ver-OS is the OpenWrt release");
});

t.test("the User-Agent names the upstream sing-box version of the installed core", () => {
    for (let installed in [ "1.13.18-extended-2.6.5-f70", "1.13.18-forkop.4" ]) {
        let module = headers_module(null, write("version", installed + "\n"));
        t.eq(module.default_user_agent(), "sing-box", "an unrelated fork is not a supported installed version");
    }
    for (let installed in [ "1.14.4-r1", "1.14.4-r0+12" ]) {
        let module = headers_module(null, write("version", installed + "\n"));
        t.eq(module.default_user_agent(), "sing-box/1.14.4", installed);
    }
});

t.test("an unknown release sends no X-Ver-OS", () => {
    let module = headers_module();
    let parsed = module.parse_header_lines(module.default_header_lines());
    t.ok(parsed.valid);
    t.eq(parsed.headers["X-Ver-OS"], null);
    t.eq(length(keys(parsed.headers)), 4);
});

t.test("header lines are validated and combined case-insensitively", () => {
    let module = headers_module();
    t.eq(module.parse_header_lines([ "X-A: 1", "x-a: 2" ]).headers, { "X-A": [ "1", "2" ] });
    t.eq(module.parse_header_lines([ "Broken Header" ]).valid, false);
    t.eq(module.parse_header_lines([ "Bad Name: x" ]).valid, false);
});

t.done();
