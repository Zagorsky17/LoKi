let t = require("t");
let conflicts = require("diagnostics.conflicts");

// What the AX3000T runs beside Loki: Zapret with its own marks and queues, fw4's DNS redirect.
const NEIGHBOURS = join("\n", [
    "table inet zapret {",
    "\tset wanif {",
    "\t\ttype ifname",
    "\t}",
    "\tchain postnat_hook {",
    "\t\ttype filter hook postrouting priority srcnat + 1; policy accept;",
    "\t\tjump postnat",
    "\t}",
    "\tchain postnat {",
    "\t\toifname @wanif tcp dport { 80, 443 } meta mark set meta mark | 0x20000000 queue flags bypass to 200",
    "\t}",
    "}",
    "table inet fw4 {",
    "\tchain dstnat {",
    "\t\ttype nat hook prerouting priority dstnat; policy accept;",
    "\t\tiifname \"br-lan\" jump dstnat_lan",
    "\t}",
    "\tchain dstnat_lan {",
    "\t\tudp dport 53 counter redirect to :5353",
    "\t}",
    "}",
    "table inet loki {",
    "\tchain proxy {",
    "\t\ttype filter hook prerouting priority dstnat; policy accept;",
    "\t\tmeta l4proto tcp tproxy ip to :1602",
    "\t}",
    "\tchain dns_redirect {",
    "\t\ttype nat hook prerouting priority dstnat - 1; policy accept;",
    "\t\tudp dport 53 redirect to :1603",
    "\t}",
    "}",
    ""
]);

t.test("priorities read the way nft prints them", () => {
    t.eq(map([ "dstnat - 1", "mangle + 1", "filter", "srcnat+1", "-401", "dstnat-5" ], conflicts.priority_value),
        [ -101, -149, 0, 101, -401, -105 ]);
    t.eq(conflicts.priority_value("unknown"), null);
});

t.test("neighbours that mark with their own bits or redirect DNS after Loki are no conflict", () => {
    t.eq(conflicts.find(NEIGHBOURS), []);
});

t.test("a transparent proxy of another table is a conflict wherever its chain is reached from", () => {
    let listing = NEIGHBOURS + join("\n", [
        "table inet PodkopTable {",
        "\tset interfaces {",
        "\t\ttype ifname",
        "\t\tflags interval",
        "\t}",
        "\tchain mangle {",
        "\t\ttype filter hook prerouting priority mangle; policy accept;",
        "\t\tgoto steer",
        "\t}",
        "\tchain steer {",
        "\t\tmeta mark 0x00100000 meta l4proto tcp tproxy ip to 127.0.0.1:1602 counter",
        "\t}",
        "\tchain unused {",
        "\t\tudp dport 53 dnat ip to 127.0.0.42",
        "\t}",
        "}",
        ""
    ]);
    t.eq(conflicts.find(listing), [ { table: "inet PodkopTable", kind: "tproxy" } ], "a chain no hook reaches redirects nothing");
});

t.test("a DNS redirect counts when it can run before Loki's", () => {
    let redirect = (hook, priority, rule) => sprintf("table ip other {\n\tchain c {\n\t\ttype nat hook %s priority %s; policy accept;\n\t\t%s\n\t}\n}\n", hook, priority, rule);
    t.eq(conflicts.find(redirect("prerouting", "dstnat - 5", "meta l4proto udp th dport 53 redirect to :5353")), [ { table: "ip other", kind: "dns" } ]);
    t.eq(conflicts.find(redirect("prerouting", "dstnat - 5", "udp dport { 53, 853 } dnat to 10.0.0.1")), [ { table: "ip other", kind: "dns" } ], "a port set");
    t.eq(conflicts.find(redirect("prerouting", "dstnat - 5", "udp dport 50-60 redirect to :5353")), [ { table: "ip other", kind: "dns" } ], "a port range");
    t.eq(conflicts.find(redirect("prerouting", "dstnat - 1", "udp dport 53 redirect to :5353")), [ { table: "ip other", kind: "dns" } ],
        "the same priority runs first once its table is loaded after LoKi's");
    t.eq(conflicts.find(redirect("prerouting", "dstnat", "udp dport 53 redirect to :5353")), [], "a later priority");
    t.eq(conflicts.find(redirect("prerouting", "dstnat - 5", "udp dport 5353 redirect to :53")), [], "another port");
    t.eq(conflicts.find(redirect("output", "-150", "udp dport 53 redirect to :5353")), [ { table: "ip other", kind: "dns" } ], "the router's own queries");
});

t.done();
