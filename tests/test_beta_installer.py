#!/usr/bin/env python3
"""Check that the compatibility URL runs only a complete installer download."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class BetaInstaller(unittest.TestCase):
    def invoke(self, download_status=0, installer_status=0):
        busybox=shutil.which('busybox');self.assertIsNotNone(busybox)
        with tempfile.TemporaryDirectory(prefix='loki-bootstrap-test-') as directory:
            home=Path(directory);marker=home/'executed';fetch=home/'wget';wrapper=home/'bootstrap.sh'
            payload='#!/bin/sh\nprintf \'%s\\n\' "$@" >'+shlex.quote(str(marker))+'\nexit '+str(installer_status)+'\n'
            fetch.write_text('#!'+sys.executable+'\n'+f'''import sys,stat
from pathlib import Path
assert sys.argv[1:4]==['-T','30','-O']
assert sys.argv[5]=='https://raw.githubusercontent.com/Zagorsky17/LoKi/main/install.sh'
p=Path(sys.argv[4]);assert stat.S_IMODE(p.stat().st_mode)==0o600
p.write_text({payload!r})
raise SystemExit({download_status})
''');fetch.chmod(0o755)
            source=(ROOT/'install-beta.sh').read_text().replace('wget -T',shlex.quote(str(fetch))+' -T',1).replace('/tmp/loki-bootstrap.XXXXXX',str(home/'download.XXXXXX'))
            wrapper.write_text(source)
            done=subprocess.run([busybox,'ash',str(wrapper),'--uninstall','--lang','ru'],capture_output=True,text=True,timeout=5)
            result=marker.read_text() if marker.exists() else None
            self.assertFalse(list(home.glob('download.*')))
            return done.returncode,result

    def test_complete_download_forwards_arguments_and_status(self):
        for code in [0,7]:
            with self.subTest(exit=code):self.assertEqual(self.invoke(installer_status=code),(code,'--uninstall\n--lang\nru\n'))

    def test_failed_download_never_executes_a_partial_script(self):
        status,result=self.invoke(download_status=8)
        self.assertNotEqual(status,0);self.assertIsNone(result)


if __name__=='__main__':
    if sys.platform!='linux':raise SystemExit('Run on the Linux test server')
    unittest.main()
