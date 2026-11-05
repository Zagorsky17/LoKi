"""Check prepared core data notices and the exact bundled font attribution."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
DATA = ('MPL-2.0.txt', 'publicsuffix-NOTICE.txt')
MPL_SHA = '66a3107d5ad6a058aab753eaac2047ccb2ed0e39465dd0fe5844da3e300d5172'
FONT_SHA = '9f04f14429bb6a9f415c7a4dd902a918d7e81a4f7526c415496fdb063954e3b8'
LICENSE_SHA = 'aa92b722615382b3f4d3e3a8049abe55ccac3a62ccd0c7902dd9c23588dabdb2'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class DataNotices(unittest.TestCase):
    def test_reviewed_core_map_requires_exact_mpl_and_psl_notice(self):
        reviewed = json.loads((ROOT / 'core/notice-files.json').read_text())
        self.assertEqual(sha(ROOT / 'core/source-data/MPL-2.0.txt'), MPL_SHA)
        for name in DATA:
            self.assertEqual(reviewed['core'].get('release/forkop/source-data/' + name),
                             sha(ROOT / 'core/source-data' / name))
        notice = (ROOT / 'core/source-data/publicsuffix-NOTICE.txt').read_text()
        for expected in ('MPL-2.0', 'd6c92f1bbb7433e5db7b8405c25d4035fb8ff376', 'golang.org/x/net@v0.57.0',
                         'core-module-sources-', 'public_suffix_list.dat'):
            self.assertIn(expected, notice)

    def prepare_fixture(self, work):
        core = work / 'core'
        core.mkdir()
        (core / 'patches').mkdir()
        for name in ('prepare.sh', 'COPYING', 'notices.py', 'notice-files.json'):
            shutil.copyfile(ROOT / 'core' / name, core / name)
        shutil.copytree(ROOT / 'core/source-data', core / 'source-data')
        (core / 'patches/0001-fixture.patch').write_text(
            'diff --git a/fixture b/fixture\n--- a/fixture\n+++ b/fixture\n@@ -1 +1 @@\n-before\n+after\n')
        cache = work / 'cache/loki/core'
        cache.mkdir(parents=True)
        archive = cache / 'fixture.tar.gz'
        with tarfile.open(archive, 'w:gz') as out:
            directory = tarfile.TarInfo('upstream/release/forkop')
            directory.type, directory.mode = tarfile.DIRTYPE, 0o755
            out.addfile(directory)
            member = tarfile.TarInfo('upstream/fixture')
            member.size, member.mode = len(b'before\n'), 0o644
            out.addfile(member, io.BytesIO(b'before\n'))
        (core / 'upstream.env').write_text('CORE_COMMIT=fixture\nCORE_ARCHIVE_SHA256=' + sha(archive) + '\n')
        environment = dict(os.environ, XDG_CACHE_HOME=str(work / 'cache'))
        return core, environment

    def test_actual_prepare_copies_data_and_refuses_missing_required_input(self):
        with tempfile.TemporaryDirectory(prefix='loki-data-notice-') as directory:
            work = Path(directory)
            core, environment = self.prepare_fixture(work)
            destination = work / 'prepared'
            done = subprocess.run(['bash', str(core / 'prepare.sh'), str(destination)],
                                  env=environment, capture_output=True, timeout=20)
            self.assertEqual(done.returncode, 0, done.stderr.decode())
            self.assertEqual((destination / 'fixture').read_bytes(), b'after\n')
            for name in DATA:
                self.assertEqual((destination / 'release/forkop/source-data' / name).read_bytes(),
                                 (ROOT / 'core/source-data' / name).read_bytes())
            for index, name in enumerate(DATA):
                with self.subTest(name=name):
                    original = core / 'source-data' / name
                    backup = original.read_bytes()
                    original.unlink()
                    done = subprocess.run(['bash', str(core / 'prepare.sh'), str(work / f'missing-{index}')],
                                          env=environment, capture_output=True, timeout=20)
                    self.assertNotEqual(done.returncode, 0)
                    original.write_bytes(backup)

    def test_exact_upstream_font_license_provenance_and_unchanged_font(self):
        fonts = ROOT / 'luci-app-loki/htdocs/luci-static/resources/view/loki/fonts'
        self.assertEqual(sha(fonts / 'TwemojiCountryFlags.woff2'), FONT_SHA)
        self.assertEqual(sha(fonts / 'UPSTREAM_LICENSE.md'), LICENSE_SHA)
        provenance = (fonts / 'PROVENANCE.md').read_text()
        for expected in ('country-flag-emoji-polyfill', '0.1.8', FONT_SHA, LICENSE_SHA,
                         '9682bbff0e201fee118803997d7fda872c2edad3fdef3a3aa1263249ca2c9468'):
            self.assertIn(expected, provenance)
        self.assertIn('Creative Commons Attribution 4.0', (fonts / 'LICENSE.md').read_text())

    def test_actual_prepare_refuses_a_missing_mpl_input(self):
        with tempfile.TemporaryDirectory(prefix='loki-missing-mpl-') as directory:
            work = Path(directory)
            core, environment = self.prepare_fixture(work)
            (core / 'source-data/MPL-2.0.txt').unlink()
            done = subprocess.run(['bash', str(core / 'prepare.sh'), str(work / 'prepared')],
                                  env=environment, capture_output=True, timeout=20)
            self.assertNotEqual(done.returncode, 0)


if __name__ == '__main__':
    unittest.main()
