#!/usr/bin/env python3
"""Exercise real lock holders, competing interpreters, and abandoned ownership."""

import json
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
HOLDER = '''let fs = require("fs"), lock = require("service.lock"), common = require("core.common");
assert(lock.acquire(ARGV[0], common.own_pid()));
assert(fs.writefile(ARGV[1], "ready"));
while (fs.stat(ARGV[2]) == null) sleep(10);
lock.release(ARGV[0], common.own_pid());
'''
PROBE = '''let fs = require("fs"), lock = require("service.lock"), common = require("core.common");
let held = lock.held(ARGV[0]), acquired = lock.acquire_wait(ARGV[0], common.own_pid(), 0);
if (acquired) lock.release(ARGV[0], common.own_pid());
printf("%J", { held, acquired, removed: fs.stat(ARGV[0]) == null });
'''


class LifecycleLock(unittest.TestCase):
    def command(self, code, *args):
        binary = shutil.which("ucode")
        self.assertIsNotNone(binary, "native ucode is required")
        return [binary, "-L", str(ROOT / "loki/files/usr/lib"), "-e", code, *map(str, args)]

    def probe(self, path):
        result = subprocess.run(self.command(PROBE, path), capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)

    def holder(self, directory):
        path, ready, release = (directory / name for name in ["runtime.lock", "ready", "release"])
        child = subprocess.Popen(self.command(HOLDER, path, ready, release),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop, child)
        deadline = time.monotonic() + 5
        while not ready.exists() and child.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(ready.exists(), "the holder did not acquire its lock")
        record = (path / "pid").read_text().splitlines()
        self.assertEqual(record[0], str(child.pid))
        self.assertEqual(len(record), 2)
        self.assertTrue(record[1].isdigit())
        self.assertEqual((path / "pid").stat().st_mode & 0o777, 0o600)
        return child, path, release

    @staticmethod
    def stop(child):
        if child.poll() is None:
            child.kill()
        child.communicate(timeout=5)

    def test_live_holder_excludes_other_processes_and_releases_for_the_next(self):
        with tempfile.TemporaryDirectory() as directory:
            child, path, release = self.holder(Path(directory))
            try:
                before = (path / "pid").read_bytes()
                for _ in range(3):
                    self.assertEqual(self.probe(path), {"held": True, "acquired": False, "removed": False})
                    self.assertEqual((path / "pid").read_bytes(), before)
                release.write_text("release")
                output, errors = child.communicate(timeout=5)
                self.assertEqual((child.returncode, output, errors), (0, "", ""))
                self.assertFalse(path.exists())
                self.assertEqual(self.probe(path), {"held": False, "acquired": True, "removed": True})
            finally:
                self.stop(child)

    def test_sigkill_leaves_a_stale_lock_that_another_process_reclaims(self):
        with tempfile.TemporaryDirectory() as directory:
            sentinel = subprocess.Popen(["sleep", "30"])
            self.addCleanup(self.stop, sentinel)
            child = None
            try:
                child, path, _ = self.holder(Path(directory))
                child.kill()
                output, errors = child.communicate(timeout=5)
                self.assertEqual((child.returncode, output, errors), (-signal.SIGKILL, "", ""))
                self.assertTrue((path / "pid").exists())
                self.assertEqual(self.probe(path), {"held": False, "acquired": True, "removed": True})
                self.assertIsNone(sentinel.poll(), "reclaiming a lock must preserve unrelated processes")
            finally:
                if child is not None:
                    self.stop(child)
                self.stop(sentinel)



if __name__ == "__main__":
    unittest.main()
