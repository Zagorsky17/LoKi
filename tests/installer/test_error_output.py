#!/usr/bin/env python3
"""Exercise installer failure output without installing or changing services."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'install.sh').read_text().rsplit('\nmain "$@"', 1)[0]


class InstallerErrorOutput(unittest.TestCase):
    def invoke(self, shell, action, log='', mode='install', russian=False):
        with tempfile.TemporaryDirectory(prefix='loki-error-output-') as directory:
            root = Path(directory)
            work = root / 'work'
            work.mkdir()
            journal = root / 'install.log'
            journal.write_text(log)
            script = root / 'case.sh'
            if mode == 'check':
                action = 'exec 3>&1\nexec 1>&2\n' + action
            script.write_text(SOURCE + f'''
WORK={shlex.quote(str(work))}
LOG={shlex.quote(str(journal))}
MODE={shlex.quote(mode)} RU={int(russian)}
logger() {{ :; }}
sleep() {{ :; }}
mem_available_kb() {{ echo 1048576; }}
free_kb() {{ echo 1048576; }}
wget() {{ echo 'TLS error: certificate verification failed' >&2; return 4; }}
''' + action + '\n')
            result = subprocess.run([*shell, str(script)], capture_output=True, text=True,
                                    env=dict(os.environ, LC_ALL='C'), timeout=10)
            self.assertFalse(work.exists())
            return result

    def test_network_failure_shows_downloader_error_and_exit_status(self):
        busybox = shutil.which('busybox')
        self.assertIsNotNone(busybox)
        for shell in (['sh'], [busybox, 'ash']):
            for russian in (False, True):
                with self.subTest(shell=shell, russian=russian):
                    result = self.invoke(shell, 'fetch_release loki', russian=russian)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn('TLS error: certificate verification failed', result.stderr)
                    self.assertIn('wget exit: 4', result.stderr)
                    self.assertEqual(result.stdout, '')

    def test_error_excerpt_is_bounded_and_masks_url_credentials_and_query(self):
        log = 'old-entry-hidden\n' + ('filler ' + 'x' * 1000 + '\n') * 40
        log += 'download https://synthetic-user:synthetic-password@mirror.example/file?token=synthetic-token\n'
        log += 'last useful error\n'
        result = self.invoke(['sh'], "fail 3 package_manager 'Package operation failed'", log=log)
        self.assertEqual(result.returncode, 3)
        self.assertIn('last useful error', result.stderr)
        self.assertIn('https://[hidden]@mirror.example/file?[hidden]', result.stderr)
        self.assertLess(len(result.stderr.encode()), 10000)
        for hidden in ('old-entry-hidden', 'synthetic-user', 'synthetic-password', 'synthetic-token'):
            self.assertNotIn(hidden, result.stderr)

    def test_check_mode_keeps_machine_output_and_does_not_dump_the_log(self):
        result = self.invoke(['sh'], "fail 1 network 'Synthetic failure'", log='private-log-line\n', mode='check')
        self.assertEqual(result.returncode, 1)
        reply = json.loads(result.stdout)
        self.assertFalse(reply['success'])
        self.assertEqual(reply['reason'], 'network')
        self.assertNotIn('private-log-line', result.stdout + result.stderr)

    def test_success_does_not_dump_the_log(self):
        result = self.invoke(['sh'], 'finish 0', log='private-log-line\n')
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''))


if __name__ == '__main__':
    unittest.main()
