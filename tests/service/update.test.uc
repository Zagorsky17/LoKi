let t = require("t");
let update = require("service.update");

const VALUE = { format: "apk", names: [ "loki" ], components: [ { package: "loki", version: "2.0.1" } ] };
const INSTALLED = { loki: "2.0.1" };

t.test("native APK same-version replacements remain restricted to the selected own set", () => {
    t.eq(update.package_plan(VALUE, "update", "(1/1) Replacing loki (2.0.1 -> 2.0.1)\nOK: 8 B in 1 packages\n", INSTALLED), true);
    t.eq(update.package_plan(VALUE, "update", "(1/1) Replacing foreign-package (1 -> 1)\n", INSTALLED), false);
    t.eq(update.package_plan(VALUE, "update", "(1/1) UnknownAction foreign-package (1)\n", INSTALLED), false);
    t.eq(update.package_plan(VALUE, "uninstall", "(1/1) Replacing loki (2.0.1 -> 2.0.1)\n", INSTALLED), false);
    t.eq(update.package_plan(VALUE, "update", "(1/1) Replacing loki (2.0.1 -> 2.0.1)\u0000private", INSTALLED), false);
});

t.done();
