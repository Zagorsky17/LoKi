let t = require("t");
let netstat = require("core.netstat");

const EXPLICIT = "tcp 0 0 192.168.1.1:9090 0.0.0.0:* LISTEN";
const IPV4_WILDCARD = "tcp 0 0 0.0.0.0:9090 0.0.0.0:* LISTEN";
const IPV6_WILDCARD = "tcp 0 0 :::9090 :::* LISTEN";

t.test("a listener on the same address and port is in the way", () => {
    t.eq(netstat.tcp_endpoint_in_use(EXPLICIT, "192.168.1.1:9090"), true);
});

t.test("a wildcard listener and an explicit address are in each other's way", () => {
    t.eq(netstat.tcp_endpoint_in_use(IPV4_WILDCARD, "192.168.1.1:9090"), true);
    t.eq(netstat.tcp_endpoint_in_use(EXPLICIT, "0.0.0.0:9090"), true);
    t.eq(netstat.tcp_endpoint_in_use(IPV6_WILDCARD, "192.168.1.1:9090"), true, "a dual-stack wildcard");
    t.eq(netstat.tcp_endpoint_in_use(EXPLICIT, "[::]:9090"), true, "a dual-stack wildcard asked for");
});

t.test("another address or another port is not", () => {
    t.eq(netstat.tcp_endpoint_in_use(EXPLICIT, "192.168.1.2:9090"), false);
    t.eq(netstat.tcp_endpoint_in_use(EXPLICIT, "192.168.1.1:9091"), false);
});

t.test("netstat tells a listener apart and names who else holds its port", () => {
    let listening = "Active Internet connections (only servers)\nProto Recv-Q Send-Q Local Address           Foreign Address         State\n" +
        "tcp        0      0 0.0.0.0:443             0.0.0.0:*               LISTEN\nudp        0      0 0.0.0.0:443             0.0.0.0:*\n";
    t.ok(netstat.port_listening(listening, "0.0.0.0", "443", "tcp") && netstat.port_listening(listening, "0.0.0.0", "443", "udp"));
    t.ok(!netstat.port_listening(listening, "0.0.0.0", "8443", "tcp"));
    t.ok(netstat.port_listening("tcp        0      0 ::1:8443                :::*                    LISTEN\n", "::1", "8443", "tcp"));
    let owners = "Active Internet connections (only servers)\n" +
        "Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name\n" +
        "tcp        0      0 0.0.0.0:443             0.0.0.0:*               LISTEN      111/nginx\n" +
        "udp        0      0 0.0.0.0:443             0.0.0.0:*                           222/dnsmasq\n" +
        "tcp        0      0 0.0.0.0:443             0.0.0.0:*               LISTEN      333/loki-core\n";
    let found = [];
    for (let proto in [ "tcp", "udp" ])
        push(found, ...netstat.port_conflict_owners(owners, "0.0.0.0", "443", proto));
    t.eq(netstat.sorted_unique(found), [ "111/nginx", "222/dnsmasq" ]);
});

t.done();
