#!/usr/bin/env python3
"""Catalog selected final package payloads without installing or running hooks."""

import argparse
import hashlib
import gzip
import json
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import sys
import tarfile
import tempfile

ROLES = {"backend": "loki", "luci": "luci-app-loki", "locale": "luci-i18n-loki-ru", "core": "loki-core"}
LIMIT = 536870912


class InvalidCatalog(ValueError):
    pass


def need(condition, reason):
    if not condition:
        raise InvalidCatalog(reason)


def token(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.+~-]{0,127}", value)


def payload_path(name, directory=False):
    need(isinstance(name, str), "member-path-invalid")
    if name.startswith("./"):
        name = name[2:]
    need(not name.startswith(("/", "./")), "member-path-invalid")
    if directory and name.endswith("/"):
        name = name[:-1]
    if name in ("", "."):
        need(directory, "member-root-not-directory")
        return "/"
    need(len(name) < 4096 and re.fullmatch(r"[A-Za-z0-9_.+@/-]+", name) and
         all(part not in ("", ".", "..") for part in name.split("/")), "member-path-invalid")
    return "/" + name


def file_entry(path, directory, mode, uid, gid, size=0, digest=None):
    need(type(mode) is int and 0 <= mode <= 0o777 and not mode & 0o022 and
         type(uid) is int and uid == 0 and type(gid) is int and gid == 0, "member-permissions-invalid")
    need(type(size) is int and 0 <= size <= LIMIT and (not directory or size == 0), "member-size-limit")
    need(directory or isinstance(digest, str) and re.fullmatch(r"[a-f0-9]{64}", digest), "member-digest-invalid")
    return {"path": path, "type": "directory" if directory else "file", "mode": mode, "uid": uid, "gid": gid,
            "size": 0 if directory else size, "sha256": None if directory else digest}


def digest_stream(stream, size):
    digest = hashlib.sha256()
    remaining = size
    while remaining:
        block = stream.read(min(65536, remaining))
        need(block, "member-truncated")
        digest.update(block)
        remaining -= len(block)
    return digest.hexdigest()



def zero_tail(archive):
    # Do not let a second archive hide after the first end marker.
    total = 0
    while True:
        block = archive.fileobj.read(65536)
        if not block:
            return
        total += len(block)
        need(total <= 1048576 and not block.strip(b"\0"), "archive-trailing-content")


def control_identity(stream):
    fields, previous, seen, total = {}, None, set(), 0
    field_names = set()
    with gzip.GzipFile(fileobj=stream) as compressed, tarfile.open(fileobj=compressed, mode="r|") as archive:
        for member in archive:
            need((member.isfile() or member.isdir()) and not member.pax_headers and not member.sparse,
                 "control-member-type-unsupported")
            name = payload_path(member.name, member.isdir())
            need(name not in seen, "control-member-duplicate")
            seen.add(name)
            total += member.size
            need(0 <= member.size <= 1048576 and total <= 1048576, "control-size-limit")
            if name != "/control":
                continue
            need(member.isfile(), "control-not-file")
            content = archive.extractfile(member).read().decode("utf-8")
            need(not re.search(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", content), "control-bytes-invalid")
            for line in content.splitlines():
                if line.startswith((" ", "\t")):
                    need(previous and previous not in ("Package", "Version", "Architecture"), "control-identity-folded")
                    fields[previous] += " " + line.strip()
                    continue
                if not line:
                    continue
                key, separator, value = line.partition(":")
                need(separator and re.fullmatch(r"[A-Za-z][A-Za-z0-9-]*", key), "control-field-invalid")
                normalized = key.lower()
                # opkg recognizes sensitive field prefixes, including unexpected suffixes.
                need(normalized not in field_names and not any(normalized.startswith(field) and normalized != field
                     for field in ("package", "version", "architecture", "depends", "provides", "conflicts", "replaces",
                                   "alternatives", "pre-depends", "recommends", "suggests")), "control-field-invalid")
                field_names.add(normalized)
                fields[key] = value.strip()
                previous = key
        zero_tail(archive)
    need(all(key in fields for key in ("Package", "Version", "Architecture")), "control-identity-missing")
    need(all(not value.strip() for key, value in fields.items() if key.lower() in ("provides", "conflicts", "replaces", "alternatives")),
         "artifact-replacement-metadata")
    need(all(not value.strip() for key, value in fields.items() if key.lower() in ("pre-depends", "recommends", "suggests")),
         "artifact-extra-dependency-metadata")
    return {"package": fields["Package"], "version": fields["Version"], "architecture": fields["Architecture"]}


def read_ipk(path):
    entries, seen, total, identity = [], set(), 0, None
    with gzip.open(path, "rb") as compressed, tarfile.open(fileobj=compressed, mode="r|") as outer:
        for member in outer:
            need(member.isfile(), "ipk-outer-type-unsupported")
            name = member.name.removeprefix("./")
            need(name in ("debian-binary", "control.tar.gz", "data.tar.gz") and name not in seen,
                 "ipk-outer-member-invalid")
            seen.add(name)
            need(0 <= member.size <= LIMIT, "ipk-outer-size-limit")
            stream = outer.extractfile(member)
            if name == "debian-binary":
                need(member.size == 4 and stream.read() == b"2.0\n", "ipk-version-unsupported")
            elif name == "control.tar.gz":
                identity = control_identity(stream)
            else:
                paths = set()
                with gzip.GzipFile(fileobj=stream) as data, tarfile.open(fileobj=data, mode="r|") as payload:
                    for child in payload:
                        need((child.isfile() or child.isdir()) and not child.pax_headers and not child.sparse,
                             "member-type-unsupported")
                        target = payload_path(child.name, child.isdir())
                        need(target not in paths, "member-path-duplicate")
                        paths.add(target)
                        need(len(paths) <= 4096 and 0 <= child.size <= LIMIT, "member-count-or-size-limit")
                        total += child.size
                        need(total <= LIMIT, "payload-size-limit")
                        digest = digest_stream(payload.extractfile(child), child.size) if child.isfile() else None
                        entries.append(file_entry(target, child.isdir(), child.mode, child.uid, child.gid, child.size, digest))
                    zero_tail(payload)
        zero_tail(outer)
    need(seen == {"debian-binary", "control.tar.gz", "data.tar.gz"} and identity, "ipk-incomplete")
    return identity, entries


def tool_limits():
    for kind, limit in ((resource.RLIMIT_CORE, 0), (resource.RLIMIT_CPU, 15),
                        (resource.RLIMIT_AS, 268435456), (resource.RLIMIT_FSIZE, 8388608)):
        soft, hard = resource.getrlimit(kind)
        resource.setrlimit(kind, (limit if soft == resource.RLIM_INFINITY else min(soft, limit),
                                  limit if hard == resource.RLIM_INFINITY else min(hard, limit)))


def cli_limits():
    # tarfile consumes GNU/PAX metadata before yielding a size-checkable TarInfo.
    def exhausted(signum, frame):
        raise InvalidCatalog("artifact-resource-limit")

    signal.signal(signal.SIGXCPU, exhausted)
    for kind, soft, hard in ((resource.RLIMIT_AS, 268435456, 268435456),
                             (resource.RLIMIT_CPU, 30, 31), (resource.RLIMIT_CORE, 0, 0)):
        previous_soft, previous_hard = resource.getrlimit(kind)
        if previous_hard != resource.RLIM_INFINITY:
            hard = min(hard, previous_hard)
        if previous_soft != resource.RLIM_INFINITY:
            soft = min(soft, previous_soft)
        resource.setrlimit(kind, (min(soft, hard), hard))


def apk_command(apk, arguments):
    # Bound tool output and time without buffering arbitrary scripts in Python memory.
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as error:
        result = subprocess.run([apk, "--no-network", "--allow-untrusted", *arguments],
                                stdin=subprocess.DEVNULL, stdout=output, stderr=error,
                                env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"}, timeout=20, preexec_fn=tool_limits)
        need(result.returncode == 0, "apk-verification-or-dump-failed")
        output.seek(0)
        data = output.read(4194305)
        need(len(data) <= 4194304, "apk-output-limit")
        return data


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        need(key not in value, "apk-json-duplicate-key")
        value[key] = item
    return value


def apk_entries(data):
    need(type(data) is dict and type(data.get("info")) is dict and type(data.get("paths")) is list,
         "apk-schema-invalid")
    info = data["info"]
    for key in ("provides", "replaces"):
        value = info.get(key)
        # Native SDK packages expose their own generic ABI name; it cannot name another component.
        own_alias = key == "provides" and info.get("arch") == "noarch" and info.get("name") in (
            ROLES["backend"], ROLES["luci"], ROLES["locale"]) and value == [info["name"] + "-any"]
        need(value is None or (type(value) is list and (not value or own_alias)), "artifact-replacement-metadata")
    priority = info.get("provider-priority")
    need(priority is None or (type(priority) is int and priority == 0), "artifact-replacement-metadata")
    for key in ("install-if", "recommends"):
        value = info.get(key)
        need(value is None or (type(value) is list and not value), "artifact-extra-dependency-metadata")
    layer = info.get("layer")
    need(layer is None or (type(layer) is int and layer == 0), "artifact-layer-metadata")
    dependencies = info.get("depends", [])
    need(type(dependencies) is list and len(dependencies) <= 128, "control-dependencies-invalid")
    for dependency in dependencies:
        need(isinstance(dependency, str) and 0 < len(dependency) <= 8192 and
             re.fullmatch(r"[!-~]+", dependency), "control-dependencies-invalid")
        need(not dependency.startswith("!"), "artifact-replacement-metadata")
    identity = {"package": info.get("name"), "version": info.get("version"), "architecture": info.get("arch")}
    entries, paths, total = [], set(), 0

    def add(item, path, directory):
        nonlocal total
        need(type(item) is dict and type(item.get("acl")) is dict, "apk-acl-missing")
        need("target" not in item, "member-type-unsupported")
        acl = item["acl"]
        need(set(acl) == {"mode", "user", "group"} and acl["user"] == acl["group"] == "root",
             "apk-acl-unsupported")
        need(path not in paths, "member-path-duplicate")
        paths.add(path)
        need(len(paths) <= 4096, "member-count-or-size-limit")
        entry = file_entry(path, directory, acl["mode"], 0, 0, item.get("size", 0), item.get("hash"))
        total += entry["size"]
        need(total <= LIMIT, "payload-size-limit")
        entries.append(entry)

    for directory in data["paths"]:
        need(type(directory) is dict and set(directory) <= {"name", "acl", "files"}, "apk-directory-schema-invalid")
        name = directory.get("name", "")
        need(isinstance(name, str) and name != "." and not name.startswith("./") and not name.endswith("/"),
             "apk-directory-name-invalid")
        parent = payload_path(name, True)
        add(directory, parent, True)
        need(type(directory.get("files", [])) is list, "apk-files-invalid")
        for file in directory.get("files", []):
            need(type(file) is dict and set(file) <= {"name", "acl", "size", "mtime", "hash", "target"},
                 "apk-file-schema-invalid")
            name = file.get("name")
            need(isinstance(name, str) and "/" not in name, "apk-file-name-invalid")
            target = payload_path(parent.lstrip("/") + ("/" if parent != "/" else "") + name)
            add(file, target, False)
    return identity, entries


def read_package(role, path, apk):
    path = Path(path)
    need(path.is_file() and not path.is_symlink(), "artifact-not-regular")
    path = path.absolute()
    before = path.stat()
    need(token(path.name) and path.suffix in (".ipk", ".apk"), "artifact-invalid")
    need(0 < before.st_size <= LIMIT, "artifact-size-limit")
    with path.open("rb") as stream:
        before_hash = digest_stream(stream, before.st_size)
    if path.suffix == ".ipk":
        identity, entries = read_ipk(path)
    else:
        need(apk and os.path.isabs(apk), "apk-tool-required")
        apk_command(apk, ["verify", str(path)])
        data = apk_command(apk, ["adbdump", "--format", "json", str(path)])
        identity, entries = apk_entries(json.loads(data, object_pairs_hook=unique_object))
    after = path.stat()
    need((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
         (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), "artifact-changed")
    with path.open("rb") as stream:
        need(digest_stream(stream, after.st_size) == before_hash, "artifact-changed")
    need(identity["package"] == ROLES[role] and token(identity["version"]) and token(identity["architecture"]),
         "artifact-identity-invalid")
    need(entries, "artifact-payload-empty")
    return dict(identity, role=role, format=path.suffix[1:], artifact={"name": path.name, "size": before.st_size,
                "sha256": before_hash}, files=sorted(entries, key=lambda entry: entry["path"]))


def build(selected, apk=None):
    need(selected and set(selected) <= set(ROLES), "component-set-invalid")
    components = [read_package(role, selected[role], apk) for role in sorted(selected)]
    need(len({item["format"] for item in components}) == 1, "mixed-package-formats")
    need(len({item["artifact"]["name"] for item in components}) == len(components), "artifact-name-duplicate")
    paths, count, total = {}, 0, 0
    for component in components:
        for entry in component["files"]:
            count += 1
            total += entry["size"]
            need(count <= 4096 and total <= LIMIT, "catalog-count-or-size-limit")
            previous = paths.get(entry["path"])
            need(previous is None or entry["type"] == "directory" and previous == entry, "catalog-owner-ambiguous")
            paths[entry["path"]] = entry
    for path in paths:
        for parent in Path(path).parents:
            if str(parent) != "/":
                need(paths.get(str(parent), {}).get("type") == "directory", "catalog-parent-invalid")
    data = json.dumps({"schema": 1, "components": components}, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n"
    need(len(data) <= 2097152, "catalog-byte-limit")
    return data


class Once(argparse.Action):
    def __call__(self, parser, namespace, value, option_string=None):
        if getattr(namespace, self.dest) is not None:
            parser.error("component option repeated")
        setattr(namespace, self.dest, value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for role in ROLES:
        parser.add_argument("--" + role, action=Once)
    parser.add_argument("--apk-bin")
    parser.add_argument("--output", type=Path, default=Path("candidate-manifest.json"))
    args = parser.parse_args()
    selected = {role: getattr(args, role) for role in ROLES if getattr(args, role) is not None}
    try:
        try:
            cli_limits()
        except (OSError, ValueError):
            raise InvalidCatalog("artifact-resource-limit-unavailable") from None
        need(not args.output.is_symlink() and args.output.resolve() not in {Path(p).resolve() for p in selected.values()},
             "output-path-invalid")
        data = build(selected, args.apk_bin)
        descriptor, temporary = tempfile.mkstemp(prefix=".candidate-manifest-", dir=args.output.parent)
        try:
            with os.fdopen(descriptor, "w") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
                os.fchmod(stream.fileno(), 0o644)
            os.replace(temporary, args.output)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    except MemoryError:
        os.write(2, b"candidate-manifest: artifact-resource-limit\n")
        return 2
    except (OSError, EOFError, ValueError, tarfile.TarError, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, InvalidCatalog) else "artifact-read-or-tool-failed"
        print("candidate-manifest: " + reason, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Build candidate manifests only on Linux")
    raise SystemExit(main())
