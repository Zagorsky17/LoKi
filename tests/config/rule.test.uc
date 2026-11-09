let t = require("t");
let rule = require("config.rule");

function parsed(text) {
    return rule.destination_conditions(text);
}

function only(kind, values) {
    let result = { domain: [], domain_suffix: [], domain_keyword: [], domain_regex: [], ip_cidr: [] };
    result[kind] = values;
    return result;
}

const TEXT_A = "full:a.example\nb.example\nkeyword:ads\nregex:^tracker\\.\n192.0.2.0/24\n";
const TEXT_B = "full:c.example\nd.example\nkeyword:beacon\n2001:db8::1\n";

t.test("the destinations split by their prefixes, and an address is matched as one", () => {
    t.eq(parsed(TEXT_A), {
        domain: [ "a.example" ],
        domain_suffix: [ "b.example" ],
        domain_keyword: [ "ads" ],
        domain_regex: [ "^tracker\\." ],
        ip_cidr: [ "192.0.2.0/24" ]
    });
});

t.test("entries may share a line, separated by spaces or commas, and comments are left out", () => {
    t.eq(parsed("full:e.example f.example,keyword:beacon # g.example\n10.0.0.1, fd00::/8 // 10.0.0.2"), {
        domain: [ "e.example" ],
        domain_suffix: [ "f.example" ],
        domain_keyword: [ "beacon" ],
        domain_regex: [],
        ip_cidr: [ "10.0.0.1", "fd00::/8" ]
    });
});

t.test("two sections asked in turn each keep their own destinations", () => {
    let expected = {
        [TEXT_A]: parsed(TEXT_A),
        [TEXT_B]: { domain: [ "c.example" ], domain_suffix: [ "d.example" ], domain_keyword: [ "beacon" ], domain_regex: [], ip_cidr: [ "2001:db8::1" ] }
    };
    for (let round = 0; round < 2; round++)
        for (let text in [ TEXT_A, TEXT_B ])
            t.eq(parsed(text), expected[text], text);
});

t.test("a caller that changes its lists does not change what the next caller gets", () => {
    let first = parsed(TEXT_A);
    push(first.ip_cidr, "198.51.100.0/24");
    first.domain_suffix[0] = "changed.example";
    t.eq(parsed(TEXT_A).ip_cidr, [ "192.0.2.0/24" ]);
    t.eq(parsed(TEXT_A).domain_suffix, [ "b.example" ]);
});

t.test("an international entry is punycoded for every domain kind", () => {
    let result = parsed("сайт.рф full:пример.испытание keyword:пример regex:^сайт[.]рф$");
    t.eq([ result.domain, result.domain_suffix, result.domain_keyword, result.domain_regex ], [
        [ "xn--e1afmkfd.xn--80akhbyknj4f" ],
        [ "xn--80aswg.xn--p1ai" ],
        [ "xn--e1afmkfd" ],
        [ "^xn--80aswg[.]xn--p1ai$" ]
    ]);
});

t.test("every address form is an address, and nothing else is", () => {
    for (let value in [ "192.0.2.1", "192.0.2.0/24", "0.0.0.0/0", "2001:db8::1", "2001:db8::/32", "::/0",
        "::ffff:192.0.2.1", "FD00::1" ])
        t.eq(parsed(value), only("ip_cidr", [ value ]), value);
    for (let value in [ "cafe.example", "dead.beef.example", "face" ])
        t.eq(parsed(value), only("domain_suffix", [ value ]), value);
});

t.test("a mistyped address is dropped instead of becoming a domain", () => {
    for (let value in [ "192.0.2", "192.0.2.256", "192.0.2.01", "192.0.2.0/33", "192.0.2.0/024", "2001:db8:::1",
        "2001:db8::/129", "fe80::1%eth0", "example.123", "full:192.0.2", "dead:beef" ])
        t.eq(parsed(value), only("domain", []), value);
});

t.test("a prefix makes a number a domain condition when that is what is meant", () => {
    t.eq(parsed("keyword:192.0.2").domain_keyword, [ "192.0.2" ]);
    t.eq(parsed("regex:^10[.]").domain_regex, [ "^10[.]" ]);
});

t.test("an entry is classified on its own and keeps its kind among others", () => {
    t.eq(rule.destination_kind_value(" 198.51.100.7 "), { kind: "ip_cidr", value: "198.51.100.7" });
    t.eq(rule.destination_kind_value("full:full:legacy.example"), { kind: "domain", value: "legacy.example" });
    t.eq(rule.destination_kind_value("unknown:example.org"), null);
    t.eq(rule.destination_kind_value("1.2.3"), null);
});

t.done();
