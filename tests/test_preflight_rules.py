"""Read real policy rules in an anonymous test namespace, as an ordinary user."""
import json
import os
from pathlib import Path
import pwd
import re
import shlex
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
PARENT_NS = 'LOKI_RULE_TEST_PARENT_NS'
QUERY4 = ('exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C '
          'timeout -s KILL 2 /sbin/ip -Numeric -j -4 rule list 2>/dev/null')
QUERY6 = QUERY4.replace('-j -4', '-j -6')


def prepare_namespace(parent, user):
    if (os.geteuid() != 0 or not re.fullmatch(r'net:\[[0-9]+\]', parent) or
            os.readlink('/proc/self/ns/net') == parent or
            os.readlink(f'/proc/{os.getppid()}/ns/net') != parent or pwd.getpwnam(user).pw_uid == 0):
        raise SystemExit('Require a fresh unshare --net child and an ordinary test account')
    fixtures = [
        ['-4', 'priority', '105', 'fwmark', '0x04000000/0x04000000', 'table', '105'],
        ['-4', 'priority', '105', 'fwmark', '0x00100000/0x00100000', 'table', '105'],
        ['-4', 'priority', '104', 'fwmark', '0x04000000/0x04000000', 'iif', 'lo', 'table', '254'],
        ['-4', 'priority', '107', 'fwmark', '0xffffffff/0', 'table', '254'],
        ['-6', 'priority', '105', 'fwmark', '0x10000000/0x10000000', 'table', '105'],
        ['-6', 'priority', '106', 'fwmark', '0x08000000/0x08000000', 'oif', 'lo', 'table', '254'],
        ['-6', 'priority', '109', 'fwmark', '0x80000000', 'table', '105'],
    ]
    for family, *args in fixtures:
        subprocess.run(['/sbin/ip', family, 'rule', 'add', *args], check=True, timeout=5)
    worker = ['/usr/sbin/runuser', '-u', user, '--', '/usr/bin/env',
              'PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', PARENT_NS + '=' + parent,
              sys.executable, '-B', str(Path(__file__).resolve())]
    first = subprocess.run(worker, cwd=ROOT, timeout=90)
    if first.returncode:
        return first.returncode
    subprocess.run(['/sbin/ip', '-4', 'rule', 'add', 'priority', '110',
                    'from', '192.0.2.0/24', 'table', '105'], check=True, timeout=5)
    return subprocess.run([*worker, 'UnsupportedProbe'], cwd=ROOT, timeout=30).returncode


class RuleHarness(unittest.TestCase):
    def setUp(self):
        self.assertNotEqual(os.geteuid(), 0, 'Product tests run as the ordinary test account')
        self.assertRegex(os.environ.get(PARENT_NS, ''), r'^net:\[[0-9]+\]$')
        self.assertNotEqual(os.readlink('/proc/self/ns/net'), os.environ[PARENT_NS])
        self.work = tempfile.TemporaryDirectory(prefix='loki-policy-rules-')
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)

    def run_ucode(self, program, *args):
        done = subprocess.run(['ucode', '-L', str(ROOT / 'loki/files/usr/lib'), '-e',
                               'let fs=require("fs");let p=require("service.preflight_rules");' + program,
                               *map(str, args)], capture_output=True, text=True, timeout=15)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stderr, '')
        return json.loads(done.stdout)

    @staticmethod
    def reasons(result, family=None):
        return {x['reason'] for x in result if family is None or x['object'] == family}

    def synthetic_pipe(self, mode):
        writer = self.root / 'writer.py'
        writer.write_text('''import sys,time
mode=sys.argv[1]
if mode=='slow':time.sleep(8)
elif mode=='error':sys.stdout.write('[]');sys.exit(7)
elif mode=='private':sys.stdout.write('[] SYNTHETIC_PRIVATE_CANARY')
else:sys.stdout.write('[]'+' '*(262144-2+(mode=='extra')))
''')
        writer.chmod(0o600)
        command = shlex.join(['/usr/bin/env', '-i', 'PATH=/usr/local/bin:/usr/bin:/bin',
                              'timeout', '-s', 'KILL', '2', sys.executable, '-B', str(writer), mode])
        return self.run_ucode('''let open=fs.popen;let allowed=json(ARGV[0]);
            fs.popen=(command,mode)=>{if(index(allowed,command)<0)die("unexpected query");
                return open("exec "+ARGV[1],mode);};print(sprintf("%J",p.collect()));''',
                              json.dumps([QUERY4, QUERY6]), command)

class RuleProbe(RuleHarness):
    def test_real_two_family_snapshots_keep_hints_and_mandatory_gaps(self):
        result = self.run_ucode('print(sprintf("%J",p.collect()));')
        self.assertEqual(sum(x['reason'] == 'policy-rule-snapshot-read-complete' for x in result), 2)
        for name in ('ipv4-candidate-table', 'ipv6-candidate-table', 'ipv4-fakeip-match-space',
                     'ipv6-router-match-space', 'ipv6-outbound-mask-bits'):
            self.assertTrue(any(x['object'] == name and x['reason'] ==
                                'policy-rule-candidate-overlap-unverified' for x in result), name)
        self.assertIn('policy-rules-ownership-configuration-unverified', self.reasons(result))
        self.assertIn('policy-routes-and-namespace-unverified', self.reasons(result))
        self.assertFalse(any(x['state'] == 'conflict' for x in result))
        self.assertNotIn('lo', {x.get('object') for x in result})

    def test_native_zero_mask_high_bit_and_equal_priorities_survive_parsing(self):
        for family, priority, expected in (('-4', 107, (4294967295, 0)),
                                           ('-6', 109, (2147483648, 4294967295))):
            native = subprocess.check_output(['/sbin/ip', '-Numeric', '-j', family, 'rule', 'list'],
                                             text=True, timeout=5)
            parsed = self.run_ucode('let r=p.parse(ARGV[0]);if(r.error)die(r.error);'
                                    'print(sprintf("%J",r.rules));', native)
            row = next(x for x in parsed if x['priority'] == priority)
            self.assertEqual((row['mark'], row['mask']), expected)
            self.assertGreaterEqual(sum(x['priority'] == 105 for x in parsed), 1)

    def test_real_pipe_accepts_exact_byte_limit_and_refuses_lookahead_byte(self):
        exact = self.synthetic_pipe('edge')
        self.assertEqual(sum(x['reason'] == 'policy-rule-snapshot-read-complete' for x in exact), 2)
        excessive = self.synthetic_pipe('extra')
        self.assertIn('policy-rule-response-size-limit', self.reasons(excessive))
        self.assertNotIn('policy-rule-snapshot-read-complete', self.reasons(excessive))

    def test_real_nonzero_status_and_bad_data_never_become_empty_rule_sets(self):
        for mode, reason in (('error', 'policy-rule-query-failed'), ('private', 'policy-rule-json-invalid')):
            result = self.synthetic_pipe(mode)
            self.assertIn(reason, self.reasons(result))
            self.assertNotIn('policy-rule-snapshot-read-complete', self.reasons(result))
            self.assertNotIn('SYNTHETIC_PRIVATE_CANARY', json.dumps(result))

    def test_actual_timeout_ends_our_own_probe_processes(self):
        started = time.monotonic()
        result = self.synthetic_pipe('slow')
        self.assertLess(time.monotonic() - started, 12)
        self.assertIn('policy-rule-query-failed', self.reasons(result, 'ipv4'))
        self.assertIn('policy-rule-query-failed', self.reasons(result, 'ipv6'))


class UnsupportedProbe(RuleHarness):
    def test_real_source_specific_rule_stays_incomplete(self):
        result = self.run_ucode('print(sprintf("%J",p.collect()));')
        self.assertIn('policy-rule-selector-or-action-unverified', self.reasons(result, 'ipv4'))
        self.assertNotIn('policy-rule-snapshot-read-complete', self.reasons(result, 'ipv4'))
        self.assertIn('policy-rule-snapshot-read-complete', self.reasons(result, 'ipv6'))
        self.assertNotIn('192.0.2', json.dumps(result))


if __name__ == '__main__':
    if sys.platform != 'linux':
        raise SystemExit('Run on Linux inside the controlled test namespace')
    if len(sys.argv) == 4 and sys.argv[1] == '--prepare':
        raise SystemExit(prepare_namespace(sys.argv[2], sys.argv[3]))
    unittest.main(defaultTest='RuleProbe')
