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

    def test_low_memory_wrapper_never_invokes_the_reader_or_core(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            marker = tree/'unexpected-reader'
            payload = {'schema': 1, 'result': 'incomplete', 'complete': False, 'install_allowed': False, 'reason': 'reader-executed'}
            entry = ('let fs=require("fs");fs.writefile(' + json.dumps(str(marker)) + ',"ran");print('
                     + json.dumps(json.dumps(payload) + '\n') + ');exit(2);')
            command = self.harness(directory, entry)
            memory = tree/'meminfo'
            memory.write_text('MemAvailable: 20480 kB\n')
            wrapper = tree/'preflight.sh'
            wrapper.write_text(wrapper.read_text().replace('/proc/meminfo', str(memory)))
            report = self.run_check(command)
            self.assertEqual(report['reason'], 'resource-candidate-memory-insufficient')
            self.assertFalse(marker.exists())

    def test_entry_readiness_controls_the_exit_status(self):
        binary = shutil.which("ucode")
        self.assertIsNotNone(binary)
        for state, complete, allowed, expected in (
            ("checked", True, True, 0), ("incomplete", False, False, 2),
            ("conflict", False, False, 1), ("checked", False, True, 2),
        ):
            with tempfile.TemporaryDirectory() as directory:
                library = Path(directory) / "service"
                library.mkdir()
                payload = {"schema": 1, "result": state, "complete": complete,
                           "install_allowed": allowed, "observations": []}
                (library / "preflight.uc").write_text("return { collect: () => (" + json.dumps(payload) + ") };\n")
                result = subprocess.run([binary, "-L", directory, str(ROOT / "preflight.uc")],
                                        capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(json.loads(result.stdout), payload)
                self.assertEqual(result.stderr, "")

    def test_wrapper_returns_a_checked_readers_success_status_and_cleans_scratch(self):
        busybox = shutil.which("busybox")
        self.assertIsNotNone(busybox)
        payload = {"schema": 1, "result": "checked", "complete": True, "install_allowed": True, "observations": []}
        for shell in (["/bin/sh"], [busybox, "ash"]):
            with tempfile.TemporaryDirectory() as directory:
                before = set(Path("/tmp").glob("loki-preflight.*"))
                entry = "print(" + json.dumps(json.dumps(payload) + "\n") + ");exit(0);\n"
                command = self.harness(directory, entry)
                result = subprocess.run([*shell, command[1]], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(json.loads(result.stdout), payload)
                self.assertEqual(result.stderr, "")
                self.assertEqual(set(Path("/tmp").glob("loki-preflight.*")), before)

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

    def test_wrapper_runs_without_invoking_the_optional_timeout_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory)
            tools = tree / "tools"
            tools.mkdir()
            binary = shutil.which("ucode")
            (tools / "ucode").symlink_to(binary)
            marker = tree / "timeout-executed"
            (tools / "timeout").write_text(f'#!/bin/sh\ntouch "{marker}"\nexit 88\n')
            (tools / "timeout").chmod(0o700)
            entry = 'print(\'{"schema":1,"result":"incomplete","complete":false,"install_allowed":false,"reason":"stock-tools"}\\n\'); exit(2);'
            command = self.harness(directory, entry)
            script = tree / "preflight.sh"
            script.write_text(script.read_text().replace(str(Path(binary).parent) + ":/usr/sbin", str(tools) + ":/usr/sbin", 1))
            report = self.run_check(command)
            self.assertEqual(report["reason"], "stock-tools")
            self.assertFalse(marker.exists())

    def test_wrapper_masks_reader_exception(self):
        with tempfile.TemporaryDirectory() as directory:
            report = self.run_check(self.harness(directory, 'die("synthetic-secret");\n'))
            self.assertEqual(report["reason"], "reader-failed-or-timeout")

    def test_wrapper_sets_zero_core_dump_size_limits(self):
        busybox = shutil.which("busybox")
        self.assertIsNotNone(busybox, "BusyBox ash is required for the OpenWrt shell check")
        for shell in (["/bin/sh"], [busybox, "ash"]):
            with tempfile.TemporaryDirectory() as directory:
                entry = '''let limits = require("fs").readfile("/proc/self/limits");
                    assert(match(limits, /Max core file size[ \\t]+0[ \\t]+0[ \\t]+bytes/) != null);
                    print('{"schema":1,"result":"incomplete","complete":false,"install_allowed":false,"reason":"core-limits-zero"}\\n');
                    exit(2);'''
                command = self.harness(directory, entry)
                report = self.run_check([*shell, command[1]])
                self.assertEqual(report["reason"], "core-limits-zero")

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
