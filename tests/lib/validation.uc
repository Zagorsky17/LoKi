// Runs the config validator over a fixture and reports what it said.

let t = require("t");
let stub = require("stub");
let fixture = require("fixture");
let validator = require("config.validator");

function with_dns(data) {
    data = { ...(data ?? {}) };
    data.settings = { ...(data.settings ?? {}) };
    if (data.settings.dns_server == null)
        data.settings.dns_server = [ "77.88.8.8" ];
    if (data.settings.bootstrap_dns_server == null)
        data.settings.bootstrap_dns_server = [ "77.88.8.8" ];
    return data;
}

// { error, logs }: the reason the validator refused the configuration, or null,
// and the lines it logged on the way.
function run(data, overrides) {
    fixture.seed(with_dns(data));
    let logs = [];
    stub.commands([ stub.logger(logs) ]);
    let error = null;
    try {
        validator.validate(overrides);
    }
    catch (e) {
        error = e.message;
    }
    stub.restore();
    return { error, logs };
}

function accepts(data, overrides) {
    let result = run(data, overrides);
    if (result.error != null)
        t.fail("refused: " + result.error);
    return result;
}

function refuses(data, expected, overrides) {
    let result = run(data, overrides);
    if (result.error == null)
        t.fail("accepted, expected a refusal containing " + sprintf("%J", expected));
    t.contains(result.error, expected);
    return result;
}

return { with_dns, run, accepts, refuses };
