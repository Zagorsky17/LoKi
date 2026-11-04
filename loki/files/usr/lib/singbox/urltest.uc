// loki-core filters provider nodes with RE2 and the section's own servers are filtered here, so
// a pattern is translated into the POSIX expression ucode compiles. What has no translation is
// refused: regcomp takes \d as a digit on musl and as d on glibc, and knows neither (?i) nor (?:.

let common = require("core.common");

let as_string = common.as_string;
let array_or_empty = common.array_or_empty;
let object_or_empty = common.object_or_empty;

const CLASSES = {
    d: [ "0-9", false ], D: [ "0-9", true ],
    w: [ "0-9A-Za-z_", false ], W: [ "0-9A-Za-z_", true ],
    s: [ "[:space:]", false ], S: [ "[:space:]", true ]
};
const SPECIAL = "\\.^$|?*+()[]{}";

function literal(character) {
    return index(SPECIAL, character) >= 0 ? "\\" + character : character;
}

// { text, end } from just past the "[". POSIX reads a backslash in brackets as itself, so
// escapes are resolved here and "]", "^" and "-" placed where they are literal.
function translate_bracket(pattern, i) {
    let negated = substr(pattern, i, 1) == "^";
    if (negated)
        i++;
    let items = "", close = false, caret = false, dash = false;
    for (let first = true; i < length(pattern); first = false) {
        let character = substr(pattern, i, 1);
        if (character == "]" && !first)
            return { text: "[" + (negated ? "^" : "") + (close ? "]" : "") + items + (caret ? "^" : "") + (dash ? "-" : "") + "]", end: i + 1 };
        if (character == "[" && substr(pattern, i + 1, 1) == ":") {
            let end = index(substr(pattern, i), ":]");
            if (end < 0)
                die("unterminated character class");
            items += substr(pattern, i, end + 2);
            i += end + 2;
            continue;
        }
        if (character != "\\") {
            if (character == "]")
                close = true;
            else if (character == "^")
                caret = true;
            else
                items += character;
            i++;
            continue;
        }
        let escaped = substr(pattern, i + 1, 1);
        let class = CLASSES[escaped];
        if (class != null && !class[1])
            items += class[0];
        else if (escaped == "]")
            close = true;
        else if (escaped == "^")
            caret = true;
        else if (escaped == "-")
            dash = true;
        else if (escaped != "" && index(SPECIAL + "/", escaped) >= 0)
            items += escaped;
        else
            die("unsupported escape \\" + escaped + " in brackets");
        i += 2;
    }
    die("missing ]");
}

// { source, flags } for ucode's regexp(), or dies with what cannot be matched
// the way RE2 matches it.
function translate(pattern) {
    pattern = as_string(pattern);
    let flags = "";
    if (substr(pattern, 0, 4) == "(?i)") {
        flags = "i";
        pattern = substr(pattern, 4);
    }

    let result = "";
    for (let i = 0; i < length(pattern);) {
        let character = substr(pattern, i, 1);
        if (character == "(" && substr(pattern, i + 1, 1) == "?") {
            let named = match(substr(pattern, i), /^\(\?P?<[A-Za-z_][A-Za-z0-9_]*>/);
            if (substr(pattern, i + 2, 1) == ":") {
                result += "(";
                i += 3;
            }
            else if (named != null) {
                result += "(";
                i += length(named[0]);
            }
            else
                die("unsupported group " + substr(pattern, i, 4));
            continue;
        }
        if (character == "[") {
            let bracket = translate_bracket(pattern, i + 1);
            result += bracket.text;
            i = bracket.end;
            continue;
        }
        // A lazy quantifier finds a match exactly where a greedy one does.
        if (character == "?" && index("*+?}", substr(pattern, i - 1, 1)) >= 0 && i > 0 && substr(result, -2) != "\\" + substr(pattern, i - 1, 1)) {
            i++;
            continue;
        }
        if (character != "\\") {
            result += character;
            i++;
            continue;
        }

        let escaped = substr(pattern, i + 1, 1);
        let class = CLASSES[escaped];
        if (class != null)
            result += "[" + (class[1] ? "^" : "") + class[0] + "]";
        else if (escaped == "Q") {
            let end = index(substr(pattern, i + 2), "\\E");
            let quoted = end < 0 ? substr(pattern, i + 2) : substr(pattern, i + 2, end);
            for (let j = 0; j < length(quoted); j++)
                result += literal(substr(quoted, j, 1));
            i += 2 + length(quoted) + (end < 0 ? 0 : 2);
            continue;
        }
        else if (escaped == "x" && match(substr(pattern, i + 2, 2), /^[0-7][0-9A-Fa-f]$/)) {
            result += literal(chr(hex(substr(pattern, i + 2, 2))));
            i += 4;
            continue;
        }
        else if (escaped == "A")
            result += "^";
        else if (escaped == "z")
            result += "$";
        else if (escaped == "b" || escaped == "B")
            result += "\\" + escaped;
        else if (escaped == "t")
            result += "\t";
        else if (escaped == "n")
            result += "\n";
        else if (escaped != "" && index(SPECIAL + "/-", escaped) >= 0)
            result += "\\" + escaped;
        else
            die("unsupported escape \\" + escaped);
        i += 2;
    }
    return { source: result, flags };
}

// The translation is inside the try: ucode hands a try the exception of a `let` initializer
// right before it, with a function in place of the error.
function compile(pattern) {
    try {
        let translated = translate(pattern);
        return regexp(translated.source, translated.flags);
    }
    catch (e) {
        die(replace(e.message, /^[^:]*: /, ""));
    }
}

function regex_matching_tag_array(tags, names, regexes) {
    tags = array_or_empty(tags);
    names = object_or_empty(names);
    let compiled = [];
    for (let pattern in array_or_empty(regexes)) {
        try {
            if (as_string(pattern) != "")
                push(compiled, compile(pattern));
        }
        catch (e) {
        }
    }

    let result = [];
    for (let tag in tags) {
        let name = names[tag];
        name = name == null || as_string(name) == "" ? tag : as_string(name);
        for (let filter in compiled)
            if (match(name, filter) != null) {
                push(result, tag);
                break;
            }
    }
    return result;
}

return { translate, compile, regex_matching_tag_array };
