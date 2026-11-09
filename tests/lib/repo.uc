// Paths into the repository, for a test that reads a file the package ships.

let fs = require("fs");

let root = fs.realpath(sourcepath(0, true) + "/../..");

function path(relative) {
    return root + "/" + relative;
}

return { root, path };
