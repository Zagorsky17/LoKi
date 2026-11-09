// Modified for LoKi on 2026-11-01: verify conservative list overlap warnings.
let t = require("t");
let lists = require("singbox.rulesets");
const LEGACY = "https://github.com/itdoginfo/allow-domains/releases/latest/download/";

t.test("the same known source is recognized by name or exact URL in either list field", () => {
    for (let reference in [ "telegram", lists.community_url("telegram") ])
        t.eq(lists.overlaps([ "telegram" ], [ reference ]), [ {
            builtin: "telegram", external: "forkop-lists/telegram.srs", relation: "same_source"
        } ]);
    t.eq(lists.overlaps([], [ lists.community_url("telegram") ]), []);
    t.eq(lists.overlaps([ "unknown_service" ], [ "telegram" ]), []);
    t.eq(lists.overlaps([ "github" ], [ lists.community_url("telegram") ]), []);
});

t.test("regional inclusion and legacy sources are possible overlaps, never proof of identical files", () => {
    t.eq(lists.overlaps([ "ru_blocked_all" ], [ "telegram" ]), [ {
        builtin: "ru_blocked_all", external: "forkop-lists/telegram.srs", relation: "possible_overlap"
    } ]);
    t.eq(lists.overlaps([ "ru_blocked_geo" ], [ "claude" ])[0].relation, "possible_overlap");
    t.eq(lists.overlaps([ "ru_blocked_rkn" ], [ "claude" ]), []);
    t.eq(lists.overlaps([ "ru_blocked_all" ], [ LEGACY + "russia_inside.srs", LEGACY + "meta.srs" ]), [
        { builtin: "ru_blocked_all", external: "itdog/russia_inside.srs", relation: "possible_overlap" },
        { builtin: "ru_blocked_all", external: "itdog/meta.srs", relation: "possible_overlap" }
    ]);
    t.eq(lists.overlaps([ "ru_blocked_geo" ], [ LEGACY + "meta.srs" ]), []);
});

t.test("exact matches win and repeated references cannot multiply warnings", () => {
    let refs = [ "telegram", lists.community_url("telegram"), "telegram" ];
    t.eq(lists.overlaps([ "ru_blocked_all", "telegram", "telegram" ], refs), [ {
        builtin: "telegram", external: "forkop-lists/telegram.srs", relation: "same_source"
    } ]);
    t.eq(length(lists.overlaps([ "telegram" ], map(split(sprintf("%01000d", 0), ""), () => "telegram"))), 1);
    let names = keys(lists.COMMUNITY_SERVICES);
    t.eq(length(lists.overlaps(names, [ ...names, ...names ])), length(names));
});

t.test("untrusted lookalikes and secret-bearing or versioned URLs are ignored without returning their text", () => {
    let url = lists.community_url("telegram");
    for (let reference in [
        replace(url, "github.com/", "github.com.evil.test/"), replace(url, "github.com/", "github.com@evil.test/"),
        url + "?token=TEST_SECRET", url + "#TEST_SECRET", url + "/file.srs", lc(replace(url, "telegram", "TELEGRAM")) + ".bak",
        replace(url, "/latest/download/", "/download/pinned/"), replace(url, "https://", "http://"),
        "/tmp/telegram.srs", "https://other.test/telegram.srs", LEGACY + "meta.srs?token=TEST_SECRET", "__proto__"
    ])
        t.eq(lists.overlaps([ "telegram", "ru_blocked_all" ], [ reference ]), []);
});
t.done();
