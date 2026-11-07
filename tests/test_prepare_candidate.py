#!/usr/bin/env python3
"""Check offline candidate snapshots without executing packages or their core."""

from contextlib import contextmanager
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import prepare_candidate as preparer
import test_preflight_manifest as fixtures


class CandidatePreparation(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.output = self.root / "prepared"
        self.ucode = shutil.which("ucode")
        self.assertIsNotNone(self.ucode, "native ucode is required")
        self.marker = self.root / "unexpected-execution"
        self.core_body = ("#!/bin/sh\ntouch " + str(self.marker) + "\n").encode()
        self.core = self.root / "loki-core"
        self.core.write_bytes(self.core_body)
        self.core.chmod(0o600)
        self.components = fixtures.ComponentPolicy().prepare(fixtures.ComponentPolicy().complete())
        self.selected = self.packages(self.components)

    def archive(self, rows):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w", format=tarfile.GNU_FORMAT) as archive:
            for name, mode, body in rows:
                entry = tarfile.TarInfo(name)
                entry.mode = mode
                entry.type = tarfile.DIRTYPE if body is None else tarfile.REGTYPE
                entry.size = 0 if body is None else len(body)
                archive.addfile(entry, None if body is None else io.BytesIO(body))
        return gzip.compress(stream.getvalue(), mtime=0)

    def packages(self, value):
        selected = {}
        for component in value["components"]:
            control = (f'Package: {component["package"]}\nVersion: {component["version"]}\n'
                       f'Architecture: {component["architecture"]}\n').encode()
            payload = [("." + item["path"], item["mode"], None if item["type"] == "directory" else
                        self.core_body if item["path"] == "/usr/bin/loki-core" else b"synthetic payload\n")
                       for item in component["files"]]
            data = self.archive([("debian-binary", 0o644, b"2.0\n"),
                                 ("control.tar.gz", 0o644, self.archive([("control", 0o644, control),
                                                                       ("postinst", 0o755, self.core_body)])),
                                 ("data.tar.gz", 0o644, self.archive(payload))])
            path = self.root / component["artifact"]["name"]
            path.write_bytes(data)
            path.chmod(0o600)
            selected[component["role"]] = path
        return selected

    def prepare(self, selected=None, core=None):
        return preparer.prepare(self.selected if selected is None else selected, self.core if core is None else core,
                                self.output, self.ucode)

    def command(self):
        command = [sys.executable, "-B", str(ROOT / "prepare_candidate.py"), "--output", str(self.output),
                   "--ucode-bin", self.ucode, "--core-binary", str(self.core)]
        for role, path in self.selected.items():
            command += ["--" + role, str(path)]
        return command

    def assert_snapshot(self, result, selected):
        self.assertEqual(json.loads((self.output / "candidate-prepared.json").read_bytes()), result)
        self.assertFalse(result["install_allowed"])
        self.assertFalse(result["origin_verified"])
        self.assertEqual(result["manifest_sha256"], hashlib.sha256((self.output / "candidate-manifest.json").read_bytes()).hexdigest())
        self.assertEqual((self.output / "candidate-core").read_bytes(), self.core_body)
        self.assertEqual(result["core"]["sha256"], hashlib.sha256(self.core_body).hexdigest())
        self.assertEqual(set(p.name for p in (self.output / "packages").iterdir()), {p.name for p in selected.values()})
        for original in selected.values():
            self.assertEqual((self.output / "packages" / original.name).read_bytes(), original.read_bytes())
        for path in [self.output, *self.output.rglob("*")]:
            self.assertEqual(path.stat().st_mode & 0o777,
                             0o700 if path.is_dir() or path.name == "candidate-core" else 0o600)
        self.assertFalse((self.output / ".candidate-prepared.tmp").exists())
        self.assertFalse(self.marker.exists(), "neither the packaged hook nor the candidate core may run")

    def test_complete_and_no_locale_sets_preserve_inputs_and_make_private_snapshots(self):
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_mode) for path in self.selected.values()}
        for locale in (True, False):
            selected = {role: path for role, path in self.selected.items() if locale or role != "locale"}
            result = self.prepare(selected)
            self.assert_snapshot(result, selected)
            shutil.rmtree(self.output)
        for path, values in before.items():
            self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_mode), values)

    def test_cli_success_and_competing_calls_publish_one_complete_snapshot(self):
        processes = [subprocess.Popen(self.command(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(2)]
        results = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=20)
            results.append((process.returncode, stdout, stderr))
        self.assertEqual(sorted(row[0] for row in results), [0, 2], results)
        success = next(row for row in results if row[0] == 0)
        self.assertEqual(success[2], "")
        self.assert_snapshot(json.loads(success[1]), self.selected)
        failed = next(row for row in results if row[0] == 2)
        self.assertEqual(failed[1], "")
        self.assertNotIn(str(self.root), failed[2])

    def test_existing_file_directory_and_symlink_are_never_replaced(self):
        foreign = self.root / "foreign"; foreign.write_text("keep")
        for kind in ("file", "directory", "symlink"):
            if kind == "file": self.output.write_text("keep")
            elif kind == "directory": self.output.mkdir(); (self.output / "keep").write_text("keep")
            else: self.output.symlink_to(foreign)
            with self.assertRaises(preparer.SourceError): self.prepare()
            self.assertEqual(foreign.read_text(), "keep")
            if kind == "directory": shutil.rmtree(self.output)
            else: self.output.unlink()

    def test_unsafe_parent_or_symlinked_parent_refuses_without_creating_output(self):
        self.root.chmod(0o777)
        try:
            with self.assertRaises(preparer.SourceError): self.prepare()
            self.assertFalse(self.output.exists())
        finally: self.root.chmod(0o700)
        link = self.root / "link"; link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(preparer.SourceError):
            preparer.prepare(self.selected, self.core, link / "prepared", self.ucode)
        self.assertFalse(self.output.exists())

    def test_links_fifo_writable_and_empty_inputs_are_refused_and_cleaned(self):
        for kind in ("symlink", "hardlink", "fifo", "writable", "empty"):
            path = self.root / "unsafe.ipk"
            if kind == "symlink": path.symlink_to(self.selected["backend"])
            elif kind == "hardlink": os.link(self.selected["backend"], path)
            elif kind == "fifo": os.mkfifo(path)
            else: path.write_bytes(b"" if kind == "empty" else b"synthetic"); path.chmod(0o666 if kind == "writable" else 0o600)
            with self.subTest(kind=kind), self.assertRaises((preparer.SourceError, preparer.catalog.InvalidCatalog)):
                self.prepare(dict(self.selected, backend=path))
            self.assertFalse(self.output.exists())
            path.unlink()

    def test_changed_input_is_pinned_and_partial_output_is_removed(self):
        real = preparer.input_file
        changed = self.selected["backend"]

        @contextmanager
        def changing(path, maximum):
            with real(path, maximum) as opened:
                yield opened
                if path == changed:
                    with path.open("ab") as stream: stream.write(b"synthetic-secret")

        with mock.patch.object(preparer, "input_file", changing), self.assertRaises(preparer.SourceError): self.prepare()
        self.assertFalse(self.output.exists())
        self.assertFalse(self.marker.exists())

    def test_missing_roles_foreign_paths_and_mismatched_versions_never_publish(self):
        with self.assertRaises(preparer.catalog.InvalidCatalog): self.prepare({"backend": self.selected["backend"]})
        self.assertFalse(self.output.exists())
        for change in ("foreign-path", "version", "private-mode"):
            value = fixtures.ComponentPolicy().prepare(fixtures.ComponentPolicy().complete())
            if change == "foreign-path": value["components"][0]["files"][0]["path"] = "/etc/banner"
            elif change == "version": value["components"][1]["version"] = "2.0.1"
            else: value["components"][0]["files"][1]["mode"] = 0o644
            with self.subTest(change=change), self.assertRaises(preparer.catalog.InvalidCatalog): self.prepare(self.packages(value))
            self.assertFalse(self.output.exists())

    def test_wrong_core_bytes_empty_and_oversized_core_cannot_publish(self):
        for body in (b"synthetic-secret", b"", self.core_body + b"extra"):
            self.core.write_bytes(body)
            with self.subTest(size=len(body)), self.assertRaises((preparer.SourceError, preparer.catalog.InvalidCatalog)): self.prepare()
            self.assertFalse(self.output.exists())
            self.assertFalse(self.marker.exists())

    def test_oversized_package_refuses_before_copy_or_archive_parsing(self):
        path = self.root / "oversized.ipk"
        with path.open("wb") as stream: stream.truncate(preparer.catalog.LIMIT + 1)
        path.chmod(0o600)
        with self.assertRaises(preparer.SourceError): self.prepare(dict(self.selected, backend=path))
        self.assertFalse(self.output.exists())

    def test_policy_timeout_or_rejection_never_leaves_a_completion_marker(self):
        for outcome in (subprocess.CompletedProcess([], 2, b"synthetic-secret"),
                        subprocess.TimeoutExpired("synthetic-secret", 10)):
            context = mock.patch.object(preparer.subprocess, "run", side_effect=outcome) if isinstance(outcome, Exception) else \
                mock.patch.object(preparer.subprocess, "run", return_value=outcome)
            with context, self.assertRaises((preparer.catalog.InvalidCatalog, subprocess.TimeoutExpired)): self.prepare()
            self.assertFalse(self.output.exists())

    def test_sigkill_leaves_no_complete_marker_and_retry_preserves_partial_data(self):
        waiting = self.root / "policy-waiting"
        tool = self.root / "blocking-policy"
        tool.write_text("#!/usr/bin/python3\nfrom pathlib import Path\nimport time\n"
                        + "Path(" + repr(str(waiting)) + ").touch()\ntime.sleep(30)\n")
        tool.chmod(0o700)
        command = self.command()
        command[command.index("--ucode-bin") + 1] = str(tool)
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 8
            while not waiting.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(waiting.exists(), "the controlled interruption must occur after package staging")
        finally:
            if process.poll() is None: os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=5)
        self.assertEqual(process.returncode, -signal.SIGKILL)
        self.assertTrue((self.output / "candidate-manifest.json").exists())
        self.assertFalse((self.output / "candidate-prepared.json").exists())
        before = (self.output / "candidate-manifest.json").read_bytes()
        with self.assertRaises(preparer.SourceError): self.prepare()
        self.assertEqual((self.output / "candidate-manifest.json").read_bytes(), before)
        self.assertFalse(self.marker.exists())

    def test_io_or_policy_tool_failure_removes_owned_output_and_cli_hides_paths(self):
        with mock.patch.object(preparer, "write_private", side_effect=OSError("synthetic-secret")), self.assertRaises(OSError): self.prepare()
        self.assertFalse(self.output.exists())
        self.selected["backend"].write_bytes(b"synthetic-secret truncated archive")
        result = subprocess.run(self.command(), capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "candidate-prepare: preparation-failed\n")
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Run candidate preparation checks only on Linux")
    unittest.main()
