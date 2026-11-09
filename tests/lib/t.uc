// Assertions and the test registry every test file uses.

let tests = [];

function canonical(value) {
    let kind = type(value);
    if (kind == "object") {
        let parts = [];
        for (let key in sort(keys(value)))
            push(parts, sprintf("%J", key) + ":" + canonical(value[key]));
        return "{" + join(",", parts) + "}";
    }
    if (kind == "array") {
        let parts = [];
        for (let item in value)
            push(parts, canonical(item));
        return "[" + join(",", parts) + "]";
    }
    return sprintf("%J", value);
}

const ASSERTION = "assertion: ";

function fail(message) {
    die(ASSERTION + message);
}

function describe(value) {
    return type(value) == "string" ? sprintf("%J", value) : canonical(value);
}

function eq(actual, expected, message) {
    if (canonical(actual) != canonical(expected))
        fail((message ? message + ": " : "") + "expected " + describe(expected) + ", got " + describe(actual));
}

function ok(condition, message) {
    if (!condition)
        fail(message || "expected a true condition");
}

function contains(haystack, needle, message) {
    let found = false;
    if (type(haystack) == "array") {
        for (let item in haystack)
            if (canonical(item) == canonical(needle))
                found = true;
    }
    else
        found = index("" + haystack, "" + needle) >= 0;

    if (!found)
        fail((message ? message + ": " : "") + describe(haystack) + " does not contain " + describe(needle));
}

function excludes(haystack, needle, message) {
    let found = false;
    if (type(haystack) == "array") {
        for (let item in haystack)
            if (canonical(item) == canonical(needle))
                found = true;
    }
    else
        found = index("" + haystack, "" + needle) >= 0;

    if (found)
        fail((message ? message + ": " : "") + describe(haystack) + " contains " + describe(needle));
}

function matches(value, pattern, message) {
    if (match("" + value, pattern) == null)
        fail((message ? message + ": " : "") + describe(value) + " does not match " + pattern);
}

// The error a function raised, or a failure when it returned normally.
function throws(fn, message) {
    try {
        fn();
    }
    catch (e) {
        return e;
    }
    fail(message || "expected an exception");
}

function test(name, fn) {
    push(tests, { name, fn });
}

function error_text(e) {
    let message = type(e) == "object" ? "" + e.message : "" + e;
    if (substr(message, 0, length(ASSERTION)) == ASSERTION)
        return substr(message, length(ASSERTION));

    let where = [];
    for (let frame in (type(e) == "object" ? e.stacktrace : null) ?? [])
        push(where, sprintf("%s:%d", frame.filename ?? "?", frame.line ?? 0));
    return message + (length(where) ? " (" + join(" < ", where) + ")" : "");
}

// Runs every registered test and exits with the number of failures, so the
// runner only has to look at the status.
function done() {
    let failures = 0;
    for (let entry in tests) {
        try {
            entry.fn();
        }
        catch (e) {
            failures++;
            warn("FAIL ", sourcepath(1) || "", ": ", entry.name, "\n    ", replace(error_text(e), /\n/g, "\n    "), "\n");
        }
    }
    exit(failures > 0 ? 1 : 0);
}

return { test, eq, ok, contains, excludes, matches, throws, fail, canonical, done };
