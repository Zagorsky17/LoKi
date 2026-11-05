let preflight = require("service.preflight");
let result = preflight.collect("/", ARGV[0], ARGV[1], ARGV[2], ARGV[3]);
print(sprintf("%J\n", result));
exit(result.result == "conflict" ? 1 : 2);
