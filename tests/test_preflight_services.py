#!/usr/bin/env python3
"""Exercise the bounded local service query with a synthetic CLI on Linux."""
import json
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
LIMIT = 262144


class ServiceProbe(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.root.chmod(0o755)
        for name in ('etc', 'etc/rc.d', 'etc/init.d', 'bin'):
            path = self.root / name
            path.mkdir(exist_ok=True)
            path.chmod(0o755)
        self.response = self.root / 'response.json'
        self.response.write_text('{}')
        self.pid = self.root / 'child.pid'
        self.cli = self.root / 'bin/ubus'
        self.cli.write_text('#!' + sys.executable + '\n' + '''import os, sys, time
from pathlib import Path
assert sys.argv[1:] == ['call', 'service', 'list', '{"verbose":true}']
mode = os.environ.get('SERVICE_TEST_MODE', '')
if mode == 'hang':
    Path(os.environ['SERVICE_TEST_PID']).write_text(str(os.getpid()))
    while True:
        time.sleep(1)
if mode == 'error':
    print('synthetic-private-error')
    print('synthetic-private-stderr', file=sys.stderr)
    raise SystemExit(17)
sys.stdout.write(Path(os.environ['SERVICE_TEST_RESPONSE']).read_text())
''')
        self.cli.chmod(0o755)
        self.addCleanup(self.cleanup_child)
        self.ucode = shutil.which('ucode')
        self.assertIsNotNone(self.ucode, 'ucode is required; do not skip the native pipe check')

    def cleanup_child(self):
        if not self.pid.exists():
            return
        descriptor = None
        try:
            pid = int(self.pid.read_text())
            descriptor = os.pidfd_open(pid)
            command = Path(f'/proc/{pid}/cmdline').read_bytes()
            if str(self.cli).encode() + b'\0' in command:
                signal.pidfd_send_signal(descriptor, signal.SIGKILL)
        except (ProcessLookupError, FileNotFoundError):
            pass
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def invoke(self, data='{}', mode=''):
        self.response.write_text(data)
        expression = ('let p=require("service.preflight_services");'
                      'print(sprintf("%J\\n",p.collect(ARGV[0])));')
        env = dict(os.environ, PATH=str(self.root / 'bin') + ':/usr/local/bin:/usr/bin:/bin',
                   SERVICE_TEST_RESPONSE=str(self.response), SERVICE_TEST_PID=str(self.pid), SERVICE_TEST_MODE=mode)
        started = time.monotonic()
        result = subprocess.run([self.ucode, '-L', str(ROOT / 'loki/files/usr/lib'), '-e', expression, str(self.root)],
                                env=env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        return json.loads(result.stdout), time.monotonic() - started

    @staticmethod
    def reasons(result):
        return {item['reason'] for item in result}

    def test_real_pipe_preserves_privacy_and_never_executes_service_commands(self):
        marker = self.root / 'must-not-exist'
        data = {'podkop': {'instances': {'main': {'running': True, 'pid': 123,
                'command': ['sh', '-c', 'touch ' + str(marker)], 'env': {'TOKEN': 'synthetic-secret'}}}},
                'synthetic-private-service': {'instances': {}}}
        result, _ = self.invoke(json.dumps(data))
        self.assertIn('foreign-service-active-unverified', self.reasons(result))
        self.assertFalse(marker.exists())
        self.assertNotIn('synthetic-secret', json.dumps(result))
        self.assertNotIn('synthetic-private-service', json.dumps(result))
        self.assertNotIn(str(marker), json.dumps(result))

    def test_cli_failure_is_not_a_successful_empty_inventory(self):
        result, _ = self.invoke(mode='error')
        self.assertIn('service-query-failed', self.reasons(result))
        self.assertNotIn('service-snapshot-read-complete', self.reasons(result))
        self.assertNotIn('synthetic-private', json.dumps(result))

    def test_byte_boundary_is_checked_with_the_actual_stream(self):
        result, _ = self.invoke('{}' + ' ' * (LIMIT - 2))
        self.assertIn('service-snapshot-read-complete', self.reasons(result))
        result, _ = self.invoke('{}' + ' ' * (LIMIT - 1))
        self.assertIn('service-response-size-limit', self.reasons(result))
        self.assertNotIn('service-snapshot-read-complete', self.reasons(result))

    def test_malformed_json_and_instance_states_are_incomplete(self):
        for data in ('{}extra', '{} {}', '[]', '{"podkop":{"instances":{"i":{"running":true,"pid":"123"}}}}'):
            with self.subTest(data=data[:20]):
                result, _ = self.invoke(data)
                self.assertNotIn('service-snapshot-read-complete', self.reasons(result))
                self.assertTrue(any(item['kind'] == 'services' and item['state'] == 'incomplete' for item in result))

    def test_timeout_terminates_the_synthetic_child_without_disclosing_its_output(self):
        result, seconds = self.invoke(mode='hang')
        self.assertTrue(self.pid.is_file(), 'the synthetic CLI must actually start')
        self.assertGreater(seconds, 3.5)
        self.assertLess(seconds, 12)
        self.assertIn('service-query-failed', self.reasons(result))
        pid = int(self.pid.read_text())
        stat = Path(f'/proc/{pid}/stat')
        for _ in range(50):
            try:
                state = stat.read_text().split(') ', 1)[1]
            except FileNotFoundError:
                break
            if state.startswith('Z'):
                break
            time.sleep(0.02)
        else:
            self.fail('the synthetic timeout child is still active')

    def test_absolute_init_links_are_mapped_to_the_fixture_without_running_scripts(self):
        marker = self.root / 'must-not-exist'
        script = self.root / 'etc/init.d/podkop'
        script.write_text('#!/bin/sh\ntouch ' + str(marker) + '\n')
        script.chmod(0o755)
        (self.root / 'etc/rc.d/S95podkop').symlink_to('/etc/init.d/podkop')
        result, _ = self.invoke()
        self.assertIn('enabled-service-origin-unverified', self.reasons(result))
        self.assertFalse(marker.exists())

    def test_stat_disappearing_after_existence_check_is_finished(self):
        from unittest.mock import patch
        original_read = Path.read_text
        original_exists = Path.exists
        seen = []

        def is_our_stat(path):
            return self.pid.is_file() and path == Path('/proc') / original_read(self.pid).strip() / 'stat'

        def exists(path):
            return True if is_our_stat(path) else original_exists(path)

        def read(path, *args, **kwargs):
            if is_our_stat(path):
                seen.append(True)
                raise FileNotFoundError('synthetic child exited between lookup and read')
            return original_read(path, *args, **kwargs)

        with patch.object(Path, 'exists', exists), patch.object(Path, 'read_text', read):
            self.test_timeout_terminates_the_synthetic_child_without_disclosing_its_output()
        self.assertTrue(seen, 'the read must encounter the controlled disappearance')

    def test_repeated_queries_leave_the_fixture_and_results_unchanged(self):
        result, _ = self.invoke()
        before = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        repeated, _ = self.invoke()
        after = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(result, repeated)
        self.assertEqual(before, after)
        self.assertIn('service-process-and-origin-unverified', self.reasons(result))
        self.assertIn('autostart-hook-provenance-unverified', self.reasons(result))


if __name__ == '__main__':
    if sys.platform != 'linux':
        raise SystemExit('Run executable checks only on the Linux test server')
    unittest.main()
