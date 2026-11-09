#!/usr/bin/env python3
"""Exercise the production shell watchdog with real children and no timeout applet."""

import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / 'loki/files/usr/lib'


class CoreCheckDeadline(unittest.TestCase):
    def setUp(self):
        self.ucode = shutil.which('ucode')
        self.assertIsNotNone(self.ucode)
        self.temporary = tempfile.TemporaryDirectory(prefix='loki-check-watchdog-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        expression = '''
            let fs = require("fs");
            let fixture = require("fixture");
            let stub = require("stub");
            let exec = require("core.exec");
            require("service.gateway_secret").load = () => fixture.CONTROLLER_SECRET;
            fixture.seed({ settings: fixture.settings({
                config_path: ARGV[0] + "/config.json", cache_path: ARGV[0] + "/cache/cache.db",
                service_listen_address: "127.0.0.1"
            }), section: [{ ".name": "example", action: "bypass", domains: ["example.test"] }] });
            stub.commands([stub.logger([]), [ "ip -o addr show dev", { stdout: "" } ]]);
            exec.combined = (argv, limit) => { print(sprintf("%J\\n", {argv, limit})); return {status: 0}; };
            require("singbox.runtime").prepare_config(true);
            stub.restore();
        '''
        result = subprocess.run([self.ucode, '-L', str(ROOT/'tests/fakes'), '-L', str(ROOT/'tests/lib'),
                                 '-L', str(LIBRARY), '-e', expression, str(self.root)],
                                capture_output=True, text=True, timeout=10,
                                env={**os.environ, 'LOKI_TEST_TMP': str(self.root)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.command = json.loads(result.stdout)['argv']
        self.assertEqual(self.command[:5], ['/bin/busybox', 'setsid', '/bin/busybox', 'ash', '-c'])
        self.assertNotIn('timeout', self.command[5])
        self.assertEqual(list(self.root.glob('*.guard')), [])

    def run_check(self, name, script, *args):
        guard = self.root/name
        guard.mkdir(mode=0o700)
        command = self.command[:6] + [str(guard), '/bin/busybox', 'ash', '-c', script, 'check', *args]
        expression = '''
            let result = require("core.exec").combined(json(ARGV[0]), 65536);
            print(sprintf("%J\\n", result));
        '''
        result = subprocess.run([self.ucode, '-L', str(LIBRARY), '-e', expression, json.dumps(command)],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_exit_status_literal_arguments_and_repeated_completion(self):
        sentinel = self.root/'must-not-exist'
        literal = "x'; touch " + str(sentinel) + "; $(touch " + str(sentinel) + ')'
        for number, status in enumerate((0, 23, 0)):
            result = self.run_check('normal'+str(number), 'printf "%s" "$1"; exit "$2"', literal, str(status))
            self.assertEqual(result, {'status': status, 'output': literal})
        self.assertFalse(sentinel.exists())

    def test_deadline_kills_concurrent_process_groups_and_their_children(self):
        started = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda name: self.run_check(name,
                'echo $$; /bin/busybox sleep 60 & echo $!; wait'), ['deadline-a', 'deadline-b']))
        self.assertGreater(time.monotonic()-started, 9)
        self.assertLess(time.monotonic()-started, 14)
        for result in results:
            self.assertIn(result['status'], (-9, 137))
            for pid in result['output'].splitlines():
                process = Path('/proc')/pid/'stat'
                self.assertTrue(not process.exists() or process.read_text().rsplit(')', 1)[1].split()[0] == 'Z', pid)

    def test_flood_is_discarded_and_signal_is_not_success(self):
        result = self.run_check('flood', '/bin/busybox dd if=/dev/zero bs=1024 count=1024 2>/dev/null')
        self.assertEqual(result, {'status': 1, 'output': '', 'output_limit': True})
        result = self.run_check('signal', 'kill -KILL $$')
        self.assertIn(result['status'], (-9, 137))

    def test_watchdog_setup_failure_never_executes_core(self):
        guard = self.root/'collision'
        guard.mkdir(mode=0o700)
        (guard/'ready').write_text('foreign-sentinel')
        marker = self.root/'core-executed'
        command = self.command[:6] + [str(guard), '/bin/busybox', 'touch', str(marker)]
        result = subprocess.run(command, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 125)
        self.assertFalse(marker.exists())
        self.assertEqual((guard/'ready').read_text(), 'foreign-sentinel')


if __name__ == '__main__':
    unittest.main()
