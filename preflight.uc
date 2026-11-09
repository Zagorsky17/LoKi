let preflight = require("service.preflight");
let result = preflight.collect("/", ARGV[0], ARGV[1], ARGV[2], ARGV[3], ARGV[4] == "" ? null : ARGV[4]);
print(sprintf("%J\n", result));
exit(result.result == "checked" && result.complete === true && result.install_allowed === true ? 0 : result.result == "conflict" ? 1 : 2);
