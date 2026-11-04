"""Exercise package-root recipes without an SDK, package manager or downloads."""
# Modified for LoKi on 2026-11-04: preserve the root license in distributed payloads.
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BUILD = (ROOT / 'build.sh').read_text()


class LicensePayloadTests(unittest.TestCase):
    def test_all_standalone_roots_preserve_license_and_existing_payloads(self):
        recipes = BUILD[BUILD.index('\nmake_dir() {'):BUILD.index('\ngenerate_apk_metadata_files() {')]
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            compiler = work / 'po2lmo'
            compiler.write_text('#!/bin/sh\ncp "$1" "$2"\n')
            compiler.chmod(0o755)
            script = work / 'roots.sh'
            script.write_text('set -euo pipefail\n' + recipes + '''
ROOT_DIR=$1 RELEASE_VERSION=2.0.0
build_backend_root "$2/backend"
build_app_root "$2/app"
build_i18n_root "$2/i18n" "$2/po2lmo"
''')
            payloads = {'backend': 'forkop', 'app': 'luci-app-forkop', 'i18n': 'luci-i18n-forkop-ru'}
            for attempt in range(2):
                result = subprocess.run(['bash', str(script), str(ROOT), str(work)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                paths = []
                for payload, package in payloads.items():
                    license_file = work / payload / 'usr/share/licenses' / package / 'LICENSE'
                    self.assertTrue(license_file.is_file(), str(license_file))
                    self.assertEqual(license_file.read_bytes(), (ROOT / 'LICENSE').read_bytes())
                    self.assertEqual(license_file.stat().st_mode & 0o777, 0o644)
                    self.assertEqual(license_file.parent.stat().st_mode & 0o777, 0o755)
                    paths.append(license_file)
                self.assertEqual((work / 'backend/usr/share/forkop/install.sh').read_bytes(), (ROOT / 'install.sh').read_bytes())
                font = 'luci-static/resources/view/forkop/fonts/LICENSE.md'
                self.assertEqual((work / 'app/www' / font).read_bytes(), (ROOT / 'luci-app-forkop/htdocs' / font).read_bytes())
                self.assertTrue((work / 'i18n/usr/lib/lua/luci/i18n/forkop.ru.lmo').is_file())
                if attempt == 0:
                    for path in paths:
                        path.write_text('stale notice')

    def test_missing_source_license_fails_instead_of_building_without_it(self):
        recipes = BUILD[BUILD.index('\nmake_dir() {'):BUILD.index('\ngenerate_apk_metadata_files() {')]
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            source = work / 'source'
            source.mkdir()
            for name in ('forkop', 'luci-app-forkop', 'install.sh'):
                (source / name).symlink_to(ROOT / name)
            compiler = work / 'po2lmo'
            compiler.write_text('#!/bin/sh\ncp "$1" "$2"\n')
            compiler.chmod(0o755)
            for function in ('build_backend_root', 'build_app_root', 'build_i18n_root'):
                with self.subTest(function=function):
                    script = 'set -euo pipefail\n' + recipes + '\nROOT_DIR=$1 RELEASE_VERSION=2.0.0\n' + function + ' "$2/root" "$2/po2lmo"\n'
                    result = subprocess.run(['bash', '-c', script, 'license-test', str(source), str(work)], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('LICENSE', result.stderr)

    def test_feed_recipes_copy_the_same_license_without_changing_metadata(self):
        backend = (ROOT / 'forkop/Makefile').read_text()
        luci = (ROOT / 'luci-app-forkop/Makefile').read_text()
        self.assertIn('PKG_LICENSE:=GPL-2.0-or-later', backend)
        self.assertIn('PKG_LICENSE:=GPL-2.0-or-later', luci)
        self.assertIn('$(INSTALL_DATA) ../LICENSE $(1)/usr/share/licenses/forkop/LICENSE', backend)
        hook = re.search(r'define Build/Prepare/\$\(PKG_NAME\)\n(.*?)\nendef', luci, re.S)[1]
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            bundle = work / 'htdocs/luci-static/resources/view/forkop/main.js'
            bundle.parent.mkdir(parents=True)
            bundle.write_text('__COMPILED_VERSION_VARIABLE__')
            recipe = hook.replace('$(PKG_BUILD_DIR)', str(work)).replace('$(FORKOP_COMPILED_VERSION)', '2.0.0').replace('$(INSTALL_DIR)', 'install -d -m0755').replace('$(INSTALL_DATA)', 'install -m0644')
            result = subprocess.run(['bash', '-e', '-c', recipe], cwd=ROOT / 'luci-app-forkop', capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(bundle.read_text(), '2.0.0')
            self.assertEqual((work / 'root/usr/share/licenses/luci-app-forkop/LICENSE').read_bytes(), (ROOT / 'LICENSE').read_bytes())


if __name__ == '__main__':
    unittest.main()
