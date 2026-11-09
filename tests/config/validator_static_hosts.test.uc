let t = require("t");
let v = require("validation");

t.test("a domain in the address column", () => {
    v.refuses({
        "settings": {
            "dns_server": [
                "77.88.8.8"
            ],
            "bootstrap_dns_server": [
                "77.88.8.8"
            ],
            "static_hosts_text": "ntc.party 130.255.77.28\n"
        },
        "section": [
            {
                ".name": "direct_rule",
                "enabled": "1",
                "action": "bypass",
                "destinations": "example.org"
            }
        ]
    }, "invalid address 'ntc.party'");
});

t.test("a malformed domain", () => {
    v.refuses({
        "settings": {
            "dns_server": [
                "77.88.8.8"
            ],
            "bootstrap_dns_server": [
                "77.88.8.8"
            ],
            "static_hosts_text": "130.255.77.28 ntc..party\n"
        },
        "section": [
            {
                ".name": "direct_rule",
                "enabled": "1",
                "action": "bypass",
                "destinations": "example.org"
            }
        ]
    }, "invalid domain 'ntc..party'");
});

t.test("a record without a domain", () => {
    v.refuses({
        "settings": {
            "dns_server": [
                "77.88.8.8"
            ],
            "bootstrap_dns_server": [
                "77.88.8.8"
            ],
            "static_hosts_text": "130.255.77.28\n"
        },
        "section": [
            {
                ".name": "direct_rule",
                "enabled": "1",
                "action": "bypass",
                "destinations": "example.org"
            }
        ]
    }, "must contain an address followed by at least one domain");
});

t.done();
