let t = require("t");
let urltest = require("singbox.urltest");

t.test("a filter written for RE2 is translated into the expression ucode compiles", () => {
    for (let pair in [
        [ "^DE\\d$", "^DE[0-9]$", "" ],
        [ "(?i)^de|nl", "^de|nl", "i" ],
        [ "(?:DE|NL)\\d+", "(DE|NL)[0-9]+", "" ],
        [ "(?P<country>DE)\\s\\w", "(DE)[[:space:]][0-9A-Za-z_]", "" ],
        [ "[\\d\\-_]x", "[0-9_-]x", "" ],
        [ "[^\\w\\]]", "[^]0-9A-Za-z_]", "" ],
        [ "\\D\\W\\S", "[^0-9][^0-9A-Za-z_][^[:space:]]", "" ],
        [ "a+?b*?c??", "a+b*c?", "" ],
        [ "\\QDE.1+\\E$", "DE\\.1\\+$", "" ],
        [ "\\x41\\.\\/", "A\\.\\/", "" ],
        [ "\\bDE\\b", "\\bDE\\b", "" ],
        [ "[[:alpha:]]{2}", "[[:alpha:]]{2}", "" ],
        [ "🇩🇪|Германия", "🇩🇪|Германия", "" ]
    ]) {
        let translated = urltest.translate(pair[0]);
        t.eq([ translated.source, translated.flags ], [ pair[1], pair[2] ], pair[0]);
    }
});

t.test("what has no translation is refused, not matched another way", () => {
    for (let pattern in [ "\\pL", "a(?i)b", "(?=DE)", "(DE)\\1", "[\\D]", "\\x{41}", "\\xE9", "[DE", "(?s).", "(" ])
        t.throws(() => urltest.compile(pattern), pattern);
});

t.test("a refusal says what is wrong with the pattern", () => {
    let native_error = t.throws(() => regexp("(")).message;
    t.ok(type(native_error) == "string" && length(native_error) > 0);
    for (let pair in [ [ "[DE", "missing ]" ], [ "\\pL", "unsupported escape \\p" ], [ "(?=DE)", "unsupported group (?=D" ], [ "(", native_error ] ])
        t.eq(t.throws(() => urltest.compile(pair[0])).message, pair[1], pair[0]);
});

t.test("manual servers join a group by the same pattern provider nodes do", () => {
    let tags = [ "Main/DE1", "Main/DEd", "Main/de 2", "Main/NL1" ];
    let names = { "Main/DE1": "DE1", "Main/DEd": "DEd", "Main/de 2": "de 2", "Main/NL1": "NL1" };
    t.eq(urltest.regex_matching_tag_array(tags, names, [ "^DE\\d$" ]), [ "Main/DE1" ]);
    t.eq(urltest.regex_matching_tag_array(tags, names, [ "(?i)^de\\s?\\d" ]), [ "Main/DE1", "Main/de 2" ]);
    t.eq(urltest.regex_matching_tag_array(tags, names, [ "(?:NL|FR)\\d" ]), [ "Main/NL1" ]);
    t.eq(urltest.regex_matching_tag_array(tags, names, [ "\\pL" ]), [], "a refused pattern matches nothing");
});

t.done();
