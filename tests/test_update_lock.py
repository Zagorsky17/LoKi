#!/usr/bin/env python3
"""Keep the update lease held by package children after their worker dies."""

import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / 'loki/files/usr/lib'


class UpdateLease(unittest.TestCase):
    def setUp(self):
        self.binary = shutil.which('ucode')
        self.assertIsNotNone(self.binary)
        self.directory = tempfile.TemporaryDirectory(prefix='loki-update-lease-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.lock = self.root/'install.lock'
        self.anchor = self.lock/'.kernel'
        result = self.run_ucode('let l=require("service.lock"); let p=require("core.common").own_pid(); '
                                'assert(l.acquire(ARGV[0], p)); l.release(ARGV[0],p);', str(self.lock))
        self.assertEqual(result.returncode, 0, result.stderr)

    def command(self, expression, *args):
        return [self.binary, '-L', str(LIBRARY), '-e', expression, *args]

    def run_ucode(self, expression, *args):
        return subprocess.run(self.command(expression, *args), capture_output=True, text=True, timeout=10)

    def spawn(self, expression, *args, anchor=None):
        try:
            previous = os.dup(9)
        except OSError:
            previous = None
        descriptor = os.open(anchor or self.anchor, os.O_RDWR)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            os.dup2(descriptor, 9)
            return subprocess.Popen(self.command(expression, *args), pass_fds=(9,),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                    start_new_session=True)
        finally:
            os.close(9)
            if descriptor != 9:
                os.close(descriptor)
            if previous is not None:
                os.dup2(previous, 9)
                os.close(previous)

    def test_adopted_descriptor_owns_the_existing_protocol_and_releases_normally(self):
        process = self.spawn('let l=require("service.lock"); let p=require("core.common").own_pid(); '
                             'assert(type(l.adopt)=="function"); assert(!l.adopt(ARGV[0],"0")); '
                             'assert(l.adopt(ARGV[0],p)); '
                             'assert(l.held(ARGV[0])); l.release(ARGV[0],p);', str(self.lock))
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual((process.returncode, stdout, stderr), (0, '', ''))
        self.assertFalse((self.lock/'pid').exists())
        with self.anchor.open('r') as file:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_corrupt_protocol_or_unsafe_anchor_mode_never_publishes_an_owner(self):
        original = self.anchor.read_bytes()
        for kind in ('protocol', 'mode'):
            self.anchor.write_bytes(b'foreign-data\n' if kind == 'protocol' else original)
            self.anchor.chmod(0o644 if kind == 'mode' else 0o600)
            process = self.spawn('let l=require("service.lock");assert(type(l.adopt)=="function");'
                                 'assert(!l.adopt(ARGV[0],require("core.common").own_pid()));', str(self.lock))
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual((process.returncode, stdout, stderr), (0, '', ''), kind)
            self.assertFalse((self.lock/'pid').exists())
            self.assertEqual(self.anchor.read_bytes(), b'foreign-data\n' if kind == 'protocol' else original)
    def test_missing_or_foreign_descriptor_is_refused_without_closing_foreign_input(self):
        expression = ('let fs=require("fs");let l=require("service.lock");'
                      'assert(type(l.adopt)=="function");'
                      'assert(!l.adopt(ARGV[0],require("core.common").own_pid()));')
        result = self.run_ucode(expression, str(self.lock))
        self.assertEqual(result.returncode, 0, result.stderr)
        foreign = self.root/'foreign';foreign.write_text('foreign-sentinel')
        process = self.spawn(expression + 'assert(fs.readfile("/proc/self/fd/9")=="foreign-sentinel");',
                             str(self.lock), anchor=foreign)
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual((process.returncode, stdout, stderr), (0, '', ''))
        self.assertEqual(foreign.read_text(), 'foreign-sentinel')
        self.assertFalse((self.lock/'pid').exists())

    def test_package_child_keeps_recovery_excluded_after_worker_sigkill(self):
        marker, release = self.root/'package.pid', self.root/'release'
        package = self.root/'package.sh'
        package.write_text('echo $$ > "$1"\nwhile [ ! -e "$2" ]; do sleep 0.1; done\n')
        process = self.spawn('let l=require("service.lock"); assert(type(l.adopt)=="function"); '
                             'assert(l.adopt(ARGV[0],require("core.common").own_pid())); '
                             'require("core.exec").run(["/bin/sh",ARGV[1],ARGV[2],ARGV[3]]);', str(self.lock), str(package), str(marker), str(release))
        try:
            deadline = time.monotonic()+5
            while not marker.exists() and process.poll() is None and time.monotonic()<deadline:
                time.sleep(0.02)
            self.assertTrue(marker.exists(), 'the controlled package child did not start')
            pid = marker.read_text().strip()
            self.assertEqual(Path('/proc',pid,'fd/9').resolve(), self.anchor)
            process.kill();process.wait(timeout=5)
            self.assertEqual(process.returncode, -signal.SIGKILL)
            with self.anchor.open('r') as file:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            check = self.run_ucode('let l=require("service.lock");assert(l.held(ARGV[0]));'
                                   'assert(!l.acquire(ARGV[0],require("core.common").own_pid()));', str(self.lock))
            self.assertEqual(check.returncode, 0, check.stderr)
            release.touch()
            deadline=time.monotonic()+5
            while time.monotonic()<deadline:
                with self.anchor.open('r') as file:
                    try:
                        fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        time.sleep(0.02)
            else:
                self.fail('the package child did not release its inherited lease')
            result=self.run_ucode('let l=require("service.lock");let p=require("core.common").own_pid();'
                                  'assert(l.acquire(ARGV[0],p));l.release(ARGV[0],p);',str(self.lock))
            self.assertEqual(result.returncode,0,result.stderr)
        finally:
            release.touch()
            try:
                os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=5)


if __name__ == '__main__':
    if sys.platform != 'linux':
        raise SystemExit('Run update lease checks only on the Linux test server')
    unittest.main()
