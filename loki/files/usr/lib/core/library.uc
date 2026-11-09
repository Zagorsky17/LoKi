let dir = getenv("LOKI_LIB") || "/usr/lib/loki";

function set_dir(path) {
    dir = path;
}

function get_dir() {
    return dir;
}

return { set_dir, dir: get_dir };
