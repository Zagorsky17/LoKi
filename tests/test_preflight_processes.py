"""Exercise bounded process discovery using fixtures and only our own Linux children."""
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def stat(pid='42', comm='private )\n(comm', start='18446744073709551615'):
    fields = ['S'] + ['0'] * 49
    fields[19] = start
    return f'{pid} ({comm}) ' + ' '.join(fields) + '\n'


class ProcessProbe(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='loki-processes-')
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.proc = self.root / 'proc'
        self.proc.mkdir(mode=0o755)
        self.pid = self.proc / '42'
        self.pid.mkdir(mode=0o755)
        (self.pid / 'stat').write_text(stat())
        (self.pid / 'stat').chmod(0o644)
        (self.root / 'loki-core').write_text('private unexecuted fixture')
        (self.pid / 'exe').symlink_to(self.root / 'loki-core')

    def run_ucode(self, program, *args):
        done = subprocess.run(['ucode', '-L', str(ROOT / 'loki/files/usr/lib'), '-e',
                               'let fs=require("fs");let p=require("service.preflight_processes");' + program,
                               *map(str, args)], capture_output=True, text=True, timeout=20)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stderr, '')
        return json.loads(done.stdout)

    def collect(self):
        return self.run_ucode('print(sprintf("%J",p.collect(ARGV[0])));', self.root)

    @staticmethod
    def reasons(result):
        return {item['reason'] for item in result}

    def test_actual_procfs_nonroot_child_stat_zero_size_and_native_name_hint(self):
        binary = self.root / 'loki-core'
        shutil.copyfile('/bin/sleep', binary)
        binary.chmod(0o700)
        with subprocess.Popen([str(binary), '30'], env=dict(os.environ, LOKI_TEST_SECRET='private-env-canary')) as child:
            try:
                result = self.run_ucode('''let open=fs.opendir;
                    fs.opendir=(path)=>{let handle=open(path);if(path!="/proc")return handle;
                        let emitted=false;return {fileno:()=>handle.fileno(),
                        read:()=>{if(emitted)return null;emitted=true;return ARGV[0];},close:()=>handle.close()};};
                    let first=fs.lstat("/proc/"+ARGV[0]+"/stat");
                    print(sprintf("%J",{zero:first.size==0,nonroot:first.uid!=0,result:p.collect("/")}));''', child.pid)
                self.assertTrue(result['zero'])
                self.assertTrue(result['nonroot'], 'Run as the ordinary test account')
                self.assertIn('process-directory-read-complete', self.reasons(result['result']))
                self.assertTrue(any(x['object'] == 'own-core' and x['reason'] ==
                                    'process-executable-name-hint-unverified' for x in result['result']))
                self.assertNotIn('private-env-canary', json.dumps(result))
                self.assertNotIn(str(self.root), json.dumps(result))
            finally:
                child.terminate()
                child.wait(timeout=5)

    def test_real_child_comm_with_parentheses_newline_and_secret_argv_is_not_disclosed(self):
        program = ('import ctypes,sys;'
                   'assert ctypes.CDLL(None).prctl(15,b"private)\\n(name",0,0,0)==0;'
                   'print("ready",flush=True);sys.stdin.read()')
        with subprocess.Popen([sys.executable, '-c', program, 'private-argv-canary'],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
            try:
                self.assertTrue(select.select([child.stdout], [], [], 5)[0], 'child readiness timed out')
                self.assertEqual(os.read(child.stdout.fileno(), 6), b'ready\n')
                with open(f'/proc/{child.pid}/stat', 'rb') as stream:
                    self.assertIn(b'private)\n(name', stream.read(4097))
                result = self.run_ucode('''let file=fs.open("/proc/"+ARGV[0]+"/stat","re");
                    let value=p.parse(file.read(4097),ARGV[0]);file.close();
                    print(sprintf("%J",{valid:value.error==null,precise:type(value.start)=="string"}));''', child.pid)
                self.assertEqual(result, {'valid': True, 'precise': True})
            finally:
                child.terminate()
                child.wait(timeout=5)

    def test_stat_fifo_hardlink_symlink_and_missing_exe_fail_closed(self):
        path = self.pid / 'stat'
        path.unlink()
        os.mkfifo(path)
        self.assertIn('process-stat-unavailable', self.reasons(self.collect()))
        path.unlink()
        path.symlink_to(self.root / 'loki-core')
        self.assertIn('process-stat-unavailable', self.reasons(self.collect()))
        path.unlink()
        path.write_text(stat())
        os.link(path, self.root / 'hardlink')
        self.assertIn('process-stat-unavailable', self.reasons(self.collect()))
        (self.root / 'hardlink').unlink()
        (self.pid / 'exe').unlink()
        self.assertIn('process-executable-unavailable', self.reasons(self.collect()))
        self.assertNotIn('process-directory-read-complete', self.reasons(self.collect()))

    def test_root_proc_and_pid_links_or_writable_parents_are_refused(self):
        (self.pid / 'stat').unlink()
        (self.pid / 'exe').unlink()
        self.pid.rmdir()
        self.pid.symlink_to(self.root, target_is_directory=True)
        self.assertIn('process-directory-entry-unavailable', self.reasons(self.collect()))
        self.proc.chmod(0o777)
        self.assertIn('process-directory-unavailable', self.reasons(self.collect()))
        self.proc.chmod(0o755)
        self.root.chmod(0o777)
        self.assertIn('process-directory-unavailable', self.reasons(self.collect()))
        self.root.chmod(0o700)

    def test_reads_only_stat_and_exe_without_spawn_or_persistent_changes(self):
        before = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*')
                  if p.is_file() and not p.is_symlink()}
        result = self.run_ucode('''let open=fs.open;fs.open=(path,mode)=>{
                if(path!=ARGV[0]+"/proc/42/stat"||mode!="re")die("unexpected read");return open(path,mode);};
            fs.readfile=()=>die("unexpected unbounded read");fs.popen=()=>die("unexpected command");
            global.system=()=>die("unexpected command");
            let before=length(fs.lsdir("/proc/self/fd"));let first;
            for(let i=0;i<40;i++){let result=p.collect(ARGV[0]);
                if(i==0)first=result;else if(sprintf("%J",first)!=sprintf("%J",result))die("changed");}
            print(sprintf("%J",{result:first,handles_unchanged:before==length(fs.lsdir("/proc/self/fd"))}));''', self.root)
        after = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*')
                 if p.is_file() and not p.is_symlink()}
        self.assertEqual(before, after)
        self.assertTrue(result['handles_unchanged'])
        self.assertIn('process-directory-read-complete', self.reasons(result['result']))
        self.assertNotIn('private', json.dumps(result))

    def test_genuine_oversized_stat_and_invalid_numeric_pid_never_claim_coverage(self):
        (self.pid / 'stat').write_bytes(b'x' * 4097)
        self.assertIn('process-stat-size-limit', self.reasons(self.collect()))
        (self.pid / 'stat').write_text(stat())
        (self.proc / '00042').mkdir()
        result = self.collect()
        self.assertIn('process-directory-entry-invalid', self.reasons(result))
        self.assertNotIn('process-directory-read-complete', self.reasons(result))


if __name__ == '__main__':
    if sys.platform != 'linux':
        raise SystemExit('Run on Linux; genuine procfs coverage is required')
    unittest.main()
