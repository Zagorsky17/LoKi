// The trusted offline entry and installed Components page share the same worker.
let common = require("core.common");
let lock = require("service.lock");
let update = require("service.update");
let owner = common.own_pid();
if (ARGV[0] == "prepare" && length(ARGV) == 1) {
    if (!lock.acquire(update.paths.lock, owner)) exit(1);
    lock.release(update.paths.lock, owner);
    exit(0);
}
if (!lock.adopt(update.paths.lock, owner)) {
    print('{"success":false,"reason":"transaction-busy-or-unsafe-lock"}\n');
    exit(1);
}
let result = ARGV[0] == "recover" && length(ARGV) == 1 ? update.run_recovery() :
    length(ARGV) == 3 ? update.run(ARGV[1], ARGV[0], ARGV[2]) :
    { success: false, reason: "invalid-transaction-arguments" };
lock.release(update.paths.lock, owner);
print(sprintf("%J\n", result));
exit(result.success ? 0 : 1);
