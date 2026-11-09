"""Read native Linux resource counters without installing or applying LoKi."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
QUERY = ['/usr/bin/env', '-i', 'PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL=C', '/bin/df', '-Pk', '/', '/tmp']


class NativeResources(unittest.TestCase):
    def collect(self, root):
        script = r'''
let fs=require("fs");
let open=fs.open;
let e=require("core.exec"),deadline=e.deadline;
let mkdir=fs.mkdir,unlink=fs.unlink,rmdir=fs.rmdir;
let reads=[];
let commands=[],writes=[],temporary=null;
fs.open=(path,mode)=>{if(mode!="re")die("unexpected write mode");push(reads,{path,mode});return open(path,mode);};
for(let name in ["writefile","chmod","chown","rename","symlink","mkstemp"])
    fs[name]=()=>die("unexpected filesystem mutation");
fs.mkdir=(path,mode)=>{
    assert(temporary==null && mode==0700 && index(path,"/tmp/loki-query."+require("core.common").own_pid()+".")==0);
    temporary=path;push(writes,"mkdir");return mkdir(path,mode);
};
fs.unlink=(path)=>{assert(path==temporary+"/ready");push(writes,"unlink");return unlink(path);};
fs.rmdir=(path)=>{assert(path==temporary);push(writes,"rmdir");return rmdir(path);};
e.deadline=(argv,seconds,limit)=>{
    assert(seconds==2 && limit==16384);push(commands,argv);return deadline(argv,seconds,limit);
};
let result=require("service.preflight_resources").collect(ARGV[0]);
assert(temporary!=null && fs.lstat(temporary)==null);
print(sprintf("%J\n",{result,reads,commands,writes}));
'''
        result = subprocess.run(['ucode', '-L', str(ROOT / 'loki/files/usr/lib'), '-e', script, str(root)],
                                cwd=ROOT, env=dict(os.environ, PATH='/usr/local/bin:/usr/bin:/bin'),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        value = json.loads(result.stdout)
        self.assertEqual(value['commands'], [QUERY])
        self.assertEqual(value['writes'], ['mkdir', 'unlink', 'rmdir'])
        self.assertEqual(value['reads'], [{'path': str(root).rstrip('/') + '/proc/meminfo', 'mode': 're'}])
        self.assertIn({'kind': 'resources', 'object': 'resource-budget', 'state': 'incomplete',
                       'reason': 'resource-transaction-budget-namespace-unverified'}, value['result'])
        return value['result']

    def test_native_procfs_zero_size_and_system_df_preserve_system_files(self):
        self.assertEqual(Path('/proc/meminfo').stat().st_size, 0)
        value = self.collect('/')
        self.assertEqual([item['reason'] for item in value[:2]],
                         ['resource-memory-snapshot-read-complete', 'resource-filesystem-snapshot-read-complete'])
        self.assertEqual([item['state'] for item in value[:2]], ['checked', 'checked'])

    def test_malformed_fixture_is_not_capacity_and_does_not_disclose_source(self):
        with tempfile.TemporaryDirectory(prefix='loki-resources-native-') as directory:
            root = Path(directory)
            (root / 'proc').mkdir(mode=0o755)
            path = root / 'proc/meminfo'
            body = 'MemTotal: private-canary\n'
            path.write_text(body)
            path.chmod(0o644)
            value = self.collect(root)
            self.assertEqual(value[0]['state'], 'incomplete')
            self.assertEqual(value[0]['reason'], 'resource-memory-data-invalid')
            self.assertNotIn('private-canary', json.dumps(value))
            self.assertEqual(path.read_text(), body)


if __name__ == '__main__':
    unittest.main()
