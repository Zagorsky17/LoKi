#!/usr/bin/env python3
"""Kill the real lifecycle interpreter at interception with isolated router fakes."""

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


class WatchRecovery(unittest.TestCase):
    def test_sigkill_at_first_interception_leaves_the_watcher_armed(self):
        binary = shutil.which("ucode")
        self.assertIsNotNone(binary, "native ucode is required")
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory) / "intercepted.json"
            environment = dict(os.environ, FORKOP_TEST_TMP=directory,
                               FORKOP_TEST_FATAL_SNAPSHOT=str(snapshot))
            command = [binary, "-L", "fakes", "-L", "lib", "-L", "../forkop/files/usr/lib",
                       "service/lifecycle.test.uc"]
            child = subprocess.Popen(command, cwd=ROOT / "tests", env=environment,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            sentinel = subprocess.Popen(["sleep", "30"], stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while not snapshot.exists() and child.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(snapshot.exists(), "the lifecycle did not reach interception")
                child.kill()
                output, errors = child.communicate(timeout=5)
                self.assertEqual(child.returncode, -signal.SIGKILL, errors)
                self.assertEqual(output, "")
                self.assertEqual(errors, "")
                state = json.loads(snapshot.read_text())
                self.assertTrue(state["network"])
                self.assertTrue(state["watcher"], state)
                self.assertFalse(state["planned_stop"], state)
                self.assertNotIn("rule-set worker started", state["events"])
                recovery_environment = dict(os.environ, FORKOP_TEST_TMP=directory,
                                            FORKOP_TEST_RECOVER_SNAPSHOT=str(snapshot))
                recovered = subprocess.run(command, cwd=ROOT / "tests", env=recovery_environment,
                                           capture_output=True, text=True, timeout=5)
                self.assertEqual(recovered.returncode, 0, recovered.stderr)
                self.assertEqual(json.loads(recovered.stdout),
                                 {"capture": False, "events": ["capture paused"]})
                self.assertIsNone(sentinel.poll(), "recovery must not terminate an unrelated process")
            finally:
                if child.poll() is None:
                    child.kill()
                child.communicate(timeout=5)
                sentinel.terminate()
                sentinel.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
