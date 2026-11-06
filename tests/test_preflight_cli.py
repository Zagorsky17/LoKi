#!/usr/bin/env python3
"""Native Linux entry and shell boundary checks; no package manager is invoked."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PreflightCLI(unittest.TestCase):
    def run_check(self, command, environment=None):
        result = subprocess.run(command, capture_output=True, text=True, timeout=20, env=environment)
        self.assertIn(result.returncode, (1, 2), result.stderr)
        self.assertEqual(result.stderr, "")
        report = json.loads(result.stdout)
        self.assertFalse(report["install_allowed"])
        self.assertFalse(report["complete"])
        self.assertEqual(report["result"], "conflict" if result.returncode == 1 else "incomplete")
        return report

    def harness(self, directory, entry=None):
        # Linux installs ucode in /usr/local/bin; only the fixed tool directory differs.
        binary = shutil.which("ucode")
        self.assertIsNotNone(binary)
        tree = Path(directory)
        script = (ROOT / "preflight.sh").read_text()
        script = script.replace("PATH=/usr/sbin:/usr/bin:/sbin:/bin\n",
                                f"PATH={Path(binary).parent}:/usr/sbin:/usr/bin:/sbin:/bin\n", 1)
        (tree / "preflight.sh").write_text(script)
        (tree / "preflight.uc").write_text(entry if entry is not None else (ROOT / "preflight.uc").read_text())
        (tree / "loki/files").mkdir(parents=True)
        (tree / "loki/files/usr").symlink_to(ROOT / "loki/files/usr", target_is_directory=True)
        (tree / "loki/files/etc/config").mkdir(parents=True)
        (tree / "loki/files/etc/config/loki").write_text("config settings 'settings'\n")
        return ["/bin/sh", str(tree / "preflight.sh")]

    def test_original_native_entry(self):
        binary = shutil.which("ucode")
        self.assertIsNotNone(binary, "ucode is required; do not skip the native check")
        command = [binary, "-L", str(ROOT / "loki/files/usr/lib"), str(ROOT / "preflight.uc")]
        for _ in range(2):
            report = self.run_check(command)
            pending = {item["kind"] for item in report["observations"] if item["reason"] == "not-implemented"}
            self.assertTrue({"configuration", "core-check", "nft-persisted"} <= pending)
            self.assertTrue(any(item["kind"] == "nft-loaded" for item in report["observations"]))

    def test_wrapper_rejects_arguments_without_echoing_them(self):
        report = self.run_check(["/bin/sh", str(ROOT / "preflight.sh"), "--force=synthetic-secret"])
        self.assertEqual(report["reason"], "unsupported-arguments")
        self.assertNotIn("synthetic-secret", json.dumps(report))

    def test_wrapper_does_not_trust_caller_path(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "executed"
            for name in ("ucode", "timeout", "opkg", "apk", "nft", "ip", "date"):
                path = Path(directory) / name
                path.write_text(f'#!/bin/sh\ntouch "{marker}"\nexit 0\n')
                path.chmod(0o700)
            environment = dict(os.environ, PATH=directory)
            self.run_check(["/bin/sh", str(ROOT / "preflight.sh")], environment)
            self.assertFalse(marker.exists())

    def test_wrapper_with_fixed_linux_tool_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            before = set(Path("/tmp").glob("loki-preflight.*"))
            report = self.run_check(self.harness(directory))
            self.assertIn("observations", report)
            self.assertNotIn("reason", report, "missing native UCI must be an observation, not a reader failure")
            self.assertTrue(any(item["kind"] == "configuration" and item["reason"] != "not-implemented"
                                for item in report["observations"]))
            self.assertEqual(set(Path("/tmp").glob("loki-preflight.*")), before)

    def test_wrapper_masks_reader_exception(self):
        with tempfile.TemporaryDirectory() as directory:
            report = self.run_check(self.harness(directory, 'die("synthetic-secret");\n'))
            self.assertEqual(report["reason"], "reader-failed-or-timeout")

    def test_wrapper_deadline(self):
        with tempfile.TemporaryDirectory() as directory:
            before = set(Path("/tmp").glob("loki-preflight.*"))
            entry = 'require("fs").writefile(ARGV[2] + "/synthetic-secret", "synthetic-secret"); sleep(30000);\n'
            report = self.run_check(self.harness(directory, entry))
            self.assertEqual(report["reason"], "reader-failed-or-timeout")
            self.assertNotIn("synthetic-secret", json.dumps(report))
            self.assertEqual(set(Path("/tmp").glob("loki-preflight.*")), before)


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Run these executable checks only on the Linux test server")
    unittest.main()
