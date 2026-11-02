"""Keep the real deadline test strict about failures and supported versions."""
import unittest

from dns_timeout import assert_check, assert_outcome


class DeadlineGuards(unittest.TestCase):
    def test_only_the_characterized_schema_refusal_is_accepted(self):
        self.assertFalse(assert_check('1.12.22', '400ms', 1, 'dns: unknown field "timeout"'))
        for status, message in [(0, ''), (-11, 'crash'), (1, 'other error'), (127, 'missing binary')]:
            with self.subTest(status=status), self.assertRaises(AssertionError):
                assert_check('1.13.21', '12s', status, message)
        self.assertTrue(assert_check('1.14.4', '12s', 0, ''))

    def test_an_unexpected_answer_timeout_or_early_close_fails(self):
        for outcome, elapsed in [('answer', 10), ('deadline', .1), ('deadline', 14)]:
            with self.subTest(outcome=outcome, elapsed=elapsed), self.assertRaises(AssertionError):
                assert_outcome(outcome, elapsed, 'deadline', 9.4, 12, 'silent.test: context deadline exceeded')
        with self.assertRaises(AssertionError):
            assert_outcome('deadline', 11, 'answer', 10.7, 13.4, '')

    def test_closure_without_a_core_dns_deadline_is_not_success(self):
        for log in ['', 'silent.test: unexpected error', 'other.test: context deadline exceeded',
                    'silent.test: request\nkeepalive.test: context deadline exceeded']:
            with self.subTest(log=log), self.assertRaises(AssertionError):
                assert_outcome('deadline', 10, 'deadline', 9.4, 12, log)
        assert_outcome('deadline', 10, 'deadline', 9.4, 12, 'silent.test: context deadline exceeded')

    def test_only_the_pinned_stock_async_core_can_close_without_a_diagnostic(self):
        assert_outcome('deadline', 10, 'deadline', 9.4, 12, '', '1.14.4')
        with self.assertRaises(AssertionError):
            assert_outcome('deadline', 10, 'deadline', 9.4, 12, 'ERROR unrelated failure', '1.14.4')
        with self.assertRaises(AssertionError):
            assert_outcome('deadline', 10, 'deadline', 9.4, 12, '', '1.15.0')


if __name__ == '__main__':
    unittest.main()
