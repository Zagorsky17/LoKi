"""Exercise the real Bash SDK helper with isolated files and local HTTPS only."""
import hashlib
import http.server
import io
import os
from pathlib import Path
import ssl
import subprocess
import tarfile
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]
BODY = b'synthetic SDK archive\n'
SHA = hashlib.sha256(BODY).hexdigest()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests.append(self.path)
        body = BODY
        if self.path in ('/downgrade', '/redirect'):
            self.send_response(302)
            target = self.server.http_url if self.path == '/downgrade' else self.server.https_url
            self.send_header('Location', target + '/valid')
            self.end_headers()
            return
        self.send_response(404 if self.path == '/404' else 200)
        if self.path == '/wrong':
            body = b'X' * len(BODY)
        elif self.path == '/short':
            body = BODY[:-1]
        elif self.path == '/large':
            body = BODY * 100
        if self.path not in ('/large', '/short'):
            self.send_header('Content-Length', str(len(body) + (1 if self.path == '/truncated' else 0)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class SDKDownloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tls_dir = tempfile.TemporaryDirectory()
        cls.cert = Path(cls.tls_dir.name) / 'cert.pem'
        key = Path(cls.tls_dir.name) / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-days', '1', '-subj', '/CN=localhost', '-addext',
                        'subjectAltName=IP:127.0.0.1,DNS:localhost', '-keyout', str(key),
                        '-out', str(cls.cert)], check=True, capture_output=True)
        cls.servers = [http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler) for _ in range(2)]
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cls.cert, key)
        cls.servers[0].socket = context.wrap_socket(cls.servers[0].socket, server_side=True)
        cls.url = 'https://127.0.0.1:' + str(cls.servers[0].server_port)
        cls.http_url = 'http://127.0.0.1:' + str(cls.servers[1].server_port)
        cls.threads = []
        for server in cls.servers:
            server.requests = []
            server.https_url = cls.url
            server.http_url = cls.http_url
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            cls.threads.append(thread)

    @classmethod
    def tearDownClass(cls):
        for server in cls.servers:
            server.shutdown()
            server.server_close()
        for thread in cls.threads:
            thread.join(timeout=2)
        cls.tls_dir.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='sdk fixtures ')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.cache = self.directory / 'cache'
        self.cache.mkdir(mode=0o700)
        self.archive = self.cache / (SHA + '.tar.zst')
        self.script = self.directory / 'helper.sh'
        source = (ROOT / 'build.sh').read_text()
        start = source.index('download_sdk_archive() ')
        end = source.index('\nensure_po2lmo() ', start)
        self.script.write_text('set -euo pipefail\n' + source[start:end] +
                               '\nresult="$("$@")"\nprintf "%s\\n" "$result"\n')
        for server in self.servers:
            server.requests.clear()

    def run_helper(self, path='/valid', sha=SHA, size=len(BODY), env=None, url=None):
        settings = dict(os.environ, SDK_CACHE_DIR=str(self.cache), CURL_CA_BUNDLE=str(self.cert))
        settings.update(HTTP_PROXY='', HTTPS_PROXY='', ALL_PROXY='', http_proxy='',
                        https_proxy='', all_proxy='', NO_PROXY='127.0.0.1,localhost')
        settings.update(env or {})
        return subprocess.run(['bash', str(self.script), 'download_sdk_archive',
                               url or self.url + path, sha, str(size)], env=settings,
                              capture_output=True, text=True, timeout=15)

    def assert_refused(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, '')
        self.assertEqual(list(self.cache.glob('download.*')), [])

    def test_download_and_cache_reuse_verify_bytes_and_hash(self):
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Path(result.stdout.strip()), self.archive)
        self.assertEqual(self.archive.read_bytes(), BODY)
        self.assertEqual(self.archive.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.cache.iterdir()), [self.archive])
        self.assertEqual(self.servers[0].requests, ['/valid'])
        again = self.run_helper('/must-not-fetch')
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertEqual(self.servers[0].requests, ['/valid'])

    def test_corrupt_cached_file_refuses_without_replacement_or_network(self):
        for body in (b'X' * len(BODY), BODY[:-1]):
            with self.subTest(body=body):
                self.archive.write_bytes(body)
                self.assert_refused(self.run_helper())
                self.assertEqual(self.archive.read_bytes(), body)
                self.assertEqual(self.servers[0].requests, [])

    def test_group_or_world_writable_cache_is_refused(self):
        self.archive.write_bytes(BODY)
        for mode in (0o620, 0o602, 0o666):
            with self.subTest(mode=mode):
                self.archive.chmod(mode)
                self.assert_refused(self.run_helper())
                self.assertEqual(self.archive.read_bytes(), BODY)
                self.assertEqual(self.archive.stat().st_mode & 0o777, mode)
                self.assertEqual(self.servers[0].requests, [])
        self.archive.chmod(0o600)
        tools = self.directory / 'tools'
        tools.mkdir()
        stat = tools / 'stat'
        stat.write_text('#!/bin/sh\nexit 1\n')
        stat.chmod(0o700)
        self.assert_refused(self.run_helper(env={'PATH': str(tools) + ':' + os.environ['PATH']}))
        self.assertEqual(self.archive.read_bytes(), BODY)
        self.assertEqual(self.servers[0].requests, [])

    def test_cached_symlink_directory_and_dangling_link_are_untouched(self):
        victim = self.directory / 'victim'
        victim.write_bytes(BODY)
        for kind in ('symlink', 'dangling', 'directory'):
            with self.subTest(kind=kind):
                if kind == 'directory':
                    self.archive.mkdir()
                else:
                    self.archive.symlink_to(victim if kind == 'symlink' else self.directory / 'missing')
                self.assert_refused(self.run_helper())
                self.assertEqual(victim.read_bytes(), BODY)
                self.assertEqual(self.servers[0].requests, [])
                if kind == 'directory':
                    self.archive.rmdir()
                else:
                    self.archive.unlink()

    def test_bad_downloads_never_publish_or_leave_partial_files(self):
        for path in ('/wrong', '/short', '/large', '/truncated', '/404'):
            with self.subTest(path=path):
                self.assert_refused(self.run_helper(path))
                self.assertEqual(list(self.cache.iterdir()), [])

    def test_https_redirect_succeeds_but_http_downgrade_is_not_contacted(self):
        self.assert_refused(self.run_helper('/downgrade'))
        self.assertEqual(self.servers[1].requests, [])
        result = self.run_helper('/redirect')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.archive.read_bytes(), BODY)

    def test_untrusted_certificate_is_rejected(self):
        self.assert_refused(self.run_helper(env={'CURL_CA_BUNDLE': '/etc/ssl/certs/ca-certificates.crt'}))
        self.assertEqual(self.servers[0].requests, [])

    def test_invalid_manifest_and_plain_http_fail_before_network(self):
        for sha, size in (('0' * 63, len(BODY)), ('G' * 64, len(BODY)),
                          (SHA, '0'), (SHA, '-1'), (SHA, '01'),
                          (SHA, '1000000000'), (SHA, '1+1')):
            with self.subTest(sha=sha, size=size):
                self.assert_refused(self.run_helper(sha=sha, size=size))
        self.assert_refused(self.run_helper(url=self.http_url + '/valid'))
        self.assertEqual(self.servers[0].requests, [])
        self.assertEqual(self.servers[1].requests, [])

    def test_failed_curl_and_legacy_oversized_body_still_refuse(self):
        tools = self.directory / 'tools'
        tools.mkdir()
        curl = tools / 'curl'
        for payload in ('printf "synthetic SDK archive\\n"; exit 18',
                        'printf "%01000d" 0; exit 0'):
            with self.subTest(payload=payload):
                curl.write_text('#!/bin/sh\n' + payload + '\n')
                curl.chmod(0o700)
                self.assert_refused(self.run_helper(env={'PATH': str(tools) + ':' + os.environ['PATH']}))
                self.assertFalse(self.archive.exists())

    def test_default_archive_hashes_and_sizes_are_pinned(self):
        source = (ROOT / 'build.sh').read_text().split('\nBACKEND_DESCRIPTION=', 1)[0]
        script = self.directory / 'defaults.sh'
        script.write_text(source + '\nprintf "%s\\n" "$IPK_SDK_SHA256" "$IPK_SDK_BYTES" '
                          '"$APK_SDK_SHA256" "$APK_SDK_BYTES"\n')
        env = dict(os.environ)
        for name in ('IPK_SDK_SHA256', 'IPK_SDK_BYTES', 'APK_SDK_SHA256', 'APK_SDK_BYTES'):
            env.pop(name, None)
        result = subprocess.run(['bash', str(script), '2.0.0'], env=env,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            'ac4a0405d2eea821b06f93c14ba13ffa90ad0457648903df7dde02570027ab21', '258916431',
            '1864152619092e781fa36a401960c8e9ae42d6a364c44ee5f0b197ca5f3c0fcc', '285832189'])

    def test_curl_configuration_cannot_disable_tls_verification(self):
        (self.directory / '.curlrc').write_text('insecure\n')
        self.assert_refused(self.run_helper(env={'CURL_HOME': str(self.directory),
                                                'CURL_CA_BUNDLE': '/etc/ssl/certs/ca-certificates.crt'}))

    def test_legacy_shared_partial_file_is_untouched(self):
        partial = self.cache / 'valid.part'
        victim = self.directory / 'victim'
        victim.write_text('preserved')
        partial.symlink_to(victim)
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(partial.is_symlink())
        self.assertEqual(victim.read_text(), 'preserved')

    def test_extraction_reuses_only_matching_digest_marker(self):
        archive = self.directory / 'fixture.tar.zst'
        raw = self.directory / 'fixture.tar'
        with tarfile.open(raw, 'w') as tar:
            info = tarfile.TarInfo('sdk/payload')
            info.size = 5
            tar.addfile(info, io.BytesIO(b'fresh'))
        subprocess.run(['zstd', '-q', str(raw), '-o', str(archive)], check=True)
        destination = self.directory / 'extracted' / 'ipk'
        destination.mkdir(parents=True)
        (destination / '.forkop-sdk-url').write_text(self.url + '/valid\n')
        (destination / 'old').write_text('unverified')
        settings = dict(os.environ, SDK_DIR=str(destination.parent))
        def extract(digest):
            return subprocess.run(['bash', str(self.script), 'extract_sdk', 'ipk', str(archive), digest],
                                  env=settings, capture_output=True, text=True, timeout=10)
        result = extract(SHA)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((destination / 'old').exists())
        self.assertEqual((destination / 'payload').read_bytes(), b'fresh')
        self.assertEqual((destination / '.forkop-sdk-sha256').read_text(), SHA + '\n')
        (destination / 'reuse').write_text('kept')
        self.assertEqual(extract(SHA).returncode, 0)
        self.assertTrue((destination / 'reuse').exists())
        self.assertEqual(extract('0' * 64).returncode, 0)
        self.assertFalse((destination / 'reuse').exists())

    def test_failed_extraction_preserves_previous_sdk_and_cleans_staging(self):
        archive = self.directory / 'invalid.tar.zst'
        archive.write_bytes(b'not an archive')
        sdk_dir = self.directory / 'extracted'
        destination = sdk_dir / 'ipk'
        destination.mkdir(parents=True)
        (destination / 'old').write_text('preserved')
        result = subprocess.run(['bash', str(self.script), 'extract_sdk', 'ipk', str(archive), SHA],
                                env=dict(os.environ, SDK_DIR=str(sdk_dir)),
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')
        self.assertEqual((destination / 'old').read_text(), 'preserved')
        self.assertEqual(list(sdk_dir.iterdir()), [destination])

    def test_extraction_requires_one_real_root_including_hidden_entries(self):
        for kind in ('empty', 'two_roots', 'hidden_file', 'symlink_root'):
            with self.subTest(kind=kind):
                raw = self.directory / (kind + '.tar')
                with tarfile.open(raw, 'w') as tar:
                    if kind != 'empty':
                        root = tarfile.TarInfo('sdk')
                        root.type = tarfile.SYMTYPE if kind == 'symlink_root' else tarfile.DIRTYPE
                        root.linkname = str(self.directory)
                        tar.addfile(root)
                    if kind == 'two_roots':
                        second = tarfile.TarInfo('other')
                        second.type = tarfile.DIRTYPE
                        tar.addfile(second)
                    elif kind == 'hidden_file':
                        tar.addfile(tarfile.TarInfo('.unexpected'))
                archive = raw.with_suffix('.tar.zst')
                subprocess.run(['zstd', '-q', str(raw), '-o', str(archive)], check=True)
                sdk_dir = self.directory / (kind + '-extracted')
                destination = sdk_dir / 'ipk'
                destination.mkdir(parents=True)
                (destination / 'old').write_text('preserved')
                result = subprocess.run(['bash', str(self.script), 'extract_sdk', 'ipk', str(archive), SHA],
                                        env=dict(os.environ, SDK_DIR=str(sdk_dir)),
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertEqual((destination / 'old').read_text(), 'preserved')
                self.assertEqual(list(sdk_dir.iterdir()), [destination])


if __name__ == '__main__':
    unittest.main()
