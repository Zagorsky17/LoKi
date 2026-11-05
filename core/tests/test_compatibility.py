"""Keep baseline rejection checks from treating crashes or other failures as success."""
import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from compatibility import REFERENCE_VERSION, assert_result, historical_controller_configuration, verify_stock_binary


class CompatibilityTests(unittest.TestCase):
    def test_private_controller_is_accepted_only_by_the_reference_core(self):
        assert_result('private-controller', REFERENCE_VERSION, 0, '')
        with self.assertRaises(AssertionError):
            assert_result('private-controller', REFERENCE_VERSION, 1, 'unknown field "external_controller_unix"')
        for version in ('1.12.22', '1.13.21', '1.14.4'):
            assert_result('private-controller', version, 1, 'experimental.clash_api: unknown field "external_controller_unix"')
            for status, message in [(0, ''), (-11, 'crash'), (127, 'missing core'), (1, 'certificate missing')]:
                with self.subTest(version=version, status=status), self.assertRaises(AssertionError):
                    assert_result('private-controller', version, status, message)

    def test_historical_controller_copy_retains_the_other_schema_boundaries(self):
        actual = {'experimental': {'clash_api': {'external_controller_unix': '/tmp/loki/controller.sock',
                                                'secret': 'synthetic'}, 'unified_delay': {'enabled': True}},
                  'providers': {'test': {'type': 'remote'}}}
        before = repr(actual)
        historical = historical_controller_configuration(actual)
        self.assertEqual(historical['experimental']['clash_api'],
                         {'external_controller': '127.0.0.1:9092', 'secret': 'synthetic'})
        self.assertEqual(historical['experimental']['unified_delay'], actual['experimental']['unified_delay'])
        self.assertEqual(historical['providers'], actual['providers'])
        self.assertEqual(repr(actual), before)
        for api in ({}, {'external_controller': '127.0.0.1:9092', 'secret': 'synthetic'},
                    {'external_controller_unix': '/tmp/other.sock', 'secret': 'synthetic'},
                    {**actual['experimental']['clash_api'], 'external_ui': 'unexpected'}):
            with self.subTest(api=api), self.assertRaisesRegex(AssertionError, 'fixed private Unix controller'):
                historical_controller_configuration({'experimental': {'clash_api': api}})

    def test_reference_must_accept_the_configuration(self):
        assert_result('manual-json', REFERENCE_VERSION, 0, '')
        with self.assertRaises(AssertionError):
            assert_result('manual-json', REFERENCE_VERSION, 1, 'unknown field "providers"')

    def test_only_the_characterized_schema_rejection_is_accepted(self):
        assert_result('custom-dns-timeout', '1.12.22', 1, 'dns.timeout: unknown field "timeout"')
        assert_result('manual-json', '1.14.4', 1, 'experimental.unified_delay: unknown field "unified_delay"')
        assert_result('dns-fallback', '1.14.4', 1, 'unknown transport type: fallback')
        for status, message in [(0, ''), (127, 'command missing'), (-11, 'crash'), (1, 'certificate missing'),
                                (1, 'unknown transport type: fallback')]:
            with self.subTest(status=status, message=message), self.assertRaises(AssertionError):
                assert_result('manual-json', '1.14.4', status, message)

    def test_the_limited_native_schema_must_succeed_on_each_characterized_core(self):
        assert_result('manual-json-native', '1.14.4', 0, '')
        assert_result('manual-json-native', '1.12.22', 0, '')
        assert_result('manual-json-native', '1.13.21', 0, '')
        for status, message in [(1, 'unknown field "providers"'), (-11, 'crash'), (127, 'missing core')]:
            with self.subTest(status=status), self.assertRaises(AssertionError):
                assert_result('manual-json-native', '1.14.4', status, message)
        with self.assertRaises(AssertionError):
            assert_result('uncharacterized-profile', '1.14.4', 0, '')

    def test_plain_links_must_succeed_but_complex_links_still_require_the_parser(self):
        for profile in ('share-link', 'http-link', 'https-link'):
            assert_result(profile, '1.14.4', 0, '')
            with self.subTest(profile=profile), self.assertRaises(AssertionError):
                assert_result(profile, '1.14.4', 1, 'unknown outbound type: parser')
        assert_result('complex-link', '1.14.4', 1, 'unknown outbound type: parser')
        with self.assertRaises(AssertionError):
            assert_result('complex-link', '1.14.4', 0, '')

    def test_custom_timeout_is_not_misclassified_as_supported_on_older_cores(self):
        for version in ('1.12.22', '1.13.21'):
            assert_result('custom-dns-timeout', version, 1, 'unknown field "timeout"')
            with self.subTest(version=version), self.assertRaises(AssertionError):
                assert_result('custom-dns-timeout', version, 0, '')
        assert_result('custom-dns-timeout', '1.14.4', 0, '')

    def test_a_new_core_is_not_silently_assumed_to_follow_the_same_schema(self):
        for message in ['unknown field "providers"', 'unknown field "timeout"', 'unknown transport type: fallback']:
            with self.subTest(message=message), self.assertRaises(AssertionError):
                assert_result('manual-json', '1.15.0', 1, message)


class BinaryIntegrityTests(unittest.TestCase):
    def archive(self, directory, symlink=False):
        archive = directory / 'sing-box-1.14.4.tar.gz'
        binary = directory / 'sing-box-1.14.4'
        payload = b'synthetic binary content'
        binary.write_bytes(payload)
        with tarfile.open(archive, 'w:gz') as data:
            member = tarfile.TarInfo('sing-box-1.14.4-linux-amd64/sing-box')
            if symlink:
                member.type = tarfile.SYMTYPE
                member.linkname = '/outside/archive'
                data.addfile(member)
            else:
                member.size = len(payload)
                data.addfile(member, io.BytesIO(payload))
        return binary, archive, {'version': '1.14.4', 'url': 'https://example.invalid/' + archive.name, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}

    def test_digest_is_checked_before_an_archive_can_be_used(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            binary, archive, release = self.archive(directory)
            self.assertEqual(verify_stock_binary(directory, release), binary)
            archive.write_bytes(b'corrupt archive')
            with self.assertRaisesRegex(AssertionError, 'digest mismatch'):
                verify_stock_binary(directory, release)

    def test_a_replaced_binary_or_symlink_cannot_pass_the_archive_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            binary, _, release = self.archive(directory)
            binary.write_bytes(b'changed')
            with self.assertRaisesRegex(AssertionError, 'differs'):
                verify_stock_binary(directory, release)
            binary.unlink()
            other = directory / 'other'
            other.write_bytes(b'synthetic binary content')
            binary.symlink_to(other)
            with self.assertRaisesRegex(AssertionError, 'regular extracted binary'):
                verify_stock_binary(directory, release)

    def test_an_archive_link_is_not_treated_as_an_executable_member(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            _, _, release = self.archive(directory, symlink=True)
            with self.assertRaisesRegex(AssertionError, 'not a regular file'):
                verify_stock_binary(directory, release)


if __name__ == '__main__':
    unittest.main()
