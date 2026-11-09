let t = require("t");
let domain = require("config.domain");

let label63 = "";
for (let i = 0; i < 63; i++)
    label63 += "a";

t.test("an ASCII domain is lowered and kept as written", () => {
    let cases = [
        [ "example.com", "example.com" ],
        [ "EXAMPLE.COM", "example.com" ],
        [ "MiXeD-123.Example.CO.uk", "mixed-123.example.co.uk" ],
        [ ".example.com", ".example.com" ],
        [ "123.456", "123.456" ],
        [ label63 + ".com", label63 + ".com" ],
        [ "xn--p1ai", "xn--p1ai" ]
    ];
    for (let entry in cases)
        t.eq(domain.suffix_to_ascii(entry[0]), entry[1], entry[0]);
});

t.test("an ASCII label that is not a valid label is refused, not encoded into one", () => {
    let refused = [
        "-abc.com", "-" + substr(label63, 0, 58) + ".com", "abc-.com", "a..com",
        "under_score.com", label63 + "a.com", "example.com.", ""
    ];
    for (let value in refused)
        t.eq(domain.suffix_to_ascii(value), null, value);
});

t.test("an international domain is punycoded in lowercase", () => {
    t.eq(domain.suffix_to_ascii("пример.рф"), "xn--e1afmkfd.xn--p1ai");
    t.eq(domain.suffix_to_ascii("ПРИМЕР.РФ"), "xn--e1afmkfd.xn--p1ai");
});

t.done();
