#!/usr/bin/env python3
"""Prepare an offline Linux candidate snapshot; never install or execute its core."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile

import build_candidate_manifest as catalog

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "core"))
from module_sources import SourceError, input_file, output_directory


def write_private(path, data):
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def copy_input(source, destination, maximum):
    with input_file(Path(source), maximum) as (stream, before):
        catalog.need(before.st_size > 0, "candidate-input-empty")
        digest, total = hashlib.sha256(), 0
        with os.fdopen(os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as output:
            while block := stream.read(65536):
                total += len(block)
                catalog.need(total <= before.st_size, "candidate-input-changed")
                digest.update(block)
                output.write(block)
            output.flush()
            os.fsync(output.fileno())
        catalog.need(total == before.st_size, "candidate-input-changed")
    return total, digest.hexdigest()


def prepare(selected, core_binary, output, ucode, apk=None):
    catalog.need({"backend", "luci", "core"} <= set(selected) <= set(catalog.ROLES), "candidate-component-set-incomplete")
    output = Path(output).absolute()
    output_directory(output)
    output.mkdir(mode=0o700)
    created = output.lstat()
    try:
        packages = output / "packages"
        packages.mkdir(mode=0o700)
        copied, total = {}, 0
        for role, path in sorted(selected.items()):
            path = Path(path)
            catalog.need(catalog.token(path.name) and path.suffix in (".ipk", ".apk"), "artifact-invalid")
            target = packages / path.name
            size, _ = copy_input(path, target, catalog.LIMIT - total)
            total += size
            copied[role] = target
        manifest = catalog.build(copied, apk)
        write_private(output / "candidate-manifest.json", manifest.encode())
        expression = ('let fs=require("fs");let r=require("service.preflight_manifest").parse(fs.readfile(ARGV[0]));'
                      'if(r.error!=null||r.component_policy?.state!="checked")exit(2);print("checked");')
        catalog.need(Path(ucode).is_absolute(), "candidate-ucode-tool-required")
        checked = subprocess.run([str(ucode), "-L", str(ROOT / "loki/files/usr/lib"), "-e", expression,
                                  str(output / "candidate-manifest.json")], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10,
                                 env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
        catalog.need(checked.returncode == 0 and checked.stdout == b"checked", "candidate-component-policy-unverified")
        component = next(item for item in json.loads(manifest)["components"] if item["role"] == "core")
        expected = next(item for item in component["files"] if item["path"] == "/usr/bin/loki-core")
        size, digest = copy_input(core_binary, output / "candidate-core", expected["size"])
        catalog.need((size, digest) == (expected["size"], expected["sha256"]), "candidate-core-content-mismatch")
        (output / "candidate-core").chmod(0o700)
        result = {"schema": 1, "install_allowed": False, "origin_verified": False,
                  "manifest_sha256": hashlib.sha256(manifest.encode()).hexdigest(),
                  "core": {"path": "candidate-core", "sha256": digest, "size": size,
                           "version": component["version"], "architecture": component["architecture"]}}
        # A complete marker is published last; an interrupted directory is never admission evidence.
        write_private(output / ".candidate-prepared.tmp", (json.dumps(result, sort_keys=True) + "\n").encode())
        os.replace(output / ".candidate-prepared.tmp", output / "candidate-prepared.json")
        return result
    except BaseException:
        current = output.lstat()
        if stat.S_ISDIR(current.st_mode) and (current.st_dev, current.st_ino) == (created.st_dev, created.st_ino):
            shutil.rmtree(output)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for role in catalog.ROLES:
        parser.add_argument("--" + role, type=Path, action=catalog.Once, required=role != "locale")
    parser.add_argument("--core-binary", type=Path, action=catalog.Once, required=True)
    parser.add_argument("--ucode-bin", type=Path, action=catalog.Once, required=True)
    parser.add_argument("--apk-bin", type=Path, action=catalog.Once)
    parser.add_argument("--output", type=Path, action=catalog.Once, required=True)
    args = parser.parse_args()
    try:
        catalog.cli_limits()
        result = prepare({role: getattr(args, role) for role in catalog.ROLES if getattr(args, role) is not None},
                         args.core_binary, args.output, args.ucode_bin, args.apk_bin)
        print(json.dumps(result, sort_keys=True))
    except catalog.InvalidCatalog as error:
        print("candidate-prepare: " + str(error), file=sys.stderr)
        return 2
    except SourceError:
        print("candidate-prepare: unsafe-input-or-output", file=sys.stderr)
        return 2
    except (OSError, EOFError, ValueError, MemoryError, tarfile.TarError, shutil.Error, subprocess.SubprocessError):
        print("candidate-prepare: preparation-failed", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Prepare candidate snapshots only on Linux")
    raise SystemExit(main())
