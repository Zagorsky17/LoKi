let preflight = require("service.preflight");
let result = preflight.collect("/");
print(sprintf("%J\n", result));
exit(result.result == "conflict" ? 1 : 2);
