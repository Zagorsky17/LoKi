#!/usr/bin/env python3
"""Exercise beta download/admission ordering with BusyBox and synthetic private kits."""
import hashlib
import io
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BetaInstaller(unittest.TestCase):
    def run_installer(self, *, release='25.12.6', arch='aarch64_cortex-a53', **options):
        source = (ROOT/'install-beta.sh').read_text()
        with tempfile.TemporaryDirectory(prefix='loki-beta-test-') as tmp:
            home = Path(tmp)
            binaries = home/'bin'
            binaries.mkdir()
            events = home/'events'
            (home/'openwrt_release').write_text(f"DISTRIB_RELEASE='{release}'\nDISTRIB_ARCH='{arch}'\n")
            (home/'meminfo').write_text(f"MemAvailable: {options.get('memory', 204800)} kB\n")
            replacements = {}
            for version, original_hash, original_size in [
                ('24.10', '87327a8f430e1796624c37e852815603c0e7457078f83f907acc84374f137c52', 25501443),
                ('25.12', 'c9f1163d5bb9cb7c286802b63ff3660e7c8422852227a5687dea5122980741c9', 25487033),
            ]:
                files = {
                    'preflight.sh': b'#!/bin/sh\nprintf "preflight\\n" >> "$EVENTS"\nprintf "{\\"result\\":\\"checked\\"}\\n"\nexit "${PREFLIGHT_STATUS:-0}"\n',
                    'component-update.sh': b'#!/bin/sh\nprintf "worker:%s\\n" "$1" >> "$EVENTS"\nprintf "{\\"success\\":true}\\n"\nexit "${WORKER_STATUS:-0}"\n',
                    'candidate-manifest.json': b'{"synthetic":true}\n',
                }
                files['SHA256SUMS'] = ''.join(hashlib.sha256(body).hexdigest()+'  '+name+'\n' for name, body in sorted(files.items())).encode()
                name = f'loki-2.0.0-r10-openwrt-{version}-aarch64_cortex-a53-candidate.tar.gz'
                archive = home/name
                with tarfile.open(archive, 'w:gz') as tar:
                    for member, body in files.items():
                        info = tarfile.TarInfo(f'openwrt-{version}-aarch64_cortex-a53/'+member)
                        info.mode = 0o600
                        info.size = len(body)
                        tar.addfile(info, io.BytesIO(body))
                replacements[original_hash] = hashlib.sha256(archive.read_bytes()).hexdigest()
                replacements[str(original_size)] = str(archive.stat().st_size)
            (binaries/'wget').write_text(f'''#!{sys.executable}
import os,sys,pathlib
args=sys.argv[1:]
assert args[-1].startswith('https://github.com/Zagorsky17/LoKi/releases/download/2.0.0/')
with open(os.environ['EVENTS'],'a') as f:f.write('download:'+args[-1].split('/')[-1]+'\\n')
mode=os.environ.get('DOWNLOAD_CASE','')
if mode=='fail':sys.exit(8)
if mode=='hang':
 pathlib.Path(os.environ['PID_FILE']).write_text(str(os.getpid()))
 os.execv('/bin/sleep',['sleep','30'])
data=(pathlib.Path(os.environ['FIXTURE'])/args[-1].split('/')[-1]).read_bytes()
if mode=='corrupt':data=data[:-1]+bytes([data[-1]^1])
pathlib.Path(args[args.index('-O')+1]).write_bytes(data)
''')
            (binaries/'id').write_text('#!/bin/sh\nprintf "%s\\n" "${FAKE_UID:-0}"\n')
            (binaries/'df').write_text('#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted on\\nnone 999999 0 %s 0%% /tmp\\n" "${TMP_FREE:-204800}"\n')
            for path in binaries.iterdir(): path.chmod(0o700)
            for old, new in replacements.items(): source = source.replace(old, new)
            source = source.replace('/etc/openwrt_release', str(home/'openwrt_release')).replace('/proc/meminfo', str(home/'meminfo'))
            source = source.replace('/tmp/loki-beta.XXXXXX', str(home/'loki-beta.XXXXXX'))
            source = source.replace('DOWNLOAD_SECONDS=35', 'DOWNLOAD_SECONDS=1')
            # Standalone BusyBox applets bypass PATH; replace only these dependency calls in the fixture.
            source = source.replace('exec wget ', 'exec '+shlex.quote(str(binaries/'wget'))+' ')
            source = source.replace('$(id -u)', '$('+shlex.quote(str(binaries/'id'))+' -u)')
            source = source.replace('df -Pk /tmp', shlex.quote(str(binaries/'df'))+' -Pk /tmp')
            source = source.rsplit('\nmain "$@"', 1)[0]
            source += '\nPATH='+shlex.quote(str(binaries))+':/usr/bin:/bin\nexport PATH\nmain "$@"\n'
            script = home/'installer.sh'
            script.write_text(source)
            env = dict(os.environ, EVENTS=str(events), FIXTURE=str(home), PID_FILE=str(home/'pid'),
                       DOWNLOAD_CASE=options.get('download', ''), PREFLIGHT_STATUS=str(options.get('preflight', 0)),
                       WORKER_STATUS=str(options.get('worker', 0)), TMP_FREE=str(options.get('space', 204800)),
                       FAKE_UID=str(options.get('uid', 0)))
            process = subprocess.run([shutil.which('busybox'), 'ash', '-c', '(set -o pipefail; cat "$1" | sh)', 'beta', str(script)], env=env, capture_output=True, text=True, timeout=8)
            recorded = events.read_text().splitlines() if events.exists() else []
            preserved = [p for p in home.glob('loki-beta.*') if p.is_dir()]
            self.assertTrue(all(p.stat().st_mode & 0o777 == 0o700 for p in preserved))
            if (home/'pid').exists(): self.assertFalse(Path('/proc/'+(home/'pid').read_text()).exists(), 'download child leaked')
            return process, recorded, len(preserved)

    def test_both_versions_use_preflight_before_install_and_clean_up(self):
        for version in ['24.10.5', '25.12.6']:
            with self.subTest(version=version):
                p, events, kept = self.run_installer(release=version)
                self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
                self.assertIn('openwrt-'+'.'.join(version.split('.')[:2]), events[0])
                self.assertEqual(events[1:], ['preflight', 'worker:install'])
                self.assertEqual(kept, 0)

    def test_unsupported_system_root_and_resources_refuse_before_download(self):
        for options in [dict(arch='x86_64'), dict(release='23.05.5'), dict(uid=1000), dict(memory=20000), dict(space=20000)]:
            with self.subTest(options=options):
                p, events, kept = self.run_installer(**options)
                self.assertNotEqual(p.returncode, 0)
                self.assertEqual(events, [])
                self.assertEqual(kept, 0)

    def test_download_failure_checksum_and_timeout_never_run_kit(self):
        for mode in ['fail', 'corrupt', 'hang']:
            with self.subTest(mode=mode):
                p, events, kept = self.run_installer(download=mode)
                self.assertNotEqual(p.returncode, 0)
                self.assertEqual(len(events), 1)
                self.assertEqual(kept, 0)

    def test_incomplete_or_conflicting_preflight_never_installs(self):
        for status in [1, 2]:
            p, events, kept = self.run_installer(preflight=status)
            self.assertNotEqual(p.returncode, 0)
            self.assertEqual(events[1:], ['preflight'])
            self.assertEqual(kept, 0)

    def test_worker_failure_preserves_private_recovery_kit(self):
        p, events, kept = self.run_installer(worker=1)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(events[1:], ['preflight', 'worker:install'])
        self.assertEqual(kept, 1)
        self.assertIn('recover', p.stdout+p.stderr)


if __name__ == '__main__':
    if sys.platform != 'linux': raise SystemExit('Run only on the Linux build host')
    unittest.main()
