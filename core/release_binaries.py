#!/usr/bin/env python3
"""Export bootstrap binaries only when they match the final core package payloads."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import sys
import tarfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_candidate_manifest as catalog
from prepare_candidate import copy_input
from module_sources import SourceError, input_file, output_directory


def fingerprint(path):
    with input_file(path, catalog.LIMIT) as (stream, info):
        return info.st_size, hashlib.file_digest(stream, "sha256").hexdigest()


def collect(directory, output, version, binaries):
    catalog.need(catalog.token(version), "core-binary-version-invalid")
    packages = sorted(Path(directory).glob("loki-core_*.ipk")) + sorted(Path(directory).glob("loki-core_*.apk"))
    catalog.need(packages and binaries, "core-binary-input-missing")
    apk = shutil.which("apk")
    catalog.need(not any(p.suffix == ".apk" for p in packages) or apk is not None, "apk-tool-required")
    apk = str(Path(apk).absolute()) if apk else None
    available = {fingerprint(Path(path)): Path(path) for path in binaries}
    output = Path(output).absolute()
    output_directory(output)
    output.mkdir(mode=0o700)
    created = output.lstat()
    try:
        used, exported = set(), []
        for package in packages:
            with input_file(package, catalog.LIMIT):
                component = catalog.read_package("core", package, apk)
            architecture = component["architecture"]
            catalog.need(component["version"] == version and architecture not in ("all", "noarch") and
                         re.fullmatch(re.escape("loki-core_" + version + "_") + r"(base|full|tiny)_" +
                                      re.escape(architecture), package.stem), "core-binary-package-identity-invalid")
            expected = next((entry for entry in component["files"] if entry["path"] == "/usr/bin/loki-core"), None)
            catalog.need(expected is not None and expected["type"] == "file" and expected["size"] > 0 and expected["mode"] == 0o755 and
                         expected["uid"] == expected["gid"] == 0, "core-binary-payload-invalid")
            identity = expected["size"], expected["sha256"]
            catalog.need(identity in available, "core-binary-content-mismatch")
            target = output / (package.stem + ".bin")
            if target.exists():
                catalog.need(fingerprint(target) == identity, "core-binary-format-mismatch")
                used.add(identity)
                continue
            catalog.need(copy_input(available[identity], target, expected["size"]) == identity and
                         fingerprint(target) == identity, "core-binary-copy-mismatch")
            target.chmod(0o644)
            used.add(identity)
            exported.append(target)
        catalog.need(used == set(available), "core-binary-unpackaged-input")
        return exported
    except BaseException:
        if (not output.is_symlink() and output.is_dir() and
                (output.lstat().st_dev, output.lstat().st_ino) == (created.st_dev, created.st_ino)):
            shutil.rmtree(output)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packages", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("version")
    parser.add_argument("binaries", nargs="+", type=Path)
    args = parser.parse_args()
    try:
        catalog.cli_limits()
        exported = collect(args.packages, args.output, args.version, args.binaries)
    except MemoryError:
        os.write(2, b"core-binaries: artifact-resource-limit\n")
        return 2
    except (OSError, EOFError, ValueError, SourceError, tarfile.TarError) as error:
        reason = str(error) if isinstance(error, (catalog.InvalidCatalog, SourceError)) else "core-binary-read-or-copy-failed"
        print("core-binaries: " + reason, file=sys.stderr)
        return 2
    print("Exported %d verified bootstrap binaries" % len(exported))
    return 0


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Export core binaries only on Linux")
    raise SystemExit(main())
