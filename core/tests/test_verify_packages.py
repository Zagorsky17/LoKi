"""Exercise the release verifier's manifest boundary before package parsing."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ManifestMinimum(unittest.TestCase):
    def check_manifest(self, current, required):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'release.json').write_text(json.dumps({
                'name': 'loki', 'version': '2.0.0', 'tag': '2.0.0',
                'requires': {'loki-core': required}}))
            (root / 'core-release.json').write_text(json.dumps({
                'name': 'loki-core', 'version': current, 'tag': '2.0.0',
                'page': 'https://github.com/Zagorsky17/LoKi/releases/tag/2.0.0',
                'requires': {'loki': '2.0.0'}}))
            p = root / 'release.json'
            (root / 'SHA256SUMS').write_text(hashlib.sha256(p.read_bytes()).hexdigest() + '  release.json\n')
            return subprocess.run([sys.executable, '-B', str(ROOT / 'core/tests/verify_packages.py'), str(root)],
                                  capture_output=True, text=True, timeout=5)

    def test_equal_or_newer_core_reaches_source_validation(self):
        for current, required in [('1.14.4-r9', '1.14.4-r9'), ('1.14.4-r10', '1.14.4-r9'),
                                  ('1.15.0-r1', '1.14.4-r9')]:
            with self.subTest(current=current, required=required):
                result = self.check_manifest(current, required)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('FileNotFoundError', result.stderr)
                self.assertIn('core-source-', result.stderr)

    def test_old_or_malformed_core_is_refused_before_source_reads(self):
        for current, required in [('1.14.4-r8', '1.14.4-r9'), ('1.13.99-r99', '1.14.4-r9'),
                                  ('1.14.4-r10garbage', '1.14.4-r9'), ('1.14.4-r10', ''),
                                  ('1.14.4-r10', '1.14.4-r9junk'), ('', '1.14.4-r9')]:
            with self.subTest(current=current, required=required):
                result = self.check_manifest(current, required)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('AssertionError', result.stderr)
                self.assertNotIn('FileNotFoundError', result.stderr)


if __name__ == '__main__':
    unittest.main()
