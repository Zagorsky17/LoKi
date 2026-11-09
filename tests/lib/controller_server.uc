// controller_server.uc DIR PID: the process behind controller.uc. Its Unix socket is private
// to DIR, with readiness in DIR/port. It records requests and answers with DIR/reply: its raw
// text, or its status and body after delay_ms, then closes as an HTTP/1.0 server does. It leaves
// once the test process PID is gone.

let socket = require("socket");
let fs = require("fs");

let dir = ARGV[0];
let owner = ARGV[1];
let server = socket.listen({ path: dir + "/controller.sock" }, null, { socktype: socket.SOCK_STREAM }, 16);
fs.chmod(dir + "/controller.sock", 0600);
fs.writefile(dir + "/port.tmp", "unix");
fs.rename(dir + "/port.tmp", dir + "/port");

for (let count = 0; fs.access("/proc/" + owner); ) {
    let ready = socket.poll(1000, server);
    if (ready == null)
        break;
    if (ready[0][1] == 0)
        continue;
    let conn = server.accept();
    if (conn == null)
        continue;

    let received = "";
    while (index(received, "\r\n\r\n") < 0) {
        let chunk = conn.recv(4096);
        if (chunk == null || chunk == "")
            break;
        received += chunk;
    }
    let length_header = match(received, /\r\nContent-Length: ([0-9]+)\r\n/i);
    let need = index(received, "\r\n\r\n") + 4 + int(length_header?.[1] ?? 0);
    while (length(received) < need) {
        let chunk = conn.recv(4096);
        if (chunk == null || chunk == "")
            break;
        received += chunk;
    }
    fs.writefile(sprintf("%s/request.%04d", dir, count++), received);

    let reply = json(fs.readfile(dir + "/reply") ?? "{}");
    if (reply.delay_ms)
        sleep(reply.delay_ms);
    let text = reply.raw ?? sprintf("HTTP/1.0 %d Reply\r\nContent-Type: application/json\r\n\r\n%s", reply.status ?? 200, reply.body ?? "");
    while (length(text) > 0) {
        let sent = conn.send(text);
        if (sent == null || sent <= 0)
            break;
        text = substr(text, sent);
    }
    conn.close();
}
server.close();
