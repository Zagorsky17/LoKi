let fs = require("fs");

const DIRECTORY_ENTRY_LIMIT = 16384;

function same_node(a, b) {
    return a != null && b != null && a.type == b.type && a.inode == b.inode &&
        a.dev.major == b.dev.major && a.dev.minor == b.dev.minor && a.uid == b.uid &&
        a.mode == b.mode && a.nlink == b.nlink && a.size == b.size &&
        a.mtime == b.mtime && a.ctime == b.ctime;
}

function absence(parent, name, before, budget) {
    // A failed lstat cannot distinguish ENOENT from permission or I/O errors in this binding.
    fs.error();
    let directory = fs.opendir(parent);
    if (directory == null)
        return "candidate-directory-read-failed";
    let reason = "candidate-path-absent";
    try {
        while (true) {
            if (budget.entries >= DIRECTORY_ENTRY_LIMIT) {
                reason = "candidate-directory-entry-limit";
                break;
            }
            fs.error();
            let entry = directory.read();
            let error = fs.error();
            if (entry == null) {
                if (error != null) reason = "candidate-directory-read-failed";
                break;
            }
            budget.entries++;
            if (entry == name) {
                reason = "candidate-path-stat-unavailable";
                break;
            }
        }
    }
    catch (e) { reason = "candidate-directory-read-failed"; }
    try { if (directory.close() !== true) reason = "candidate-directory-read-failed"; }
    catch (e) { reason = "candidate-directory-read-failed"; }
    if (!same_node(before, fs.lstat(parent)))
        return "candidate-parent-changed";
    return reason;
}

function inspect(root, target, expected, budget) {
    let base = fs.lstat(root || "/");
    let owner = root == "" ? 0 : base?.uid;
    if (base?.type != "directory" || base.uid != owner || (base.mode & 0022) != 0)
        return { state: "incomplete", reason: "candidate-root-unsafe" };
    let parents = [];
    let finish = (result) => {
        for (let parent in parents)
            if (!same_node(parent.stat, fs.lstat(parent.path)))
                return { state: "incomplete", reason: "candidate-parent-changed" };
        return result;
    };
    let path = root;
    let parts = split(target, "/");
    for (let i = 1; i < length(parts); i++) {
        let parent = path || "/";
        let before = fs.lstat(parent);
        if (before?.type == "link")
            return finish({ state: "incomplete", reason: "candidate-parent-symlink" });
        if (before?.type != "directory")
            return finish({ state: before == null ? "incomplete" : "conflict", reason: "candidate-parent-type-conflict" });
        if (before.uid != owner || (before.mode & 0022) != 0)
            return finish({ state: "incomplete", reason: "candidate-parent-unsafe" });
        push(parents, { path: parent, stat: before });
        if (parts[i] == "") continue; // The catalog may include the shared root directory.
        path += "/" + parts[i];
        let node = fs.lstat(path);
        if (node == null) {
            let reason = absence(parent, parts[i], before, budget);
            return finish({ state: reason == "candidate-path-absent" ? "checked" : "incomplete", reason });
        }
        let leaf = i == length(parts) - 1;
        if (node.type == "link")
            return finish({ state: leaf ? "conflict" : "incomplete", reason: leaf ? "candidate-path-symlink" : "candidate-parent-symlink" });
        if (!leaf) continue;
        if (node.type != expected)
            return finish({ state: "conflict", reason: "candidate-target-type-conflict" });
        if (node.uid != owner || (node.mode & 0022) != 0 || (node.type == "file" && node.nlink != 1))
            return finish({ state: "incomplete", reason: "candidate-target-unsafe" });
        if (!same_node(node, fs.lstat(path)))
            return finish({ state: "incomplete", reason: "candidate-target-changed" });
        return finish({ state: expected == "directory" ? "checked" : "incomplete",
            reason: expected == "directory" ? "candidate-directory-safe" : "candidate-existing-file-origin-unverified" });
    }
    return finish({ state: "checked", reason: "candidate-directory-safe" });
}

function collect(root, targets) {
    root = root == "/" ? "" : root;
    let observations = [];
    let budget = { entries: 0 };
    for (let target in sort(keys(targets))) {
        let result = inspect(root, target, targets[target], budget);
        push(observations, { path: target, state: result.state, reason: result.reason });
    }
    return observations;
}

return { collect, same_node };
