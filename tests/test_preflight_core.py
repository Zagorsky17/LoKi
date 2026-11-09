#!/usr/bin/env python3
"""Check staged native UCI against a checksum-bound core, without starting a service."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DEFAULT = (ROOT/'loki/files/etc/config/loki').read_text()


class PreparedCore(unittest.TestCase):
    def setUp(self):
        self.binary = shutil.which('ucode')
        self.assertIsNotNone(self.binary)
        directory = tempfile.TemporaryDirectory(prefix='loki-preflight-core-')
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.marker = self.root/'executed'
        self.core = self.root/'candidate-core'
        if os.environ.get('LOKI_TEST_CORE'):
            shutil.copyfile(os.environ['LOKI_TEST_CORE'], self.core)
        else:
            self.core.write_text('#!/bin/sh\n[ "$1" = --disable-color ] && [ "$2" = -c ] && [ "$4" = check ] || exit 99\n'
                                 'test -s "$3" || exit 99\nprintf checked > "'+str(self.marker)+'"\n')
        self.core.chmod(0o700)
        self.metadata = {'path': str(self.core), 'mode': 0o700, 'size': self.core.stat().st_size,
                         'sha256': hashlib.sha256(self.core.read_bytes()).hexdigest()}

    def check(self, data=DEFAULT, metadata=None):
        scratch = self.root/'scratch'
        scratch.mkdir(mode=0o700)
        source = self.root/'input.json'
        source.write_text(json.dumps({'data': data, 'core': self.metadata if metadata is None else metadata}))
        expression = '''let fs=require("fs");let input=json(fs.readfile(ARGV[0]));
require("service.gateway_secret").load=()=>die("persistent-secret-accessed");
let report=require("service.preflight_config").check(input.data,ARGV[1],
 {dhcp:"config dnsmasq 'dns'\\n option domain 'prepared.lan'\\n",system:"config timeserver 'ntp'\\n"},input.core);
print(sprintf("%J",report));'''
        process = subprocess.run([self.binary, '-L', str(ROOT/'loki/files/usr/lib'), '-e', expression,
                                  str(source), str(scratch)], capture_output=True, text=True, timeout=15)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stderr, '')
        self.assertEqual(list(scratch.iterdir()), [])
        self.assertNotIn('synthetic-secret', process.stdout)
        return {(row['kind'], row['state'], row['reason']) for row in json.loads(process.stdout)}

    def test_empty_and_generated_configuration_pass_only_the_check_command(self):
        for number, data in enumerate([DEFAULT, DEFAULT+"\nconfig section 'example'\n option action 'bypass'\n list domains 'one.example'\n"]):
            result = self.check(data)
            self.assertIn(('core-check', 'checked', 'candidate-core-check-checked'), result)
            (self.root/'scratch').rmdir()

    def test_changed_checksum_or_unsafe_mode_never_executes_candidate(self):
        result = self.check(metadata={**self.metadata, 'sha256': '0'*64})
        self.assertIn(('core-check', 'incomplete', 'candidate-core-check-failed'), result)
        self.assertFalse(self.marker.exists())
        (self.root/'scratch').rmdir()
        self.core.chmod(0o777)
        result = self.check()
        self.assertIn(('core-check', 'incomplete', 'candidate-core-check-failed'), result)
        self.assertFalse(self.marker.exists())

    def test_invalid_configuration_does_not_execute_core(self):
        result = self.check(DEFAULT.replace("dns_timeout '10s'", "dns_timeout 'synthetic-secret'"))
        self.assertIn(('configuration', 'incomplete', 'candidate-config-values-invalid'), result)
        self.assertFalse(self.marker.exists())

    def test_failed_core_check_returns_a_fixed_reason(self):
        self.core.write_text('#!/bin/sh\nprintf synthetic-secret >&2\nexit 7\n')
        self.metadata.update(size=self.core.stat().st_size, sha256=hashlib.sha256(self.core.read_bytes()).hexdigest())
        result = self.check()
        self.assertIn(('core-check', 'incomplete', 'candidate-core-check-failed'), result)


if __name__ == '__main__':
    if sys.platform != 'linux': raise SystemExit('Run these checks on the Linux test server')
    unittest.main()
