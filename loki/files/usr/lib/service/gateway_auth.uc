// Keep session credentials on stdin, outside process arguments and the environment.
let fs = require("fs");
let ubus = require("ubus");
let constants = require("core.constants");

function check(input) {
    if (type(input) != "string" || length(input) != 34 || !match(input, /^[a-f0-9]{32} [rw]$/) ||
        substr(input, 0, 32) == "00000000000000000000000000000000")
        return { token: "0", code: 1 };

    let result = { token: "E", code: 2 };
    let connection;
    try {
        connection = ubus.connect(null, 2);
        if (connection != null) {
            let reply = connection.call("session", "access", {
                ubus_rpc_session: substr(input, 0, 32), scope: "ubus", object: constants.LOKI_RPC_OBJECT,
                function: substr(input, 33) == "r" ? "rpc_read" : "rpc_write"
            });
            if (type(reply) == "object" && length(keys(reply)) == 1 && type(reply.access) == "bool")
                result = reply.access ? { token: "1", code: 0 } : { token: "0", code: 1 };
        }
    }
    catch (e) {}
    if (connection != null) {
        try { connection.disconnect(); }
        catch (e) { result = { token: "E", code: 2 }; }
    }
    return result;
}

function main() {
    let input;
    try { input = fs.stdin.read(35); }
    catch (e) { print("E"); return 2; }
    let result = check(input);
    print(result.token);
    return result.code;
}

return { check, main };
