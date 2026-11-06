"""Run package hook bodies with an isolated LoKi command, without a package manager."""
from pathlib import Path
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def feed_hook(package, hook):
    recipe = (ROOT / package / 'Makefile').read_text()
    found = re.search(r'^define Package/' + re.escape(package + '/' + hook) +
                      r'\n(.*?)\nendef', recipe, re.M | re.S)
    if not found:
        raise AssertionError(package + ' has no ' + hook + ' hook')
    return found[1].replace('$$', '$')


class NativeHooksTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.calls = self.work / 'calls'
        self.command = self.work / 'loki'
        self.command.write_text('#!' + sys.executable + '\nimport json, os, sys\n'
                                'with open(os.environ["HOOK_CALLS"], "a") as output:\n'
                                '    output.write(json.dumps(sys.argv[1:]) + "\\n")\n'
                                'sys.exit(int(os.environ.get("HOOK_STATUS", "0")))\n')
        self.command.chmod(0o755)

    def run_hook(self, body, arguments=(), *, image=False, status=0, upgrade=False):
        body = body.replace('/usr/bin/loki', shlex.quote(str(self.command)))
        syntax = subprocess.run(['sh', '-n'], input=body, capture_output=True, text=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        environment = {key: value for key, value in os.environ.items()
                       if key not in ['IPKG_INSTROOT', 'PKG_UPGRADE']}
        environment.update(HOOK_CALLS=str(self.calls), HOOK_STATUS=str(status))
        if image:
            environment['IPKG_INSTROOT'] = str(self.work / 'image')
        if upgrade:
            environment['PKG_UPGRADE'] = '1'
        if self.calls.exists():
            self.calls.unlink()
        result = subprocess.run(['sh', '-c', body, 'synthetic-hook', *arguments],
                                env=environment, capture_output=True, text=True)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] if self.calls.exists() else []
        return result, calls

    def test_feed_backend_prerm_accepts_the_sdk_wrapper_arguments(self):
        body = feed_hook('loki', 'prerm')
        for action in ['remove', 'upgrade', 'remove; touch ' + str(self.work / 'injection')]:
            with self.subTest(action=action):
                result, calls = self.run_hook(body, ['/synthetic/loki.prerm', action])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, [['package_prerm', action]])
                self.assertFalse((self.work / 'injection').exists())
        result, calls = self.run_hook(body, ['/synthetic/loki.prerm', 'remove'], image=True)
        self.assertEqual((result.returncode, calls), (0, []))
        result, calls = self.run_hook(body, ['/synthetic/loki.prerm', 'upgrade'], status=23)
        self.assertEqual((result.returncode, calls), (23, [['package_prerm', 'upgrade']]))

    def test_feed_backend_preinst_only_stops_for_an_apk_upgrade(self):
        body = feed_hook('loki', 'preinst')
        for image, upgrade, expected in [(False, False, []), (True, True, []),
                                         (False, True, [['package_prerm', 'upgrade']])]:
            with self.subTest(image=image, upgrade=upgrade):
                result, calls = self.run_hook(body, image=image, upgrade=upgrade)
                self.assertEqual((result.returncode, calls), (0, expected))
        result, calls = self.run_hook(body, upgrade=True, status=23)
        self.assertEqual((result.returncode, calls), (23, [['package_prerm', 'upgrade']]))

    def test_feed_luci_hooks_call_the_owned_service_and_preserve_failures(self):
        for hook, command in [('postinst', 'luci_postinst'), ('prerm', 'luci_prerm')]:
            with self.subTest(hook=hook):
                body = feed_hook('luci-app-loki', hook)
                for attempt in range(2):
                    result, calls = self.run_hook(body)
                    self.assertEqual((result.returncode, calls), (0, [[command]]))
                result, calls = self.run_hook(body, image=True)
                self.assertEqual((result.returncode, calls), (0, []))
                result, calls = self.run_hook(body, status=23)
                self.assertEqual((result.returncode, calls), (23, [[command]]))

    def test_standalone_luci_hooks_do_not_run_shared_package_defaults(self):
        build = (ROOT / 'build.sh').read_text()
        ipk = build[build.index('\nwrite_app_ipk_control() {'):build.index('\nbuild_ipk_package() {')]
        apk = build[build.index('\nwrite_app_apk_scripts() {'):build.index('\nwrite_i18n_apk_scripts() {')]
        script = ('set -eu\nmake_dir() { mkdir -p "$1"; }\n' + ipk + apk +
                  '\nRELEASE_VERSION=2.0.0 APP_DEPENDS_IPK=synthetic PROJECT_URL=synthetic '
                  'MAINTAINER=synthetic APP_DESCRIPTION=synthetic\n'
                  'write_app_ipk_control "$1/ipk" 1\nwrite_app_apk_scripts "$1/apk"\n')
        result = subprocess.run(['bash', '-c', script, 'synthetic-packager', str(self.work)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for path, command in [('ipk/postinst', 'luci_postinst'), ('ipk/prerm', 'luci_prerm'),
                              ('apk/app-post-install.sh', 'luci_postinst'),
                              ('apk/app-post-upgrade.sh', 'luci_postinst'),
                              ('apk/app-pre-deinstall.sh', 'luci_prerm')]:
            with self.subTest(path=path):
                body = (self.work / path).read_text()
                self.assertNotIn('default_postinst', body, 'shared defaults may commit unrelated pending UCI')
                self.assertNotIn('default_prerm', body)
                result, calls = self.run_hook(body)
                self.assertEqual((result.returncode, calls), (0, [[command]]))
                result, calls = self.run_hook(body, image=True)
                self.assertEqual((result.returncode, calls), (0, []))
                result, calls = self.run_hook(body, status=23)
                self.assertEqual((result.returncode, calls), (23, [[command]]))

    def test_standalone_backend_removal_and_upgrade_keep_arguments_and_errors(self):
        build = (ROOT / 'build.sh').read_text()
        ipk = build[build.index('\nwrite_backend_ipk_control() {'):build.index('\nwrite_app_ipk_control() {')]
        apk = build[build.index('\nwrite_backend_apk_scripts() {'):build.index('\nwrite_app_apk_scripts() {')]
        script = ('set -eu\nmake_dir() { mkdir -p "$1"; }\n' + ipk + apk +
                  '\nRELEASE_VERSION=2.0.0 BACKEND_DEPENDS_IPK=synthetic PROJECT_URL=synthetic '
                  'MAINTAINER=synthetic BACKEND_DESCRIPTION=synthetic\n'
                  'write_backend_ipk_control "$1/backend-ipk" 1\nwrite_backend_apk_scripts "$1/backend-apk"\n')
        result = subprocess.run(['bash', '-c', script, 'synthetic-packager', str(self.work)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for path, arguments, action in [
            ('backend-ipk/prerm', ['upgrade'], 'upgrade'),
            ('backend-ipk/prerm', [], 'remove'),
            ('backend-ipk/prerm', ['remove; touch ' + str(self.work / 'injection')],
             'remove; touch ' + str(self.work / 'injection')),
            ('backend-apk/backend-pre-deinstall.sh', [], 'remove'),
            ('backend-apk/backend-pre-upgrade.sh', [], 'upgrade'),
        ]:
            with self.subTest(path=path, arguments=arguments):
                body = (self.work / path).read_text()
                result, calls = self.run_hook(body, arguments)
                self.assertEqual((result.returncode, calls), (0, [['package_prerm', action]]))
                result, calls = self.run_hook(body, arguments, image=True)
                self.assertEqual((result.returncode, calls), (0, []))
                result, calls = self.run_hook(body, arguments, status=23)
                self.assertEqual((result.returncode, calls), (23, [['package_prerm', action]]))
                self.assertFalse((self.work / 'injection').exists())

    def test_luci_has_no_uci_defaults_that_commit_other_pending_settings(self):
        self.assertEqual(list((ROOT / 'luci-app-loki/root/etc/uci-defaults').glob('*')), [])


if __name__ == '__main__':
    unittest.main()
