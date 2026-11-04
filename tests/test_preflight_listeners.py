"""Check socket discovery against real Linux procfs and isolated bounded fixtures."""
import contextlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TABLES = ('tcp', 'tcp6', 'udp', 'udp6')
LIMIT = 262144


def header(name):
    return ('sl local_address ' + ('remote_address' if name.endswith('6') else 'rem_address') +
            ' st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode' +
            (' ref pointer drops' if name.startswith('udp') else '') + '\n')


class ListenerProbe(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix='loki-sockets-')
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.root.chmod(0o755)
        directory = self.root
        for name in ('proc', 'self', 'net'):
            directory /= name
            directory.mkdir(mode=0o755)
        for name in TABLES:
            self.write(name, header(name))

    def write(self, name, value):
        path = self.root / 'proc/self/net' / name
        path.write_text(value)
        path.chmod(0o644)

    def run_ucode(self, program, *args):
        done = subprocess.run(['ucode', '-L', str(ROOT / 'forkop/files/usr/lib'), '-e',
                               'let fs=require("fs");let p=require("service.preflight_listeners");' + program,
                               *map(str, args)], capture_output=True, text=True, timeout=10)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stderr, '')
        return json.loads(done.stdout)

    def collect(self):
        return self.run_ucode('print(sprintf("%J",p.collect(ARGV[0])));', self.root)

    def reasons(self, result, name=None):
        return {x['reason'] for x in result if name is None or x['object'] == name}

    def test_real_procfs_distinguishes_own_tcp_listeners_and_connected_udp(self):
        with contextlib.ExitStack() as stack:
            expected, excluded = {}, set()
            for family, address, suffix in ((socket.AF_INET, '127.0.0.1', ''), (socket.AF_INET6, '::1', '6')):
                for kind, name in ((socket.SOCK_STREAM, 'tcp'), (socket.SOCK_DGRAM, 'udp')):
                    peer = stack.enter_context(socket.socket(family, kind))
                    if family == socket.AF_INET6:
                        peer.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                    peer.bind((address, 0))
                    if kind == socket.SOCK_STREAM:
                        peer.listen(1)
                        client = stack.enter_context(socket.socket(family, kind))
                        client.settimeout(2)
                        client.connect(peer.getsockname())
                        accepted, _ = peer.accept()
                        stack.enter_context(accepted)
                        excluded.update(str(os.fstat(s.fileno()).st_ino) for s in (client, accepted))
                    else:
                        peer.connect((address, peer.getsockname()[1]))
                    inode = str(os.fstat(peer.fileno()).st_ino)
                    expected[inode] = {'table': name + suffix, 'port': peer.getsockname()[1],
                                       'state': 10 if kind == socket.SOCK_STREAM else 1}
            result = self.run_ucode('''let own=json(ARGV[0]);let out={};
                for(let name in ["tcp","tcp6","udp","udp6"]){
                    let file=fs.open("/proc/self/net/"+name,"re");let data=file.read(262145);file.close();
                    let parsed=p.parse(data,name);if(parsed.error)die(parsed.error);
                    for(let item in parsed.bindings)if(own[item.inode])
                        out[item.inode]={table:name,port:item.port,state:item.state};
                }print(sprintf("%J",out));''', json.dumps({key: True for key in expected.keys() | excluded}))
            self.assertEqual(result, expected)
            collected = self.run_ucode('print(sprintf("%J",p.collect("/")));')
            self.assertEqual(sum(x['reason'] == 'listener-table-read-complete' for x in collected), 4)
            self.assertIn('listener-process-ownership-unverified', self.reasons(collected))

    def test_actual_stream_byte_limit_includes_lookahead(self):
        line = '0: 00000000:9C40 00000000:0000 06 00000000:00000000 00:00000000 00000000 0 0 0 1 0000000000000000'
        body = header('tcp').rstrip('\n').ljust(127) + '\n' + (line.ljust(127) + '\n') * 2047
        self.assertEqual(len(body.encode()), LIMIT)
        self.write('tcp', body)
        self.assertIn('listener-table-read-complete', self.reasons(self.collect(), 'ipv4-tcp'))
        self.write('tcp', body + ' ')
        result = self.collect()
        self.assertIn('listener-table-size-limit', self.reasons(result, 'ipv4-tcp'))
        self.assertNotIn('listener-table-read-complete', self.reasons(result, 'ipv4-tcp'))

    def test_missing_ipv6_and_malformed_rows_do_not_claim_coverage(self):
        (self.root / 'proc/self/net/tcp6').unlink()
        self.write('udp6', header('udp6') + 'synthetic-private-row\n')
        result = self.collect()
        self.assertIn('listener-table-path-unavailable', self.reasons(result, 'ipv6-tcp'))
        self.assertIn('listener-table-row-invalid', self.reasons(result, 'ipv6-udp'))
        self.assertNotIn('synthetic-private-row', json.dumps(result))

    def test_links_writable_parents_and_fifo_are_refused_without_opening_them(self):
        path = self.root / 'proc/self/net/tcp'
        path.unlink()
        path.symlink_to('udp')
        self.assertIn('listener-table-path-unavailable', self.reasons(self.collect(), 'ipv4-tcp'))
        path.unlink()
        os.mkfifo(path)
        self.assertIn('listener-table-path-unavailable', self.reasons(self.collect(), 'ipv4-tcp'))
        path.unlink()
        self.write('tcp', header('tcp'))
        (self.root / 'proc/self').chmod(0o777)
        result = self.collect()
        self.assertFalse(any(x['reason'] == 'listener-table-read-complete' for x in result))

    def test_repeat_reads_are_unchanged_and_never_spawn_a_command(self):
        before = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        result = self.run_ucode('''fs.popen=()=>die("unexpected process");
            global.system=()=>die("unexpected process");
            let first=p.collect(ARGV[0]);let second=p.collect(ARGV[0]);
            print(sprintf("%J",{first,second}));''', self.root)
        after = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(result['first'], result['second'])
        self.assertEqual(before, after)
        self.assertIn('listener-namespace-and-bind-configuration-unverified', self.reasons(result['first']))


if __name__ == '__main__':
    if sys.platform != 'linux':
        raise SystemExit('Run on Linux; procfs coverage is required')
    unittest.main()
