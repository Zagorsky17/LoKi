"""Read real policy rules and routes in an anonymous namespace as an ordinary user."""
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
PARENT_NS = 'LOKI_RULE_TEST_PARENT_NS'
QUERY4 = ['/usr/bin/env', '-i', 'PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'LC_ALL=C',
          '/sbin/ip', '-Numeric', '-j', '-4', 'rule', 'list']
QUERY6 = [word if word != '-4' else '-6' for word in QUERY4]
ROUTE_QUERY4 = QUERY4[:-2] + ['route', 'show', 'table', 'all']
ROUTE_QUERY6 = QUERY6[:-2] + ['route', 'show', 'table', 'all']


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
    for args in [
        ['link', 'set', 'lo', 'up'],
        ['-4', 'address', 'add', '192.0.2.1/24', 'dev', 'lo'],
        ['-6', 'address', 'add', '2001:db8::1/64', 'dev', 'lo', 'nodad'],
        ['-4', 'route', 'replace', '192.0.2.0/24', 'dev', 'lo'],
        ['-6', 'route', 'replace', '2001:db8::/64', 'dev', 'lo'],
        ['-4', 'route', 'add', 'local', 'default', 'dev', 'lo', 'table', '105'],
        ['-6', 'route', 'add', 'local', 'default', 'dev', 'lo', 'table', '105'],
        ['-4', 'route', 'add', 'blackhole', '198.51.100.0/24', 'table', '200'],
    ]:
        subprocess.run(['/sbin/ip', *args], check=True, timeout=5)
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

    def synthetic_pipe(self, mode, routes=False):
        writer = self.root / 'writer.py'
        writer.write_text('''import sys,time
mode=sys.argv[1]
if mode=='slow':time.sleep(8)
elif mode=='error':sys.stdout.write('[]');sys.exit(7)
elif mode=='private':sys.stdout.write('[] SYNTHETIC_PRIVATE_CANARY')
else:sys.stdout.write('[]'+' '*(262144-2+(mode=='extra')))
''')
        writer.chmod(0o600)
        command = ['/usr/bin/env', '-i', 'PATH=/usr/local/bin:/usr/bin:/bin', 'LC_ALL=C',
                   sys.executable, '-B', str(writer), mode]
        program = '''let e=require("core.exec"),deadline=e.deadline;let allowed=json(ARGV[0]);
            e.deadline=(argv,seconds,limit)=>{
                assert(length(filter(allowed,(value)=>sprintf("%J",value)==sprintf("%J",argv)))==1);
                assert(seconds==2 && limit==262144);
                return deadline(json(ARGV[1]),seconds,limit);
            };print(sprintf("%J",p.METHOD()));'''
        return self.run_ucode(program.replace('METHOD', 'collect_routes' if routes else 'collect'),
                              json.dumps([ROUTE_QUERY4, ROUTE_QUERY6] if routes else [QUERY4, QUERY6]), json.dumps(command))

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


class RouteProbe(RuleHarness):
    def test_real_route_snapshots_preserve_tables_and_do_not_mutate_the_namespace(self):
        commands = [['/sbin/ip', '-Numeric', '-j', family, 'route', 'show', 'table', 'all'] for family in ['-4', '-6']]
        before = [subprocess.check_output(command, text=True, timeout=5) for command in commands]
        result = self.run_ucode('print(sprintf("%J",p.collect_routes()));')
        self.assertEqual(sum(row['reason'] == 'policy-route-snapshot-read-complete' for row in result), 2)
        for name in ['ipv4-candidate-table', 'ipv6-candidate-table']:
            self.assertTrue(any(row['object'] == name and row['reason'] == 'policy-route-candidate-table-unverified' for row in result))
        self.assertIn('policy-routes-ownership-configuration-unverified', self.reasons(result))
        self.assertFalse(any(row['state'] == 'conflict' for row in result))
        try:
            init_namespace = os.readlink('/proc/1/ns/net')
        except OSError:
            expected = 'policy-route-namespace-unavailable'
        else:
            expected = ('policy-route-network-namespace-checked' if init_namespace == os.readlink('/proc/self/ns/net')
                        else 'policy-route-noninitial-network-namespace')
        self.assertTrue(any(row['object'] == 'network-namespace' and row['reason'] == expected for row in result))
        self.assertNotIn('net:[', json.dumps(result))
        self.assertNotIn('192.0.2', json.dumps(result))
        self.assertNotIn('2001:db8', json.dumps(result))
        self.assertEqual([subprocess.check_output(command, text=True, timeout=5) for command in commands], before)

    def test_native_numeric_types_and_implicit_main_table_survive_parsing(self):
        for family, number in [('-4', 4), ('-6', 6)]:
            native = subprocess.check_output(['/sbin/ip', '-Numeric', '-j', family, 'route', 'show', 'table', 'all'], text=True, timeout=5)
            parsed = self.run_ucode('let r=p.parse_routes(ARGV[0],int(ARGV[1]));if(r.error)die(r.error);print(sprintf("%J",r.routes));', native, number)
            self.assertTrue(any(row['table'] == 105 and row['type'] == 2 for row in parsed))
            self.assertTrue(any(row['table'] == 254 and row['type'] == 1 for row in parsed))
            if number == 4:
                self.assertTrue(any(row['table'] == 200 and row['type'] == 6 for row in parsed))

    def test_real_route_pipe_checks_the_exact_byte_boundary(self):
        result = self.synthetic_pipe('edge', routes=True)
        self.assertEqual(sum(row['reason'] == 'policy-route-snapshot-read-complete' for row in result), 2)
        result = self.synthetic_pipe('extra', routes=True)
        self.assertIn('policy-route-response-size-limit', self.reasons(result))
        self.assertNotIn('policy-route-snapshot-read-complete', self.reasons(result))

    def test_real_bad_route_data_and_nonzero_close_are_private_failures(self):
        for mode, reason in [('error', 'policy-route-query-failed'), ('private', 'policy-route-json-invalid')]:
            result = self.synthetic_pipe(mode, routes=True)
            self.assertIn(reason, self.reasons(result))
            self.assertNotIn('policy-route-snapshot-read-complete', self.reasons(result))
            self.assertNotIn('SYNTHETIC_PRIVATE_CANARY', json.dumps(result))

    def test_actual_route_probe_timeout_is_bounded(self):
        started = time.monotonic()
        result = self.synthetic_pipe('slow', routes=True)
        self.assertLess(time.monotonic() - started, 12)
        self.assertIn('policy-route-query-failed', self.reasons(result, 'ipv4'))
        self.assertIn('policy-route-query-failed', self.reasons(result, 'ipv6'))


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
    unittest.main(defaultTest=['RuleProbe', 'RouteProbe'])
