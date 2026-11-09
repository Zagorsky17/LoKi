// A stand-in for the ucode resolv module: a test says what a query answers and reads what was
// asked.

let answer = null;
let asked = [];

// fn(names, options) returns the reply query() gives; the list returned records every query.
function __answer(fn) {
    answer = fn;
    asked = [];
    return asked;
}

function query(names, options) {
    push(asked, { names, options });
    if (answer == null)
        die("unexpected DNS query: " + join(", ", names));
    return answer(names, options);
}

return {
    query,
    error: function() { return null; },
    __answer
};
