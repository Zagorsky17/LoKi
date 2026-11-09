"""Verify bootstrap export without executing candidate binaries or package hooks."""
import copy
import gzip
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_binaries", ROOT / "core/release_binaries.py")
EXPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORT)
VERSION = "1.14.4-r10"


class BootstrapBinaries(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.packages = self.root / "packages"
        self.packages.mkdir()
        self.output = self.root / "export"
        self.marker = self.root / "unexpected-execution"
        self.body = ("#!/bin/sh\ntouch " + str(self.marker) + "\n").encode()
        self.binary = self.root / "binary"
        self.binary.write_bytes(self.body)
        self.binary.chmod(0o755)

    def archive(self, entries):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w", format=tarfile.GNU_FORMAT) as archive:
            for name, body, mode, uid in entries:
                entry = tarfile.TarInfo(name)
                entry.mode, entry.uid, entry.gid = mode, uid, 0
                entry.type = tarfile.DIRTYPE if body is None else tarfile.REGTYPE
                entry.size = 0 if body is None else len(body)
                archive.addfile(entry, None if body is None else io.BytesIO(body))
        return gzip.compress(stream.getvalue(), mtime=0)

    def package(self, architecture="x86_64", version=VERSION, variant="base", body=None, mode=0o755, uid=0):
        control = f"Package: loki-core\nVersion: {version}\nArchitecture: {architecture}\n".encode()
        payload = [(".", None, 0o755, 0), ("./usr", None, 0o755, 0), ("./usr/bin", None, 0o755, 0),
                   ("./usr/bin/loki-core", self.body if body is None else body, mode, uid)]
        path = self.packages / f"loki-core_{version}_{variant}_{architecture}.ipk"
        path.write_bytes(self.archive([("debian-binary", b"2.0\n", 0o644, 0),
                                      ("control.tar.gz", self.archive([("control", control, 0o644, 0)]), 0o644, 0),
                                      ("data.tar.gz", self.archive(payload), 0o644, 0)]))
        path.chmod(0o644)
        return path

    def collect(self, binaries=None):
        return EXPORT.collect(self.packages, self.output, VERSION, binaries or [self.binary])

    def test_each_profile_exports_package_identical_bytes_with_safe_modes(self):
        first = self.package()
        second = self.package("aarch64_cortex-a53", variant="tiny")
        original = self.binary.read_bytes(), self.binary.stat().st_mtime_ns
        mask = os.umask(0o002)
        try:
            exported = self.collect()
        finally:
            os.umask(mask)
        self.assertEqual({p.name for p in exported}, {p.stem+".bin" for p in (first, second)})
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)
        for path in exported:
            self.assertEqual(path.read_bytes(), self.body)
            self.assertEqual(path.stat().st_mode & 0o777, 0o644)
            self.assertEqual(path.stat().st_nlink, 1)
        self.assertEqual((self.binary.read_bytes(), self.binary.stat().st_mtime_ns), original)
        self.assertFalse(self.marker.exists())

    def test_full_release_budget_scales_while_small_exports_keep_the_existing_limit(self):
        budgets = []
        for count in (2, 64, 128):
            for index in range(count):
                self.package(architecture="cpu" + str(index))
            arguments = ["release_binaries.py", str(self.packages), str(self.output), VERSION, str(self.binary)]
            with mock.patch.object(sys, "argv", arguments), mock.patch.object(EXPORT.catalog, "cli_limits") as limits, \
                    mock.patch("sys.stdout", new_callable=io.StringIO):
                self.assertEqual(EXPORT.main(), 0)
            budgets.append(limits.call_args.kwargs.get("cpu_seconds", 30))
            self.assertEqual(len(list(self.output.iterdir())), count)
            self.assertFalse(self.marker.exists())
            for path in self.output.iterdir(): path.unlink()
            self.output.rmdir()
            for path in self.packages.iterdir(): path.unlink()
        self.assertEqual(budgets[0], 30)
        self.assertGreater(budgets[1], budgets[0])
        self.assertLess(budgets[1], budgets[2])
        self.assertEqual(budgets[2], 300)

    def test_mismatched_or_unpackaged_binaries_refuse_without_partial_export(self):
        self.package(body=b"different packaged binary")
        with self.assertRaisesRegex(EXPORT.catalog.InvalidCatalog, "core-binary-content-mismatch"):
            self.collect()
        self.assertFalse(self.output.exists())
        self.package()
        extra = self.root / "unpackaged"
        extra.write_bytes(b"unpackaged synthetic-secret")
        extra.chmod(0o644)
        with self.assertRaisesRegex(EXPORT.catalog.InvalidCatalog, "core-binary-unpackaged-input"):
            self.collect([self.binary, extra])
        self.assertFalse(self.output.exists())
        self.assertFalse(self.marker.exists())

    def test_version_architecture_variant_and_payload_permissions_are_checked(self):
        for fields in ({"version": "1.14.4-r9"}, {"architecture": "all"}, {"architecture": "noarch"},
                       {"variant": "unknown"}, {"mode": 0o644}, {"uid": 1}, {"body": b""}):
            with self.subTest(fields=fields):
                package = self.package(**fields)
                with self.assertRaises(EXPORT.catalog.InvalidCatalog):
                    self.collect()
                self.assertFalse(self.output.exists())
                package.unlink()

    def test_existing_output_or_symlink_never_replaces_foreign_data(self):
        self.package()
        foreign = self.root / "foreign"
        foreign.mkdir()
        marker = foreign / "keep"
        marker.write_bytes(b"keep")
        for kind in ("file", "directory", "symlink"):
            if kind == "file":
                self.output.write_bytes(b"keep")
            elif kind == "directory":
                self.output.mkdir()
            else:
                self.output.symlink_to(foreign, target_is_directory=True)
            with self.subTest(kind=kind), self.assertRaises(EXPORT.SourceError):
                self.collect()
            self.assertEqual(marker.read_bytes(), b"keep")
            if kind == "directory":
                self.output.rmdir()
            else:
                self.output.unlink()

    def test_copy_failure_or_failed_readback_cleans_only_owned_export(self):
        self.package()
        foreign = self.root / "foreign"
        foreign.write_bytes(b"keep")
        for failure in (OSError("synthetic-secret"), (len(self.body), "0"*64)):
            with self.subTest(failure=str(failure)), mock.patch.object(EXPORT, "copy_input", side_effect=
                    failure if isinstance(failure, BaseException) else None, return_value=failure):
                with self.assertRaises((OSError, EXPORT.catalog.InvalidCatalog)):
                    self.collect()
            self.assertFalse(self.output.exists())
            self.assertEqual(foreign.read_bytes(), b"keep")
            self.assertEqual(self.binary.read_bytes(), self.body)
        original = EXPORT.copy_input
        def corrupted(source, target, limit):
            result = original(source, target, limit)
            target.write_bytes(b"corrupted destination")
            return result
        with mock.patch.object(EXPORT, "copy_input", side_effect=corrupted), self.assertRaisesRegex(
                EXPORT.catalog.InvalidCatalog, "core-binary-copy-mismatch"):
            self.collect()
        self.assertFalse(self.output.exists())
        self.assertEqual(foreign.read_bytes(), b"keep")

    def test_replaced_export_path_is_preserved_after_failure(self):
        self.package()
        foreign = self.root / "foreign"
        foreign.mkdir()
        (foreign / "keep").write_bytes(b"keep")
        def replaced(source, target, limit):
            self.output.rename(self.root / "owned-abandoned")
            self.output.symlink_to(foreign, target_is_directory=True)
            raise OSError("synthetic-secret")
        with mock.patch.object(EXPORT, "copy_input", side_effect=replaced), self.assertRaises(OSError):
            self.collect()
        self.assertTrue(self.output.is_symlink())
        self.assertEqual((foreign / "keep").read_bytes(), b"keep")

    def test_unsafe_inputs_refuse_promptly_and_cli_masks_paths(self):
        self.package()
        unsafe = self.root / "synthetic-secret"
        for kind in ("symlink", "hardlink", "fifo", "writable", "missing"):
            if kind == "symlink": unsafe.symlink_to(self.binary)
            elif kind == "hardlink": os.link(self.binary, unsafe)
            elif kind == "fifo": os.mkfifo(unsafe)
            elif kind == "writable": unsafe.write_bytes(self.body); unsafe.chmod(0o666)
            result = subprocess.run([sys.executable, "-B", str(ROOT / "core/release_binaries.py"),
                str(self.packages), str(self.output), VERSION, str(unsafe)], capture_output=True, text=True, timeout=5)
            with self.subTest(kind=kind):
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertTrue(result.stderr.startswith("core-binaries: "))
                self.assertNotIn("synthetic-secret", result.stderr)
                self.assertNotIn(str(self.root), result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertFalse(self.output.exists())
            if unsafe.exists() or unsafe.is_symlink(): unsafe.unlink()

    def test_apk_only_and_matching_pairs_use_verified_apk_metadata(self):
        package = self.package()
        component = EXPORT.catalog.read_package("core", package, None)
        apk = package.with_suffix(".apk")
        apk.write_bytes(b"synthetic APK metadata fixture")
        apk.chmod(0o644)
        original = EXPORT.catalog.read_package
        def read(role, path, tool):
            if path.suffix == ".ipk": return original(role, path, tool)
            self.assertEqual(tool, "/synthetic/apk")
            return copy.deepcopy(component)
        for apk_only in (False, True):
            if apk_only: package.unlink()
            with mock.patch.object(EXPORT.shutil, "which", return_value="/synthetic/apk"), mock.patch.object(
                    EXPORT.catalog, "read_package", side_effect=read):
                exported = self.collect()
            self.assertEqual(len(exported), 1)
            self.assertEqual(exported[0].read_bytes(), self.body)
            exported[0].unlink(); self.output.rmdir()

    def test_mismatched_package_formats_refuse_and_missing_apk_tool_does_not_publish(self):
        package = self.package()
        component = EXPORT.catalog.read_package("core", package, None)
        apk = package.with_suffix(".apk"); apk.write_bytes(b"synthetic APK"); apk.chmod(0o644)
        alternate = self.root / "alternate"; alternate.write_bytes(b"alternate"); alternate.chmod(0o644)
        original = EXPORT.catalog.read_package
        def read(role, path, tool):
            if path.suffix == ".ipk": return original(role, path, tool)
            changed = copy.deepcopy(component)
            entry = next(e for e in changed["files"] if e["path"] == "/usr/bin/loki-core")
            entry.update(size=9, sha256=hashlib.sha256(b"alternate").hexdigest())
            return changed
        with mock.patch.object(EXPORT.shutil, "which", return_value="/synthetic/apk"), mock.patch.object(
                EXPORT.catalog, "read_package", side_effect=read), self.assertRaisesRegex(
                EXPORT.catalog.InvalidCatalog, "core-binary-format-mismatch"):
            self.collect([self.binary, alternate])
        self.assertFalse(self.output.exists())
        with mock.patch.object(EXPORT.shutil, "which", return_value=None), self.assertRaisesRegex(
                EXPORT.catalog.InvalidCatalog, "apk-tool-required"):
            self.collect()
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
