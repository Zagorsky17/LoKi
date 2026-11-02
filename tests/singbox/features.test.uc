let t = require("t");
let stub = require("stub");
let fs = require("fs");
let features = require("singbox.features");

const BASE = "badlinkname,tfogo_checklinkname0,with_anytls,with_clash_api,with_gvisor,with_openvpn,with_quic," +
    "with_trusttunnel,with_utls,with_vmess,with_wireguard";
const TINY = "badlinkname,tfogo_checklinkname0,with_clash_api,with_quic,with_utls";

function version_text(tags) {
    return "sing-box version 1.14.4-r1\n\nEnvironment: go1.26.10 linux/arm64\n" +
        (tags == null ? "" : "Tags: " + tags + "\n") + "CGO: disabled\n";
}

// A core at a path of its own, answering `version` with the given tags.
function core(tags) {
    let dir = stub.tmpdir();
    features.paths.binary = dir + "/sing-box";
    fs.writefile(features.paths.binary, "#!/bin/sh\n");
    stub.commands([ [ features.paths.binary + " version", { status: 0, stdout: version_text(tags) } ] ]);
}

t.test("the tags are the Tags line of sing-box version", () => {
    t.eq(features.parse_tags(version_text("with_quic, with_utls,with_clash_api")), [ "with_quic", "with_utls", "with_clash_api" ]);
    t.eq(features.parse_tags(version_text(null)), [], "a core built without tags has none");
});

t.test("the core is asked once for as long as its binary stays the same", () => {
    core(BASE);
    t.eq(length(features.tags()), 11);
    t.eq(length(features.tags()), 11);
    t.eq(length(filter(stub.calls(), (entry) => index(entry.command, "version") >= 0)), 1, "the second question was answered from memory");

    fs.writefile(features.paths.binary, "#!/bin/sh\n# another build\n");
    stub.commands([ [ features.paths.binary + " version", { status: 0, stdout: version_text("with_clash_api") } ] ]);
    t.eq(features.tags(), [ "with_clash_api" ], "a replaced binary is asked again");
    stub.restore();
});

t.test("without a binary there is nothing to ask and nothing is available", () => {
    features.paths.binary = stub.tmpdir() + "/absent";
    t.eq(features.tags(), null);
    t.ok(!features.available("clash_api"));
    t.eq(features.unavailable_reason("quic"), "sing-box is not installed");
    t.eq(features.report().known, false);
});

t.test("a feature is there when every tag it needs is", () => {
    let tags = split(BASE, ",");
    for (let name in [ "clash_api", "wireguard", "utls", "quic", "openvpn", "trusttunnel", "vmess", "anytls" ])
        t.ok(features.available(name, tags), name + " is in the base build");
    for (let name in [ "snell", "ssh", "shadowtls", "tor", "tailscale", "naive", "openconnect", "mieru" ])
        t.ok(!features.available(name, tags), name + " is only in the full build");
    let tiny = split(TINY, ",");
    for (let name in [ "clash_api", "utls", "quic" ])
        t.ok(features.available(name, tiny), name + " is in the tiny build");
    for (let name in [ "wireguard", "openvpn", "trusttunnel", "vmess", "anytls" ])
        t.ok(!features.available(name, tiny), name + " is not in the tiny build");
    t.ok(!features.available("wireguard", [ "with_wireguard", "with_clash_api" ]), "WireGuard runs on gVisor");
    t.eq(features.unavailable_reason("quic", [ "with_clash_api" ]), "this sing-box build lacks QUIC (built without with_quic)");
    t.eq(features.unavailable_reason("utls", tags), "");
    t.ok(!features.available("no-such-feature", tags));
});

t.test("types name the feature they need by the kind of object they are", () => {
    t.eq(features.type_feature("outbound", "naive"), "naive");
    t.eq(features.type_feature("endpoint", "warp"), "wireguard");
    t.eq(features.type_feature("endpoint", "openvpn-client"), "openvpn");
    t.eq(features.type_feature("outbound", "vless"), "");
    t.eq(features.type_feature("outbound", "vmess"), "vmess");
    t.eq(features.type_feature("outbound", "ssh"), "ssh");
});

t.test("Forkop runs on a core with the Clash API whose tunnels have their gVisor stack", () => {
    t.eq(features.core_problem(split(BASE, ",")), "");
    t.eq(features.core_problem(split(TINY, ",")), "");
    t.contains(features.core_problem([ "with_utls", "with_quic" ]), "sing-box was built without with_clash_api");
    t.contains(features.core_problem([ "with_clash_api", "with_openconnect" ]),
        "sing-box was built with with_openconnect but without with_gvisor");
});

t.test("the page is told each feature, the tags that make it and the types that need it", () => {
    core(BASE);
    let report = features.report();
    t.eq(report.known, true);
    t.eq(report.features.quic, { available: true, tags: [ "with_quic" ] });
    t.eq(report.features.tailscale, { available: false, tags: [ "with_tailscale", "with_gvisor" ] });
    t.eq(report.types.endpoint.amneziawg, "wireguard");
    t.eq(report.types.outbound.hysteria2, "quic");
    t.eq(report.links.hy2, "hysteria2");
    stub.restore();
});

t.done();
