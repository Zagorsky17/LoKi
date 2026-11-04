// ucode resolves names at call time, so a call to a function declared further down, or to one
// nobody defines, fails only when that branch runs on the router; both are read off the sources.

let t = require("t");
let fs = require("fs");
let repo = require("repo");

const LIBRARY = repo.path("loki/files/usr/lib");
const KEYWORDS = [ "if", "else", "for", "while", "switch", "try", "catch", "return", "function" ];

function library_files() {
    let pipe = fs.popen("find '" + LIBRARY + "' -name '*.uc' -type f | sort", "r");
    let found = trim(pipe.read("all"));
    pipe.close();
    return split(found, "\n");
}

function relative(path) {
    return substr(path, length(LIBRARY) + 1);
}

function builtin(name) {
    return exists(global, name);
}

// A name followed by `(` and not preceded by a dot; brackets get a space after them first, so a
// call nested right inside another is not swallowed.
function calls(line) {
    let result = [];
    for (let found in match(replace(line, /\(/g, "( "), /(^|[^.A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(/g) ?? [])
        if (index(KEYWORDS, found[2]) < 0)
            push(result, found[2]);
    return result;
}

// The line each top-level function, let and const is declared on.
function declarations(lines) {
    let declared = {};
    for (let number, line in lines) {
        let found = match(line, /^(function|let|const) ([A-Za-z_][A-Za-z0-9_]*)/);
        if (found && declared[found[2]] == null)
            declared[found[2]] = number;
    }
    return declared;
}

let files = library_files();

t.test("the library is found", () => {
    t.ok(length(files) > 20);
});

t.test("a function calls only what is declared above it", () => {
    let problems = [];
    for (let path in files) {
        let lines = split(fs.readfile(path), "\n");
        let declared = declarations(lines);
        let current = null;
        for (let number, line in lines) {
            let starts = match(line, /^function ([A-Za-z_][A-Za-z0-9_]*)\(/);
            if (starts)
                current = { name: starts[1], line: number };
            if (current == null)
                continue;
            for (let name in calls(line))
                if (!builtin(name) && declared[name] != null && declared[name] > current.line)
                    push(problems, sprintf("%s:%d: %s() calls %s(), declared at line %d",
                        relative(path), number + 1, current.name, name, declared[name] + 1));
        }
    }
    t.eq(problems, []);
});

t.test("a program's dispatch calls only what its module defines", () => {
    let checked = 0;
    let problems = [];
    for (let path in files) {
        let lines = split(fs.readfile(path), "\n");
        let start = null;
        for (let number, line in lines)
            if (start == null && match(line, /^let mode = ARGV/))
                start = number;
        if (start == null)
            continue;

        checked++;
        let defined = declarations(lines);
        for (let number = start; number < length(lines); number++) {
            let local = match(lines[number], /\blet ([A-Za-z_][A-Za-z0-9_]*) =/);
            if (local)
                defined[local[1]] = number;
            for (let name in calls(lines[number]))
                if (!builtin(name) && defined[name] == null)
                    push(problems, sprintf("%s:%d calls %s(), which the module does not define", relative(path), number + 1, name));
        }
    }
    t.ok(checked > 0, "found a dispatch");
    t.eq(problems, []);
});

t.done();
