"""Exercise package-root recipes without an SDK, package manager or downloads."""
# Modified for LoKi on 2026-11-04: preserve the root license in distributed payloads.
# Modified for LoKi on 2026-11-06: verify bundled YACD notices in both package recipes.
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BUILD = (ROOT / 'build.sh').read_text()


class LicensePayloadTests(unittest.TestCase):
    def test_apk_verification_rejects_unmapped_or_missing_owners(self):
        verify = BUILD[BUILD.index('\nverify_apk_metadata() {'):BUILD.index('\ncleanup_work_dir() {')]
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            apk = work / 'apk'
            apk.write_text('#!/bin/sh\ncat "$DUMP_FIXTURE"\n')
            apk.chmod(0o755)
            fixture = work / 'dump'
            for ownership, accepted in [('user: root\n      group: root', True),
                                        ('user: nobody\n      group: nogroup', False),
                                        ('mode: 0644', False)]:
                with self.subTest(ownership=ownership):
                    fixture.write_text('  name: luci-app-loki\n  version: 2.0.0\n  depends:\n    - loki>=2.0.0\n'
                                       'paths:\n  - acl:\n      ' + ownership + '\n')
                    result = subprocess.run(
                        ['bash', '-c', 'set -euo pipefail\n' + verify +
                         '\nverify_apk_metadata "$1" "$2" luci-app-loki 2.0.0\n',
                         'apk-owner-test', str(apk), str(work / 'package.apk')],
                        env={**os.environ, 'DUMP_FIXTURE': str(fixture)}, capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, accepted, result.stderr)

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
            payloads = {'backend': 'loki', 'app': 'luci-app-loki', 'i18n': 'luci-i18n-loki-ru'}
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
                self.assertEqual((work / 'backend/usr/share/loki/install.sh').read_bytes(), (ROOT / 'install.sh').read_bytes())
                font = 'luci-static/resources/view/loki/fonts/LICENSE.md'
                self.assertEqual((work / 'app/www' / font).read_bytes(), (ROOT / 'luci-app-loki/htdocs' / font).read_bytes())
                yacd_license = work / 'app/usr/share/licenses/luci-app-loki/YACD-LICENSE'
                self.assertEqual(yacd_license.read_bytes(), (ROOT / 'yacd-loki/LICENSE').read_bytes())
                self.assertEqual(yacd_license.stat().st_mode & 0o777, 0o644)
                for installed_name, asset_name in [
                    ('YACD-THIRD-PARTY-NOTICES', 'THIRD_PARTY_NOTICES.txt'),
                    ('YACD-THIRD-PARTY-INVENTORY', 'THIRD_PARTY_INVENTORY.json'),
                ]:
                    notice = yacd_license.parent / installed_name
                    self.assertTrue(notice.is_file(), 'bundled dependency notices must reach the package license directory')
                    source = ROOT / 'yacd-loki/licenses' / asset_name
                    self.assertEqual(notice.read_bytes(), source.read_bytes())
                    self.assertEqual(notice.stat().st_mode & 0o777, 0o644)
                for package_name, source_name in [('INTER-OFL', 'inter-OFL.txt'), ('ROBOTO-MONO-OFL', 'roboto-mono-OFL.txt')]:
                    notice = yacd_license.parent / package_name
                    self.assertEqual(notice.read_bytes(), (ROOT / 'yacd-loki/licenses' / source_name).read_bytes())
                    self.assertEqual(notice.stat().st_mode & 0o777, 0o644)
                source_assets = ROOT / 'luci-app-loki/root/usr/share/loki/yacd'
                packaged_assets = work / 'app/usr/share/loki/yacd'
                source_files = {str(p.relative_to(source_assets)): p.read_bytes() for p in source_assets.rglob('*') if p.is_file()}
                packaged_files = {str(p.relative_to(packaged_assets)): p.read_bytes() for p in packaged_assets.rglob('*') if p.is_file()}
                self.assertEqual(packaged_files, source_files)
                self.assertIn('index.html', packaged_files)
                self.assertFalse(any(name.startswith('sw') for name in packaged_files))
                scripts = b''.join(body for name, body in packaged_files.items() if name.endswith('.js'))
                for forbidden in (b'/rules/disable', b'/upgrade/', b'/backend', b'?token=', b'serviceWorker', b'127.0.0.1:9090'):
                    self.assertNotIn(forbidden, scripts)
                self.assertFalse((work / 'app/www/cgi-bin/luci/loki-gateway').exists())
                self.assertTrue((work / 'i18n/usr/lib/lua/luci/i18n/loki.ru.lmo').is_file())
                self.assertFalse((work / 'i18n/etc/uci-defaults').exists(),
                                 'installing the LoKi locale must not write global LuCI settings')
                installed = {str(path.relative_to(work / 'backend')) for path in (work / 'backend').rglob('*')}
                self.assertTrue({'usr/bin/loki', 'etc/init.d/loki', 'etc/init.d/loki-state', 'etc/config/loki',
                                 'usr/lib/loki/service/lifecycle.uc', 'usr/libexec/loki-gateway'} <= installed,
                                'standalone packages must contain the gateway bootstrap used by loki-state')
                helper = work / 'backend/usr/libexec/loki-gateway'
                self.assertEqual(helper.read_bytes(), (ROOT / 'loki/files/usr/libexec/loki-gateway').read_bytes())
                self.assertEqual(helper.stat().st_mode & 0o777, 0o755)
                self.assertEqual(helper.parent.stat().st_mode & 0o777, 0o755)
                self.assertEqual((work / 'backend/etc/config/loki').stat().st_mode & 0o777, 0o600,
                                 'the mutable credential store must be private before its first commit')
                self.assertEqual((work / 'backend/usr/share/loki/default-config').stat().st_mode & 0o777, 0o644)
                self.assertFalse(any('forkop' in path for path in installed), 'legacy installed entrypoints must be absent')
                acl_path = work / 'app/usr/share/rpcd/acl.d/luci-app-loki.json'
                acl = json.loads(acl_path.read_text())
                self.assertEqual(set(acl), {'luci-app-loki'})
                self.assertTrue({'loki', 'loki.installer'} <= set(acl['luci-app-loki']['read']['ubus']))
                self.assertFalse({'forkop', 'forkop.installer'} & set(acl['luci-app-loki']['read']['ubus']))
                self.assertEqual(acl['luci-app-loki']['write']['uci'], {'loki': ['read', 'write']})
                self.assertNotIn('loki', acl['luci-app-loki']['read']['uci'])
                for payload in ('app', 'i18n'):
                    self.assertFalse(any('forkop' in str(path.relative_to(work / payload))
                                         for path in (work / payload).rglob('*')), 'legacy LuCI/ACL/locale paths must be absent')
                if attempt == 0:
                    for path in paths:
                        path.write_text('stale notice')
                    helper.write_text('stale gateway bootstrap')
                    helper.chmod(0o600)

    def test_missing_gateway_bootstrap_refuses_backend_payload(self):
        recipes = BUILD[BUILD.index('\nmake_dir() {'):BUILD.index('\ngenerate_apk_metadata_files() {')]
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            source = work / 'source'
            source.mkdir()
            shutil.copytree(ROOT / 'loki', source / 'loki')
            (source / 'loki/files/usr/libexec/loki-gateway').unlink()
            for name in ('install.sh', 'LICENSE'):
                (source / name).symlink_to(ROOT / name)
            script = 'set -euo pipefail\n' + recipes + '\nROOT_DIR=$1 RELEASE_VERSION=2.0.0\nbuild_backend_root "$2/backend"\n'
            result = subprocess.run(['bash', '-c', script, 'gateway-payload-test', str(source), str(work)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, 'backend payload silently omitted its required gateway bootstrap')
            self.assertIn('loki-gateway', result.stderr)

    def test_missing_source_license_fails_instead_of_building_without_it(self):
        recipes = BUILD[BUILD.index('\nmake_dir() {'):BUILD.index('\ngenerate_apk_metadata_files() {')]
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            source = work / 'source'
            source.mkdir()
            for name in ('loki', 'luci-app-loki', 'install.sh'):
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
        backend = (ROOT / 'loki/Makefile').read_text()
        luci = (ROOT / 'luci-app-loki/Makefile').read_text()
        self.assertIn('PKG_LICENSE:=GPL-2.0-or-later', backend)
        self.assertIn('PKG_LICENSE:=GPL-2.0-or-later AND MIT AND Apache-2.0 AND 0BSD AND OFL-1.1', luci)
        self.assertIn('$(INSTALL_DATA) ../LICENSE $(1)/usr/share/licenses/loki/LICENSE', backend)
        hook = re.search(r'define Build/Prepare/\$\(PKG_NAME\)\n(.*?)\nendef', luci, re.S)[1]
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            bundle = work / 'htdocs/luci-static/resources/view/loki/main.js'
            bundle.parent.mkdir(parents=True)
            bundle.write_text('__COMPILED_VERSION_VARIABLE__')
            recipe = hook.replace('$(PKG_BUILD_DIR)', str(work)).replace('$(LOKI_COMPILED_VERSION)', '2.0.0').replace('$(INSTALL_DIR)', 'install -d -m0755').replace('$(INSTALL_DATA)', 'install -m0644')
            result = subprocess.run(['bash', '-e', '-c', recipe], cwd=ROOT / 'luci-app-loki', capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(bundle.read_text(), '2.0.0')
            self.assertEqual((work / 'root/usr/share/licenses/luci-app-loki/LICENSE').read_bytes(), (ROOT / 'LICENSE').read_bytes())
            self.assertEqual((work / 'root/usr/share/licenses/luci-app-loki/YACD-LICENSE').read_bytes(), (ROOT / 'yacd-loki/LICENSE').read_bytes())
            for package_name, source_name in [('INTER-OFL', 'inter-OFL.txt'), ('ROBOTO-MONO-OFL', 'roboto-mono-OFL.txt')]:
                self.assertEqual((work / 'root/usr/share/licenses/luci-app-loki' / package_name).read_bytes(), (ROOT / 'yacd-loki/licenses' / source_name).read_bytes())
            for package_name, source_name in [('YACD-THIRD-PARTY-NOTICES', 'THIRD_PARTY_NOTICES.txt'),
                                              ('YACD-THIRD-PARTY-INVENTORY', 'THIRD_PARTY_INVENTORY.json')]:
                self.assertEqual((work / 'root/usr/share/licenses/luci-app-loki' / package_name).read_bytes(), (ROOT / 'yacd-loki/licenses' / source_name).read_bytes())


if __name__ == '__main__':
    unittest.main()
