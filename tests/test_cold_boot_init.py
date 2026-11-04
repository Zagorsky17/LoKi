#!/usr/bin/env python3
"""Exercise the product init hooks with a recording procd and a synthetic CLI."""

import os
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import shutil
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
INIT = ROOT / "loki/files/etc/init.d/loki"
# Identical bytes in OpenWrt v24.10.8 and v25.12.6, package/base-files/files/etc/rc.common.
RC_COMMON = ROOT / "tests/fixtures/openwrt/rc.common"
RC_COMMON_SHA256 = "dd8ae95c78d10cccf78cb487874f163ace4c1ee14dace05fe28393b19ba639e4"


class ColdBootInit(unittest.TestCase):
    def hooks(self, status=1, token="12-34-1", query_status=0, action="start_service boot"):
        with tempfile.TemporaryDirectory() as directory:
            cli = Path(directory) / "cli"
            trace = Path(directory) / "trace"
            cli.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$TEST_TRACE"
case "$1" in
    initd_start) exit "$TEST_START_STATUS" ;;
    initd_retry_token) printf '%s' "$TEST_TOKEN"; exit "$TEST_QUERY_STATUS" ;;
    *) exit 9 ;;
esac
''')
            cli.chmod(0o700)
            environment = dict(os.environ, TEST_INIT=str(INIT), TEST_BIN=str(cli), TEST_TRACE=str(trace),
                               TEST_START_STATUS=str(status), TEST_TOKEN=token,
                               TEST_QUERY_STATUS=str(query_status))
            harness = '''initscript="$TEST_INIT"
. "$initscript"
LOKI_BIN="$TEST_BIN"
procd_open_instance() { printf 'open:%s\\n' "$1"; }
procd_set_param() { printf 'param'; printf ' <%s>' "$@"; printf '\\n'; }
procd_close_instance() { printf 'close\\n'; }
start() { printf 'start:%s\\n' "$1"; }
'''
            harness += action + '\nresult=$?\nprintf "result:%s\\n" "$result"\n'
            result = subprocess.run(["/bin/sh", "-c", harness], env=environment,
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            return result.stdout, trace.read_text() if trace.exists() else ""

    def test_boot_is_identified_separately_from_manual_start(self):
        output, trace = self.hooks(action="boot")
        self.assertEqual(output, "start:boot\nresult:0\n")
        self.assertEqual(trace, "")

    def test_failed_enabled_start_registers_only_its_generation(self):
        output, trace = self.hooks()
        self.assertIn("open:start-retry-12-34-1\n", output)
        self.assertIn("<initd_retry_monitor> <12-34-1>", output)
        self.assertIn("param <respawn> <3600> <30> <0>\n", output)
        self.assertIn("param <stderr> <1>\nclose\nresult:1\n", output)
        self.assertEqual(trace, "initd_start boot\ninitd_retry_token\n")

    def test_success_has_no_retry_process_or_extra_token_query(self):
        output, trace = self.hooks(status=0)
        self.assertEqual(output, "result:0\n")
        self.assertEqual(trace, "initd_start boot\n")

    def test_cancelled_or_disabled_failure_registers_no_instance(self):
        output, trace = self.hooks(token="")
        self.assertEqual(output, "result:1\n")
        self.assertIn("initd_retry_token", trace)

    def test_token_query_failure_does_not_hide_the_failed_start(self):
        output, _ = self.hooks(query_status=2, action="start_service boot; service_started")
        self.assertEqual(output, "result:1\n")

    def common(self, action, status=0):
        self.assertEqual(hashlib.sha256(RC_COMMON.read_bytes()).hexdigest(), RC_COMMON_SHA256)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            functions = root / "lib/functions"
            functions.mkdir(parents=True)
            trace = root / "trace"
            cli = root / "cli"
            cli.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$TEST_TRACE"
case "$1" in
    initd_start|initd_stop) exit "$TEST_STATUS" ;;
    initd_retry_token) printf '12-34-1' ;;
    *) exit 9 ;;
esac
''')
            cli.chmod(0o700)
            (root / "lib/functions.sh").write_text('''list_contains() {
    eval "values=\\${$1}"
    case " $values " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}
''')
            (functions / "service.sh").write_text("")
            (functions / "procd.sh").write_text('''LOKI_BIN="$TEST_BIN"
record() { printf '%s\\n' "$*" >> "$TEST_TRACE"; }
procd_lock() { record procd_lock; }
procd_kill() { record "procd_kill $1"; }
procd_open_service() { record "procd_open_service $1"; }
procd_close_service() { record "procd_close_service $1"; }
procd_open_instance() { record "procd_open_instance $1"; }
procd_close_instance() { record procd_close_instance; }
procd_set_param() { record "procd_set_param $*"; }
''')
            environment = dict(os.environ, IPKG_INSTROOT=str(root), TEST_BIN=str(cli),
                               TEST_TRACE=str(trace), TEST_STATUS=str(status))
            result = subprocess.run(["/bin/sh", str(RC_COMMON), str(INIT), action],
                                    env=environment, capture_output=True, text=True, timeout=5)
            self.assertEqual(result.stderr, "")
            return result.returncode, trace.read_text().splitlines()

    def test_pinned_rc_common_stops_lifecycle_before_killing_retry_and_preserves_failure(self):
        for status in (0, 1):
            result, trace = self.common("stop", status)
            self.assertEqual(result, status)
            self.assertEqual(trace, ["procd_lock", "initd_stop", "procd_kill loki"])

    def test_pinned_rc_common_boot_registers_retry_even_when_initial_start_fails(self):
        result, trace = self.common("boot", 1)
        self.assertEqual(result, 1)
        self.assertEqual(trace[0:3], ["procd_open_service loki", "initd_start boot", "initd_retry_token"])
        self.assertIn("procd_open_instance start-retry-12-34-1", trace)
        self.assertEqual(trace[-1], "procd_close_service add")

    def test_pinned_rc_common_manual_start_does_not_inherit_boot_policy(self):
        result, trace = self.common("start")
        self.assertEqual(result, 0)
        self.assertEqual(trace, ["procd_open_service loki", "initd_start ", "procd_close_service set"])

    def test_native_request_lock_orders_new_start_before_old_completion(self):
        binary = shutil.which("ucode")
        self.assertIsNotNone(binary, "native ucode is required")
        prefix = '''let fs = require("fs");
let common = require("core.common");
let request = require("service.start_request");
let root = getenv("REQUEST_ROOT");
request.paths.pending = root + "/pending";
request.paths.lock = root + "/request.lock";
'''
        command = [binary, "-L", str(ROOT / "loki/files/usr/lib"), "-e"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = dict(os.environ, REQUEST_ROOT=directory)
            first = subprocess.run(command + [prefix + 'print(request.begin());'], env=environment,
                                   capture_output=True, text=True, timeout=5, check=True).stdout
            self.assertTrue(first)
            environment["EXPECTED"] = first
            writer_code = prefix + '''let write = common.write_file_atomic;
common.write_file_atomic = (path, value) => {
    fs.writefile(root + "/ready", "1");
    for (let i = 0; fs.stat(root + "/release") == null && i < 100; i++)
        sleep(50);
    if (fs.stat(root + "/release") == null)
        die("test release deadline");
    return write(path, value);
};
print(request.begin());
'''
            writer = subprocess.Popen(command + [writer_code], env=environment,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            canceller = None
            try:
                deadline = time.monotonic() + 3
                while not (root / "ready").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((root / "ready").exists(), "new Start holds the request lock")
                canceller = subprocess.Popen(command + [prefix + 'print(request.cancel(getenv("EXPECTED")));'],
                                             env=environment, stdout=subprocess.PIPE,
                                             stderr=subprocess.PIPE, text=True)
                time.sleep(0.1)
                self.assertIsNone(canceller.poll(), "old completion waits for the new intent publication")
                (root / "release").write_text("1")
                second, writer_error = writer.communicate(timeout=8)
                cancelled, cancel_error = canceller.communicate(timeout=8)
                self.assertEqual((writer.returncode, writer_error), (0, ""))
                self.assertEqual((canceller.returncode, cancel_error, cancelled), (0, "", "true"))
                self.assertNotEqual(second, first)
                self.assertTrue(second)
                self.assertEqual((root / "pending").read_text(), second + "\n")
                self.assertFalse((root / "request.lock").exists())
            finally:
                (root / "release").touch()
                for process in (writer, canceller):
                    if process is not None and process.poll() is None:
                        process.kill()
                        process.communicate(timeout=5)


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Run executable checks only on the Linux test server")
    unittest.main()
