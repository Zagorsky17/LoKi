"""Deterministic readiness failures without running a core or external endpoint."""
import contextlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import subscription_selection as selection

READY = {'all': ['main/One/A', 'main/One/B', 'main/Two/A', 'main/Two/B']}


@contextlib.contextmanager
def harness(responses, clock=None):
    with tempfile.TemporaryDirectory(prefix='loki-readiness-') as scratch:
        runtime = selection.Runtime.__new__(selection.Runtime)
        runtime.core = Path('/not-executed/synthetic-core')
        runtime.directory = Path(scratch)
        runtime.path = runtime.directory / 'runtime.json'
        runtime.runs = 0
        runtime.group = Mock(side_effect=responses)
        process = Mock()
        process.poll.return_value = None
        process.wait.return_value = 0
        with patch.object(selection.subprocess, 'Popen', return_value=process) as start, \
                patch.object(selection.time, 'monotonic', side_effect=clock or range(100)), \
                patch.object(selection.time, 'sleep') as sleep:
            yield runtime, process, start, sleep


class ReadinessTest(unittest.TestCase):
    def test_null_empty_and_absent_members_wait_for_complete_provider_list(self):
        with harness([{'all': None}, {'all': []}, {}, READY]) as (runtime, process, start, sleep):
            with runtime.running() as running:
                self.assertIs(running, process)
                self.assertEqual(runtime.group.call_count, 4)
            start.assert_called_once()
            self.assertEqual(sleep.call_count, 3)
            process.terminate.assert_called_once()
            process.wait.assert_called_once_with(timeout=5)
            process.kill.assert_not_called()

    def test_bad_shapes_never_count_as_ready_and_preserve_the_deadline(self):
        for value in [None, [], 'invalid', {}, {'all': '1234'}, {'all': {}},
                      {'all': [1, 2, 3, 4]}, {'all': ['', 'b', 'c', 'd']},
                      {'all': ['a', 'b', 'c']}, {'all': ['a', 'b', 'c', 'd', 'e']}]:
            with self.subTest(response=value), harness([value], [0, 9]) as (runtime, process, _, sleep):
                with self.assertRaisesRegex(AssertionError, 'provider startup exceeded its deadline'):
                    with runtime.running():
                        self.fail('invalid provider list reached readiness')
                process.terminate.assert_called_once()
                process.wait.assert_called_once_with(timeout=5)
                sleep.assert_not_called()

    def test_transient_transport_json_and_missing_key_errors_still_retry(self):
        with harness([OSError('synthetic socket error'), ValueError('synthetic JSON error'),
                      KeyError('all'), READY]) as (runtime, process, _, sleep):
            with runtime.running():
                self.assertEqual(runtime.group.call_count, 4)
            self.assertEqual(sleep.call_count, 3)
            process.terminate.assert_called_once()

    def test_unrelated_type_error_is_not_hidden_by_readiness_retry(self):
        with harness([TypeError('synthetic programming fault')]) as (runtime, process, _, sleep):
            with self.assertRaisesRegex(TypeError, 'synthetic programming fault'):
                with runtime.running():
                    self.fail('programming failure reached readiness')
            runtime.group.assert_called_once()
            sleep.assert_not_called()
            process.terminate.assert_called_once()

    def test_exited_core_fails_before_api_readiness(self):
        with harness([READY]) as (runtime, process, _, _):
            process.poll.return_value = 7
            with self.assertRaisesRegex(AssertionError, 'core exited before local API readiness'):
                with runtime.running():
                    self.fail('exited core reached readiness')
            runtime.group.assert_not_called()
            process.terminate.assert_called_once()

    def test_deadline_cleanup_kills_a_process_that_ignores_termination(self):
        with harness([{'all': None}], [0, 9]) as (runtime, process, _, _):
            process.wait.side_effect = [subprocess.TimeoutExpired('synthetic-core', 5), 0]
            with self.assertRaisesRegex(AssertionError, 'provider startup exceeded its deadline'):
                with runtime.running():
                    self.fail('empty providers reached readiness')
            process.terminate.assert_called_once()
            process.kill.assert_called_once()
            self.assertEqual(process.wait.call_count, 2)
            for call in process.wait.call_args_list:
                self.assertEqual(call.kwargs, {'timeout': 5})


if __name__ == '__main__':
    unittest.main()
