// The migration and the state service still run as programs with a mode argument; an unknown
// mode prints the usage and exits 1, so every requested mode is checked against its target.

let t = require("t");
let fs = require("fs");
let repo = require("repo");

const LIBRARY = repo.path("loki/files/usr/lib");

function library_files() {
    let pipe = fs.popen("cd '" + LIBRARY + "' && find . -name '*.uc' -type f | sort", "r");
    let found = trim(pipe.read("all"));
    pipe.close();
    return map(split(found, "\n"), (path) => substr(path, 2));
}

// Every literal a module compares a mode against.
function dispatched_modes(source) {
    let modes = [];
    for (let found in match(source, /[A-Za-z_]*(mode|MODE)[ \t]*[!=]=[ \t]*"([^"]+)"/g) ?? [])
        push(modes, found[2]);
    return modes;
}

// The modes a source runs a module with, as [ module, mode ] pairs:
//   ucode -L /usr/lib/loki /usr/lib/loki/config/migration.uc migrate
//   ucode -L "$library" "$library/service/state_service.uc" run
function requested_modes(source) {
    let requests = [];
    for (let found in match(source, /(\/usr\/lib\/loki|\$library)\/([a-z_]+\/[a-z_]+\.uc)"? ([a-z][a-z-]*)/g) ?? [])
        push(requests, [ found[2], found[3] ]);
    return requests;
}

t.test("every mode a module is run with is one it dispatches", () => {
    let modules = {};
    for (let path in library_files())
        modules[path] = dispatched_modes(fs.readfile(LIBRARY + "/" + path));

    let callers = [
        ...map(library_files(), (path) => [ path, LIBRARY + "/" + path ]),
        [ "loki/Makefile", repo.path("loki/Makefile") ],
        [ "build.sh", repo.path("build.sh") ],
        [ "install.sh", repo.path("install.sh") ],
        [ "init.d/loki", repo.path("loki/files/etc/init.d/loki") ],
        [ "init.d/loki-state", repo.path("loki/files/etc/init.d/loki-state") ]
    ];

    let checked = 0;
    let problems = [];
    for (let caller in callers)
        for (let request in requested_modes(fs.readfile(caller[1]))) {
            let known = modules[request[0]];
            if (known == null) {
                push(problems, caller[0] + " runs " + request[0] + ", which does not exist");
                continue;
            }
            checked++;
            if (index(known, request[1]) < 0)
                push(problems, caller[0] + " runs " + request[0] + " " + request[1] + ", which it does not dispatch");
        }

    t.ok(checked >= 5, "found the callers");
    t.eq(problems, []);
});

t.done();
