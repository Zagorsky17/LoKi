#!/usr/bin/env python3
"""Inspect real native UCI saved deltas without committing fixture configuration."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SESSION = 'uci-0123456789abcdef0123456789abcdef'


class PendingUCI(unittest.TestCase):
    def probe(self, session=False, revert=False):
        binary = shutil.which('ucode')
        self.assertIsNotNone(binary, 'native UCI checks must run on the Linux test server')
        with tempfile.TemporaryDirectory(prefix='loki-pending-native-') as directory:
            root = Path(directory)
            for name in ['tmp', 'tmp/run', 'etc', 'etc/config']:
                (root/name).mkdir(mode=0o755)
            (root/'tmp/run/rpcd').mkdir(mode=0o700)
            (root/'var').symlink_to('tmp')
            saved = root/'tmp/run/rpcd'/SESSION if session else root/'tmp/.uci'
            saved.mkdir(mode=0o700)
            config = root/'etc/config/dhcp'
            body = b"config dnsmasq 'main'\n option port '53'\n"
            config.write_bytes(body)
            script = r'''
let fs=require("fs"),u=require("uci").cursor(ARGV[1],ARGV[2],"");
assert(u.load("dhcp")===true);
assert(u.set("dhcp","main","server","127.0.0.42#53")===true);
assert(u.save("dhcp")===true);
assert(fs.stat(ARGV[2]+"/dhcp").size>0);
let pending=require("service.preflight_config").pending;
let before=pending(ARGV[0]);
if(ARGV[3]=="revert")assert(u.revert("dhcp")===true);
let after=pending(ARGV[0]);
print(sprintf("%J\n",{before,after}));
'''
            process = subprocess.run([binary, '-L', str(ROOT/'loki/files/usr/lib'), '-e', script,
                                      str(root), str(root/'etc/config'), str(saved), 'revert' if revert else 'keep'],
                                     capture_output=True, text=True, timeout=10)
            self.assertEqual(process.returncode, 0, process.stderr)
            self.assertEqual(process.stderr, '')
            self.assertEqual(config.read_bytes(), body, 'inspection/save must not commit configuration')
            for private in [str(root), SESSION, '127.0.0.42']:
                self.assertNotIn(private, process.stdout)
            if not revert:
                self.assertTrue((saved/'dhcp').is_file())
                self.assertGreater((saved/'dhcp').stat().st_size, 0, 'the original native delta remains intact')
            return json.loads(process.stdout)

    def test_native_cli_deltas_are_retained_and_repeatably_incomplete(self):
        result = self.probe()
        self.assertEqual(result['before']['reason'], 'uci-pending-config-changes')
        self.assertEqual(result['before'], result['after'])

    def test_native_rpcd_layout_deltas_are_retained_and_repeatably_incomplete(self):
        result = self.probe(session=True)
        self.assertEqual(result['before']['reason'], 'uci-pending-config-changes')
        self.assertEqual(result['before'], result['after'])

    def test_explicit_native_revert_in_the_fixture_allows_a_new_snapshot(self):
        for session in [False, True]:
            with self.subTest(session=session):
                result = self.probe(session=session, revert=True)
                self.assertEqual(result['before']['state'], 'incomplete')
                self.assertEqual(result['after']['state'], 'checked')
                self.assertEqual(result['after']['reason'], 'uci-pending-snapshot-checked')


if __name__ == '__main__':
    if sys.platform != 'linux':
        raise SystemExit('Run executable checks only on the Linux test server')
    unittest.main()
