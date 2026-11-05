let t = require("t");
let ubus = require("ubus");
let auth = require("service.gateway_auth");
let fs = require("fs");
let stub = require("stub");

const SID = "1234567890abcdef1234567890abcdef";

t.test("invalid and anonymous credentials cannot cause a session lookup", () => {
    for (let input in [ null, false, 12, [], {}, "", SID, SID + " x", SID + " r\n", " " + SID + "r",
        "1234567890ABCDEF1234567890ABCDEF r", "00000000000000000000000000000000 r", SID + " r\u0000", SID + " r extra" ]) {
        ubus.__reset();
        t.eq(auth.check(input), { token: "0", code: 1 });
        t.eq(ubus.__calls(), []);
    }
});

t.test("read and write select only their fixed existing RPC permission", () => {
    for (let role in [ "r", "w" ]) {
        ubus.__reset();
        ubus.__on("session.access", { access: true });
        t.eq(auth.check(SID + " " + role), { token: "1", code: 0 });
        t.eq(ubus.__calls(), [ { object: "session", method: "access", args: {
            ubus_rpc_session: SID, scope: "ubus", object: "loki", function: role == "r" ? "rpc_read" : "rpc_write"
        } } ]);
    }
});

t.test("denied read and write requests never become authorized", () => {
    ubus.__reset();
    ubus.__on("session.access", { access: false });
    t.eq(auth.check(SID + " r"), { token: "0", code: 1 });
    t.eq(auth.check(SID + " w"), { token: "0", code: 1 });
});

t.test("rpcd disappearance and unexpected reply shapes fail closed", () => {
    for (let reply in [ null, false, true, [], {}, { access: 1 }, { access: "true" },
        { access: true, extra: "SYNTHETIC_PRIVATE_CANARY" }, ubus.__failure("SYNTHETIC_PRIVATE_CANARY") ]) {
        ubus.__reset();
        ubus.__on("session.access", reply);
        let result = auth.check(SID + " r");
        t.eq(result, { token: "E", code: 2 });
        t.eq(index(sprintf("%J", result), "SYNTHETIC_PRIVATE_CANARY"), -1);
        t.eq(index(sprintf("%J", result), SID), -1);
    }
    ubus.__reset();
    ubus.__refuse_connections();
    t.eq(auth.check(SID + " r"), { token: "E", code: 2 });
});

t.test("each request checks the live permission again after revoke or role change", () => {
    ubus.__reset();
    ubus.__on("session.access", { access: true });
    t.eq(auth.check(SID + " w").code, 0);
    ubus.__on("session.access", { access: false });
    t.eq(auth.check(SID + " w").code, 1);
    ubus.__on("session.access", { access: true });
    t.eq(auth.check(SID + " r").code, 0);
    t.eq(length(ubus.__calls()), 3);
});

t.test("connection and call exceptions produce only a fixed failure", () => {
    let original = ubus.connect;
    ubus.connect = () => { die("SYNTHETIC_PRIVATE_CANARY"); };
    t.eq(auth.check(SID + " r"), { token: "E", code: 2 });
    let disconnected = 0;
    ubus.connect = () => ({ call: () => { die("SYNTHETIC_PRIVATE_CANARY"); },
        disconnect: () => { disconnected++; } });
    t.eq(auth.check(SID + " r"), { token: "E", code: 2 });
    t.eq(disconnected, 1);
    ubus.connect = original;
});

t.test("a failed disconnect cannot turn an uncertain request into success", () => {
    let original = ubus.connect;
    let args;
    ubus.connect = (path, seconds) => {
        args = [ path, seconds ];
        return { call: () => ({ access: true }), disconnect: () => { die("SYNTHETIC_PRIVATE_CANARY"); } };
    };
    t.eq(auth.check(SID + " r"), { token: "E", code: 2 });
    t.eq(args, [ null, 2 ]);
    ubus.connect = original;
});

t.test("stdio reads one excess byte and returns only the fixed token and exit code", () => {
    let original = fs.stdin;
    for (let sample in [
        { input: SID + " r", reply: { access: true }, token: "1", code: 0 },
        { input: SID + " w", reply: { access: true }, token: "1", code: 0 },
        { input: SID + " r", reply: { access: false }, token: "0", code: 1 },
        { input: SID + " r", reply: null, token: "E", code: 2 },
        { input: SID + " r\n", reply: { access: true }, token: "0", code: 1 },
        { input: null, reply: { access: true }, token: "0", code: 1 },
        { fail: true, token: "E", code: 2 }
    ]) {
        let reads = [];
        fs.stdin = { read: (limit) => {
            push(reads, limit);
            if (sample.fail)
                die("SYNTHETIC_PRIVATE_CANARY");
            return sample.input;
        } };
        ubus.__reset();
        ubus.__on("session.access", sample.reply);
        let captured;
        try { captured = stub.capture(() => auth.main()); }
        catch (e) { fs.stdin = original; die(e.message); }
        fs.stdin = original;
        t.eq(reads, [ 35 ]);
        t.eq(captured, { result: sample.code, stdout: sample.token, stderr: "" });
        if (sample.fail || sample.input == null || length(sample.input) != 34)
            t.eq(ubus.__calls(), []);
    }
});

t.done();
