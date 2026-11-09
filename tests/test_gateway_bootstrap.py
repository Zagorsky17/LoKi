#!/usr/bin/env python3
"""Exercise separate gateway startup and its owned children without a router or network."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / 'loki/files/usr/libexec/loki-gateway'
INIT = ROOT / 'loki/files/etc/init.d/loki-state'


class GatewayBootstrap(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.environment = dict(os.environ, TEST_GATEWAY_DIR=str(self.directory), TEST_GATEWAY_MODE='ready')
        self.helper = self.directory / 'ucode'
        self.helper.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$TEST_GATEWAY_DIR/arguments"
if [ "$TEST_GATEWAY_MODE" = preparing ]; then
    printf '%s' "$$" > "$TEST_GATEWAY_DIR/helper.pid"
    exec /bin/sleep 30
fi
count=0
[ ! -e "$TEST_GATEWAY_DIR/count" ] || count=$(cat "$TEST_GATEWAY_DIR/count")
count=$((count+1)); printf '%s' "$count" > "$TEST_GATEWAY_DIR/count"
[ "$TEST_GATEWAY_MODE" = ready ] || [ "$count" -ge 3 ]
''')
        self.core = self.directory / 'core'
        self.core.write_text('''#!/bin/sh
printf '%s' "$$" > "$TEST_GATEWAY_DIR/core.pid"
printf '%s\\n' "$*" > "$TEST_GATEWAY_DIR/core.args"
''')
        self.sleeper = self.directory / 'sleep'
        self.sleeper.write_text('''#!/bin/sh
printf '%s' "$$" > "$TEST_GATEWAY_DIR/sleep.pid"
if [ "$TEST_GATEWAY_MODE" = sleeping ]; then exec /bin/sleep 30; fi
exec /bin/sleep 0.02
''')
        text = BOOTSTRAP.read_text()
        for before, after in [('/usr/bin/ucode', str(self.helper)), ('/usr/bin/loki-core', str(self.core)), ('/bin/sleep 30', str(self.sleeper) + ' 30')]:
            self.assertEqual(text.count(before), 1)
            text = text.replace(before, after)
        self.script = self.directory / 'bootstrap'
        self.script.write_text(text)
        for path in [self.helper, self.core, self.sleeper, self.script]:
            path.chmod(0o700)

    def start(self, mode, *arguments):
        self.environment['TEST_GATEWAY_MODE'] = mode
        process = subprocess.Popen(['/bin/busybox', 'ash', str(self.script), *arguments], env=self.environment, start_new_session=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop, process)
        return process

    @staticmethod
    def stop(process):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=3)

    def wait_pid(self, name):
        path = self.directory / name
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if path.exists() and path.read_text():
                return int(path.read_text())
            time.sleep(0.01)
        self.fail('owned child did not start')

    def test_a_ready_gateway_replaces_bootstrap_without_launching_routing(self):
        process = self.start('ready')
        output, error = process.communicate(timeout=3)
        self.assertEqual((process.returncode, output, error), (0, '', ''))
        self.assertEqual(self.wait_pid('core.pid'), process.pid)
        self.assertEqual((self.directory / 'core.args').read_text(), 'gateway\n')
        self.assertEqual((self.directory / 'count').read_text(), '1')
        self.assertIn('-L /usr/lib/loki -e', (self.directory / 'arguments').read_text())
        self.assertIn('require("service.gateway").prepare()', (self.directory / 'arguments').read_text())

    def test_delayed_lan_or_tls_preparation_retries_then_executes_once(self):
        process = self.start('delayed')
        process.communicate(timeout=3)
        self.assertEqual(process.returncode, 0)
        self.assertEqual((self.directory / 'count').read_text(), '3')
        self.assertEqual(self.wait_pid('core.pid'), process.pid)

    def test_stop_during_preparation_or_delay_leaves_no_owned_child_or_late_listener(self):
        for mode, filename in [('preparing', 'helper.pid'), ('sleeping', 'sleep.pid')]:
            with self.subTest(mode=mode):
                process = self.start(mode)
                pid = self.wait_pid(filename)
                process.send_signal(signal.SIGTERM)
                output, error = process.communicate(timeout=3)
                self.assertEqual((process.returncode, output, error), (0, '', ''))
                deadline = time.monotonic() + 1
                while Path('/proc', str(pid)).exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertFalse(Path('/proc', str(pid)).exists(), 'bootstrap must reap its stopped child')
                self.assertFalse((self.directory / 'core.pid').exists())
                (self.directory / filename).unlink()

    def test_stop_reaps_owned_preparation_and_delay_even_when_term_is_ignored(self):
        for mode, filename, helper in [('preparing', 'helper.pid', self.helper), ('sleeping', 'sleep.pid', self.sleeper)]:
            with self.subTest(mode=mode):
                original = helper.read_text()
                helper.write_text('#!/bin/sh\ntrap "" TERM\nprintf "%s" "$$" > "$TEST_GATEWAY_DIR/' + filename + '"\nexec /bin/sleep 30\n')
                process = self.start(mode)
                try:
                    pid = self.wait_pid(filename)
                    process.send_signal(signal.SIGTERM)
                    try:
                        output, error = process.communicate(timeout=1)
                    except subprocess.TimeoutExpired:
                        self.fail('stop left a TERM-resistant owned child running')
                    self.assertEqual((process.returncode, output, error), (0, '', ''))
                    self.assertFalse(Path('/proc', str(pid)).exists(), 'stopped preparation must be reaped')
                    self.assertFalse((self.directory / 'core.pid').exists())
                finally:
                    self.stop(process)
                    helper.write_text(original)

    def test_unexpected_arguments_never_start_preparation(self):
        process = self.start('ready', '--listen=0.0.0.0:9091')
        process.communicate(timeout=3)
        self.assertEqual(process.returncode, 2)
        self.assertFalse((self.directory / 'count').exists())

    def test_stop_between_fork_and_child_recording_still_cancels_the_owned_child(self):
        text = self.script.read_text()
        anchor = '    child=$!\n'
        self.assertEqual(text.count(anchor), 2)
        for index, mode in [(0, 'preparing'), (1, 'sleeping')]:
            with self.subTest(mode=mode):
                parts = text.split(anchor)
                parts[index] += '    printf "%s" "$!" > "$TEST_GATEWAY_DIR/race.pid"\n    kill -TERM "$$"\n'
                self.script.write_text(anchor.join(parts))
                process = self.start(mode)
                try:
                    output, error = process.communicate(timeout=1)
                except subprocess.TimeoutExpired:
                    self.fail('stop between fork and child recording left preparation running')
                self.assertEqual((process.returncode, output, error), (0, '', ''))
                self.assertFalse(Path('/proc', str(self.wait_pid('race.pid'))).exists())



class GatewayInit(unittest.TestCase):
    def hooks(self, action, view=True, helper=True, state=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, present in [('view', view), ('helper', helper), ('state', state)]:
                if present:
                    (root / name).touch(mode=0o700)
            environment = dict(os.environ, TEST_INIT=str(INIT), TEST_ROOT=str(root))
            script = '''. "$TEST_INIT"
LOKI_STATE_SERVICE_UC="$TEST_ROOT/state"
LOKI_LUCI_VIEW="$TEST_ROOT/view"
LOKI_GATEWAY="$TEST_ROOT/helper"
resolved_library() { printf '/usr/lib/loki\\n'; }
procd_open_instance() { printf 'open:%s\\n' "$1"; }
procd_set_param() { printf 'param'; printf ' <%s>' "$@"; printf '\\n'; }
procd_close_instance() { printf 'close\\n'; }
procd_send_signal() { printf 'signal'; printf ' <%s>' "$@"; printf '\\n'; }
procd_add_reload_trigger() { printf 'config'; printf ' <%s>' "$@"; printf '\\n'; }
procd_add_reload_interface_trigger() { printf 'interface'; printf ' <%s>' "$@"; printf '\\n'; }
'''
            result = subprocess.run(['/bin/busybox', 'ash', '-c', script + action], env=environment,
                                    capture_output=True, text=True, timeout=3)
            self.assertEqual(result.stderr, '')
            return result.returncode, result.stdout, root

    def test_gateway_and_resident_have_separate_supervised_instances(self):
        code, output, root = self.hooks('start_service')
        self.assertEqual(code, 0)
        self.assertEqual(output.count('open:'), 2)
        state, gateway = output.split('open:gateway\n')
        self.assertIn('<command> <ucode> <-L> </usr/lib/loki> </usr/lib/loki/service/state_service.uc> <run>', state)
        self.assertIn('<command> <' + str(root / 'helper') + '>', gateway)
        self.assertIn('<respawn> <3600> <5> <0>', gateway)
        self.assertIn('<term_timeout> <10>', gateway)
        self.assertNotIn('prepare', output)

    def test_partial_or_absent_luci_installation_cannot_launch_a_listener(self):
        for options, code in [({'view': False}, 0), ({'helper': False}, 1), ({'state': False}, 1)]:
            with self.subTest(options=options):
                actual, output, _ = self.hooks('start_service', **options)
                self.assertEqual((actual, output), (code, ''))

    def test_reload_only_signals_the_gateway_and_triggers_cover_own_inputs(self):
        code, output, _ = self.hooks('reload_service; service_triggers')
        self.assertEqual(code, 0)
        self.assertEqual(output, 'signal <loki-state> <gateway> <TERM>\nconfig <loki> <uhttpd> <system> <dhcp>\ninterface <lan>\n')


if __name__ == '__main__':
    unittest.main()
