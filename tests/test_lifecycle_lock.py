#!/usr/bin/env python3
"""Exercise real lock holders, competing interpreters, and abandoned ownership."""

import json
import os
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
let held = lock.held(ARGV[0], 0), acquired = lock.acquire_wait(ARGV[0], common.own_pid(), 0, 0);
if (acquired) lock.release(ARGV[0], common.own_pid());
printf("%J", { held, acquired, removed: fs.stat(ARGV[0]) == null });
'''


PAUSED_HOLDER = '''let actual = require("fs").open;
require("fs").open = (path, flags, mode) => {
    let file = actual(path, flags, mode);
    if (path == ARGV[0] + "/pid" && flags == "wxe" && file != null) {
        assert(require("fs").writefile(ARGV[1], "paused"));
        while (require("fs").stat(ARGV[2]) == null) sleep(10);
    }
    return file;
};
''' + HOLDER


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

    def holder(self, directory, paused=False):
        path, ready, release = (directory / name for name in ["runtime.lock", "ready", "release"])
        child = subprocess.Popen(self.command(PAUSED_HOLDER if paused else HOLDER, path, ready, release),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop, child)
        deadline = time.monotonic() + 5
        while not ready.exists() and child.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(ready.exists(), "the holder did not acquire its lock")
        if not paused:
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
                self.assertFalse((path / "pid").exists())
                self.assertEqual(self.probe(path), {"held": False, "acquired": True, "removed": False})
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
                self.assertEqual(self.probe(path), {"held": False, "acquired": True, "removed": False})
                self.assertIsNone(sentinel.poll(), "reclaiming a lock must preserve unrelated processes")
            finally:
                if child is not None:
                    self.stop(child)
                self.stop(sentinel)


    def test_a_paused_owner_write_cannot_be_reclaimed_after_zero_grace(self):
        with tempfile.TemporaryDirectory() as directory:
            child, path, release = self.holder(Path(directory), paused=True)
            try:
                self.assertEqual((path / "pid").read_bytes(), b"")
                self.assertEqual(self.probe(path), {"held": True, "acquired": False, "removed": False})
                release.write_text("release")
                output, errors = child.communicate(timeout=5)
                self.assertEqual((child.returncode, output, errors), (0, "", ""))
            finally:
                self.stop(child)

    def test_kernel_anchor_survives_release_and_has_close_on_exec(self):
        with tempfile.TemporaryDirectory() as directory:
            child, path, release = self.holder(Path(directory))
            try:
                anchor = path / ".kernel"
                before = anchor.stat()
                self.assertEqual(before.st_mode & 0o777, 0o600)
                descriptors = [p for p in Path("/proc", str(child.pid), "fd").iterdir()
                               if p.resolve() == anchor]
                self.assertEqual(len(descriptors), 1)
                info = Path("/proc", str(child.pid), "fdinfo", descriptors[0].name).read_text()
                flags = int(next(line.split()[1] for line in info.splitlines() if line.startswith("flags:")), 8)
                self.assertTrue(flags & os.O_CLOEXEC)
                release.write_text("release")
                output, errors = child.communicate(timeout=5)
                self.assertEqual((child.returncode, output, errors), (0, "", ""))
                self.assertEqual(anchor.stat().st_ino, before.st_ino)
                self.assertFalse((path / "pid").exists())
                for _ in range(3):
                    self.assertEqual(self.probe(path), {"held": False, "acquired": True, "removed": False})
                    self.assertEqual(anchor.stat().st_ino, before.st_ino)
            finally:
                self.stop(child)


    def test_sigkill_during_the_first_owner_write_releases_the_kernel_lease(self):
        with tempfile.TemporaryDirectory() as directory:
            child, path, _ = self.holder(Path(directory), paused=True)
            try:
                self.assertEqual((path / "pid").read_bytes(), b"")
                child.kill()
                output, errors = child.communicate(timeout=5)
                self.assertEqual((child.returncode, output, errors), (-signal.SIGKILL, "", ""))
                self.assertEqual(self.probe(path), {"held": False, "acquired": True, "removed": False})
            finally:
                self.stop(child)

    def test_unsafe_fifo_anchor_is_refused_without_blocking_or_mutation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "runtime.lock"
            path.mkdir()
            os.mkfifo(path / ".kernel", 0o600)
            before = (path / ".kernel").stat()
            self.assertEqual(self.probe(path), {"held": True, "acquired": False, "removed": False})
            self.assertEqual((path / ".kernel").stat().st_ino, before.st_ino)
            self.assertFalse((path / "pid").exists())

    def test_competing_stale_reclaimers_never_enter_the_critical_section_together(self):
        worker = '''let fs=require("fs"), lock=require("service.lock"), common=require("core.common");
while (fs.stat(ARGV[1]) == null) sleep(1);
for (let n=0; n<5; n++) {
    let acquired=false;
    for (let attempt=0; attempt<5000 && !acquired; attempt++) {
        acquired=lock.acquire(ARGV[0],common.own_pid(),0);
        if (!acquired) sleep(1);
    }
    assert(acquired);
    let guard=fs.open(ARGV[2],"wxe",0600);
    assert(guard!=null,"overlapping lock owners");
    sleep(10);
    assert(guard.close());
    assert(fs.unlink(ARGV[2]));
    lock.release(ARGV[0],common.own_pid());
}
print("done");
'''
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "runtime.lock"
            path.mkdir()
            (path / "pid").write_text("2147483647\n1\n")
            children = [subprocess.Popen(self.command(worker, path, root / "start", root / "exclusive"),
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(8)]
            for child in children:
                self.addCleanup(self.stop, child)
            (root / "start").write_text("start")
            for child in children:
                output, errors = child.communicate(timeout=15)
                self.assertEqual((child.returncode, output, errors), (0, "done", ""))
            self.assertFalse((root / "exclusive").exists())
            self.assertFalse((path / "pid").exists())
            self.assertEqual(self.probe(path), {"held": False, "acquired": True, "removed": False})

    def test_repeated_lease_and_query_cycles_do_not_leak_file_descriptors(self):
        code = '''let fs=require("fs"),lock=require("service.lock"),c=require("core.common");
let before=length(fs.glob("/proc/self/fd/*"));
for (let i=0;i<100;i++) {
    assert(lock.acquire(ARGV[0],c.own_pid()));
    assert(lock.held(ARGV[0]));
    lock.release(ARGV[0],c.own_pid());
    assert(!lock.held(ARGV[0]));
}
assert(length(fs.glob("/proc/self/fd/*"))==before);
'''
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(self.command(code, Path(directory) / "runtime.lock"), capture_output=True, text=True, timeout=10)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))



if __name__ == "__main__":
    unittest.main()
