// Reads a file in the format UCI writes into the shape the tests describe a configuration in:
// { settings: {...}, section: [...], ... }. A quoted value may span lines, and '\'' is a quote,
// as uci export writes them; an anonymous section takes a cfgNNNNNN name and ".anonymous".

function unquote(text, position) {
    let value = "";
    let quote = substr(text, position, 1);
    position++;
    while (position < length(text)) {
        let c = substr(text, position, 1);
        if (c == quote) {
            if (quote == "'" && substr(text, position, 4) == "'\\''") {
                value += "'";
                position += 4;
                continue;
            }
            return [ value, position + 1 ];
        }
        value += c;
        position++;
    }
    die("unterminated quote");
}

function words(text) {
    let result = [];
    let position = 0;
    while (position < length(text)) {
        let c = substr(text, position, 1);
        if (c == " " || c == "\t") {
            position++;
            continue;
        }
        if (c == "\n" || c == "#") {
            if (c == "#")
                while (position < length(text) && substr(text, position, 1) != "\n")
                    position++;
            push(result, "\n");
            position++;
            continue;
        }
        if (c == "'" || c == "\"") {
            let parsed = unquote(text, position);
            push(result, { value: parsed[0] });
            position = parsed[1];
            continue;
        }
        let start = position;
        while (position < length(text) && !(substr(text, position, 1) in [ " ", "\t", "\n" ]))
            position++;
        push(result, { value: substr(text, start, position - start) });
    }
    return result;
}

function parse(text) {
    let data = {};
    let current = null;
    let anonymous = 0;
    let line = [];
    let finish = () => {
        if (length(line) == 0)
            return;
        let keyword = line[0];
        if (keyword == "config") {
            current = { ".type": line[1] };
            if (line[2] != null)
                current[".name"] = line[2];
            else {
                current[".name"] = sprintf("cfg%06x", ++anonymous);
                current[".anonymous"] = true;
            }
            if (line[1] == "settings")
                data.settings = current;
            else
                data[line[1]] = [ ...(data[line[1]] ?? []), current ];
        }
        else if (keyword == "option")
            current[line[1]] = line[2];
        else if (keyword == "list")
            current[line[1]] = [ ...(current[line[1]] ?? []), line[2] ];
        line = [];
    };
    for (let word in words(text)) {
        if (word == "\n")
            finish();
        else
            push(line, word.value);
    }
    finish();
    for (let type_name, sections in data)
        if (type_name != "settings")
            for (let section in sections)
                delete section[".type"];
    if (data.settings != null)
        delete data.settings[".type"];
    return data;
}

return { parse };
