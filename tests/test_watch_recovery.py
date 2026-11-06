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
            environment = dict(os.environ, LOKI_TEST_TMP=directory,
                               LOKI_TEST_FATAL_SNAPSHOT=str(snapshot))
            command = [binary, "-L", "fakes", "-L", "lib", "-L", "../loki/files/usr/lib",
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
                self.assertIn("rule-set worker started", state["events"])
                self.assertEqual(state["context_phase"], "applying")
                recovery_environment = dict(os.environ, LOKI_TEST_TMP=directory,
                                            LOKI_TEST_RECOVER_SNAPSHOT=str(snapshot))
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

    def test_sigkill_never_promotes_an_unconfirmed_generation(self):
        binary = shutil.which("ucode")
        self.assertIsNotNone(binary, "native ucode is required")
        command = [binary, "-L", "fakes", "-L", "lib", "-L", "../loki/files/usr/lib",
                   "service/lifecycle.test.uc"]
        sentinel = subprocess.Popen(["sleep", "120"], stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
        try:
            for point in ["before-applying", "applying", "worker", "service", "config", "nft", "ready"]:
                with self.subTest(point=point), tempfile.TemporaryDirectory() as directory:
                    snapshot = Path(directory) / "interrupted.json"
                    environment = dict(os.environ, LOKI_TEST_TMP=directory,
                                       LOKI_TEST_CONTEXT_SNAPSHOT=str(snapshot),
                                       LOKI_TEST_CONTEXT_POINT=point)
                    child = subprocess.Popen(command, cwd=ROOT / "tests", env=environment,
                                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    try:
                        deadline = time.monotonic() + 10
                        while not snapshot.exists() and child.poll() is None and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertTrue(snapshot.exists(), f"the lifecycle did not reach {point}")
                        child.kill()
                        output, errors = child.communicate(timeout=5)
                        self.assertEqual(child.returncode, -signal.SIGKILL, errors)
                        self.assertEqual(output + errors, "")
                        state = json.loads(snapshot.read_text())
                        expected = "ready" if point in ["before-applying", "ready"] else "applying"
                        self.assertEqual(state["phase"], expected)
                        recovery_environment = dict(os.environ, LOKI_TEST_TMP=directory,
                                                    LOKI_TEST_CONTEXT_RECOVER=str(snapshot))
                        result = subprocess.run(command, cwd=ROOT / "tests", env=recovery_environment,
                                                capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        recovered = json.loads(result.stdout)
                        self.assertEqual(recovered["phase"], expected)
                        self.assertEqual(recovered["generation"], state["generation"])
                        self.assertEqual(recovered["candidate"], state["candidate"])
                        self.assertEqual(recovered["status"], 0 if expected == "ready" else 1)
                        self.assertEqual(recovered["events"], [])
                        self.assertEqual(recovered["pid"], 4242)
                        self.assertIsNone(sentinel.poll(), "recovery must preserve unrelated processes")
                    finally:
                        if child.poll() is None:
                            child.kill()
                        child.communicate(timeout=5)
        finally:
            sentinel.terminate()
            sentinel.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
