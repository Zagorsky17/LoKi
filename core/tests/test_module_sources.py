"""Check source-asset trust boundaries without executing a module's code."""
import hashlib
import gzip
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import module_sources as sources


class ModuleSourcesTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.source, self.cache, self.recipe = [self.root / name for name in ('source', 'cache', 'recipe')]
        self.output, self.binary = self.root / 'sources.tar.gz', self.root / 'binary'
        self.version = 'v0.57.0'
        self.name = 'golang.org/x/net'
        self.leaf = self.cache / 'cache/download/golang.org/x/net/@v/v0.57.0'
        self.mod = (b'module golang.org/x/net\n\ngo 1.25.0\n\nrequire (\n'
                    b'\tgolang.org/x/crypto v0.54.0\n\tgolang.org/x/sys v0.47.0\n'
                    b'\tgolang.org/x/term v0.45.0\n\tgolang.org/x/text v0.40.0\n)\n')
        self.mod_hash = 'h1:KpXc8iv+r3XplLAG/f7Jsf9RPszJzdR0f58q9vGOuEU='
        self.zip_hash = 'h1:K5+3DljvIuDG9/Jv9rvyMywYNFCQ9RSUY6OOTTkT+tE='
        self.write(self.source / 'go.sum', f'{self.name} {self.version} {self.zip_hash}\n'
                   f'{self.name} {self.version}/go.mod {self.mod_hash}\n'.encode())
        self.write(self.source / 'go.mod', b'module github.com/sagernet/sing-box\n')
        self.write(self.binary, b'synthetic binary metadata fixture')
        self.write(Path(str(self.leaf) + '.mod'), self.mod)
        self.write(Path(str(self.leaf) + '.info'), json.dumps({'Version': self.version,
                   'Time': '2026-01-01T00:00:00Z', 'Origin': {'Dir': 'private-build-path'}}).encode())
        # The mocked Go verifier models an already verified cache; ZIP payloads stay opaque.
        self.write(Path(str(self.leaf) + '.zip'), b'synthetic verified opaque ZIP')
        self.write(Path(str(self.leaf) + '.ziphash'), (self.zip_hash + '\n').encode())
        self.write(self.cache / 'golang.org/x/net@v0.57.0/publicsuffix/table.go',
                   ('// git revision ' + sources.PSL_REVISION + '\n').encode())
        for name in sources.EXTRA:
            self.write(self.recipe / 'source-data' / name, (sources.HERE / 'source-data' / name).read_bytes())
        self.go_archive = self.root / 'go1.26.10.src.tar.gz'
        self.goroot = self.root / 'go'
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w') as archive:
            for name, body in {'VERSION': b'go1.26.10\n', 'LICENSE': b'synthetic original notice\n',
                               'src/runtime/proc.go': b'// synthetic preferred source\n'}.items():
                self.write(self.goroot / name, body)
                entry = tarfile.TarInfo('go/' + name)
                entry.size, entry.mode = len(body), 0o644
                archive.addfile(entry, io.BytesIO(body))
        self.go_source_bytes = gzip.compress(data.getvalue(), mtime=0)
        self.write(self.go_archive, self.go_source_bytes)
        self.go_pin = {'version': 'go1.26.10', 'filename': self.go_archive.name,
                       'size': len(self.go_source_bytes),
                       'sha256': hashlib.sha256(self.go_source_bytes).hexdigest()}
        self.patches = [mock.patch.object(sources, 'GO_SOURCE', self.go_pin, create=True),
                        mock.patch.object(sources, 'go_source_path', return_value=self.go_archive, create=True),
                        mock.patch.object(sources, 'HERE', self.recipe),
                        mock.patch.object(sources, 'go', side_effect=self.go),
                        mock.patch.object(sources, 'binary_manifest', side_effect=self.manifest)]
        for patch in self.patches:
            patch.start()
            self.addCleanup(patch.stop)

    def write(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(0o644)

    def go(self, source, *args):
        if args == ('env', '-json', 'GOROOT', 'GOMODCACHE', 'GOVERSION'):
            return json.dumps({'GOROOT': str(self.goroot), 'GOMODCACHE': str(self.cache), 'GOVERSION': 'go1.26.10'})
        self.assertEqual(args, ('mod', 'verify'))
        return 'all modules verified\n'

    def manifest(self, source, binary):
        return {'unresolved': [], 'source_tree': sources.source_receipt(self.source),
                'go_version': 'go1.26.10', 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                'settings': {'GOOS': 'linux', 'GOARCH': 'amd64', 'CGO_ENABLED': '0'},
                'modules': [{'path': self.name, 'version': self.version,
                             'sum': self.zip_hash, 'replacement': None}]}

    def collect(self):
        return sources.collect(self.source, [self.binary], self.output)

    def assert_refused(self):
        with self.assertRaises((sources.SourceError, OSError, ValueError)):
            self.collect()
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.root.glob('.loki-module-sources-*')))

    def test_the_pinned_go_sources_are_included_and_bound_to_the_binary(self):
        manifest = self.collect()
        name = 'toolchain/' + self.go_archive.name
        self.assertIn(name, {item['path'] for item in manifest['entries']})
        self.assertEqual(manifest['go_source'], self.go_pin)
        with tarfile.open(self.output) as archive:
            self.assertEqual(archive.extractfile(name).read(), self.go_source_bytes)
        self.assertEqual(sources.verify_archive(self.output, manifest['source_tree'],
                         [self.manifest(self.source, self.binary)]), manifest)

    def test_missing_corrupt_oversized_or_aliased_go_sources_refuse_offline(self):
        original = self.go_source_bytes
        for kind in ('missing', 'corrupt', 'oversized', 'symlink', 'hardlink'):
            with self.subTest(kind=kind), mock.patch.object(sources.subprocess, 'run') as network:
                self.go_archive.unlink(missing_ok=True)
                target = self.root / 'kept-source'
                target.unlink(missing_ok=True)
                self.write(target, original)
                if kind == 'corrupt': self.write(self.go_archive, b'x' * len(original))
                elif kind == 'oversized': self.write(self.go_archive, original + b'x')
                elif kind == 'symlink': self.go_archive.symlink_to(target)
                elif kind == 'hardlink': self.go_archive.hardlink_to(target)
                self.assert_refused()
                self.assertEqual(target.read_bytes(), original)
                network.assert_not_called()

    def test_source_verifier_requires_the_go_pin_even_if_manifest_hashes_are_updated(self):
        manifest = self.collect()
        original = self.output.read_bytes()
        name = 'toolchain/' + self.go_archive.name
        changes = [lambda data, _: data.pop(name),
                   lambda data, _: data.update({name: b'x' * len(self.go_source_bytes)}),
                   lambda data, meta: meta['go_source'].update(sha256='0' * 64),
                   lambda data, meta: meta.update(go_version='go1.27.0'),
                   lambda data, meta: meta.update(schema=1),
                   lambda data, _: data.update({'toolchain/../outside.tar.gz': b'no'})]
        for change in changes:
            with self.subTest(change=change):
                self.output.write_bytes(original)
                self.rewrite_archive(change)
                with self.assertRaises((sources.SourceError, KeyError)):
                    sources.verify_archive(self.output, manifest['source_tree'],
                                           [self.manifest(self.source, self.binary)])

    def test_go_archive_replacement_after_verification_is_not_published(self):
        original = tarfile.TarFile.addfile
        def change(archive, info, stream=None):
            if info.name == 'toolchain/' + self.go_archive.name:
                self.write(self.go_archive, b'changed during source publication')
            return original(archive, info, stream)
        with mock.patch.object(tarfile.TarFile, 'addfile', new=change):
            self.assert_refused()

    def test_missing_changed_or_aliased_toolchain_source_is_refused(self):
        path = self.goroot / 'src/runtime/proc.go'
        original = path.read_bytes()
        target = self.root / 'preserved-toolchain-source'
        self.write(target, original)
        for kind in ('changed', 'missing', 'symlink', 'hardlink', 'oversized'):
            with self.subTest(kind=kind):
                path.unlink(missing_ok=True)
                if kind == 'changed': self.write(path, b'// modified stdlib with unchanged Go version\n')
                elif kind == 'symlink': path.symlink_to(target)
                elif kind == 'hardlink': path.hardlink_to(target)
                elif kind == 'oversized':
                    with path.open('wb') as stream:
                        stream.seek(8388608)
                        stream.write(b'x')
                self.assert_refused()
                self.assertEqual(target.read_bytes(), original)

    def test_toolchain_source_changes_after_the_initial_check_are_refused(self):
        original = self.go
        def change(source, *args):
            if args == ('mod', 'verify'):
                self.write(self.goroot / 'src/runtime/proc.go', b'changed during metadata checks')
            return original(source, *args)
        with mock.patch.object(sources, 'go', side_effect=change):
            self.assert_refused()

    def test_toolchain_source_changes_during_archive_publication_are_refused(self):
        original = tarfile.TarFile.addfile
        def change(archive, info, stream=None):
            if info.name.endswith('.zip'):
                self.write(self.goroot / 'src/runtime/proc.go', b'changed after the metadata checks')
            return original(archive, info, stream)
        with mock.patch.object(tarfile.TarFile, 'addfile', new=change):
            self.assert_refused()

    def test_go_tree_entry_file_and_total_limits_are_enforced(self):
        for limit in ('GO_FILE_LIMIT', 'GO_TREE_LIMIT', 'GO_ENTRY_LIMIT'):
            with self.subTest(limit=limit), mock.patch.object(sources, limit, 1):
                self.assert_refused()

    def test_go_tree_refuses_unsafe_paths_links_and_duplicate_members(self):
        for kind in ('absolute', 'traversal', 'symlink', 'duplicate'):
            with self.subTest(kind=kind):
                data = io.BytesIO()
                with tarfile.open(fileobj=data, mode='w') as archive:
                    name = '/outside' if kind == 'absolute' else 'go/../outside' if kind == 'traversal' else 'go/VERSION'
                    entry = tarfile.TarInfo(name)
                    if kind == 'symlink':
                        entry.type, entry.linkname = tarfile.SYMTYPE, '/outside'
                    body = (self.goroot / 'VERSION').read_bytes() if kind == 'duplicate' else b''
                    entry.size = len(body)
                    archive.addfile(entry, io.BytesIO(body))
                    if kind == 'duplicate': archive.addfile(entry, io.BytesIO(body))
                body = gzip.compress(data.getvalue(), mtime=0)
                self.write(self.go_archive, body)
                with mock.patch.dict(sources.GO_SOURCE, size=len(body), sha256=hashlib.sha256(body).hexdigest()):
                    self.assert_refused()

    def test_unreviewed_go_version_refuses_before_source_collection(self):
        with mock.patch.dict(sources.GO_SOURCE, version='go1.27.0'):
            self.assert_refused()

    def test_explicit_fetch_is_pinned_bounded_atomic_and_cached(self):
        self.go_archive.unlink()
        calls = []
        real_run = subprocess.run
        def download(args, **kwargs):
            calls.append(args)
            self.assertEqual(args[args.index('--proto') + 1], '=https')
            self.assertEqual(args[args.index('--proto-redir') + 1], '=https')
            self.assertIn('https://go.dev/dl/' + self.go_archive.name, args)
            self.assertEqual(args[args.index('--max-filesize') + 1], str(len(self.go_source_bytes)))
            self.assertEqual(kwargs['timeout'], 310)
            output = Path(args[args.index('--output') + 1])
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            excessive = self.root / 'excessive-download'
            result = real_run([sys.executable, '-B', '-c',
                               'import sys\nwith open(sys.argv[1],"wb") as out:\n out.write(b"x"*int(sys.argv[2]))\n',
                               str(excessive), str(len(self.go_source_bytes) + 1)],
                              preexec_fn=kwargs['preexec_fn'], capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertLessEqual(excessive.stat().st_size, len(self.go_source_bytes))
            output.write_bytes(self.go_source_bytes)
        with mock.patch.object(sources.subprocess, 'run', side_effect=download):
            self.assertEqual(sources.fetch_go_source(), self.go_archive)
            self.assertEqual(sources.fetch_go_source(), self.go_archive)
        self.assertEqual(len(calls), 1)
        self.assertEqual(self.go_archive.read_bytes(), self.go_source_bytes)
        self.assertEqual(self.go_archive.stat().st_mode & 0o777, 0o644)
        self.assertFalse(list(self.root.glob('.loki-go-source-*')))

    def test_failed_fetch_preserves_existing_data_and_cleans_partial_downloads(self):
        for kind in ('network', 'corrupt', 'concurrent'):
            self.go_archive.unlink(missing_ok=True)
            def fail(args, **kwargs):
                temporary = Path(args[args.index('--output') + 1])
                temporary.write_bytes(b'bad' if kind == 'corrupt' else self.go_source_bytes)
                if kind == 'network': raise subprocess.CalledProcessError(7, args)
                if kind == 'concurrent': self.write(self.go_archive, b'preserve concurrent output')
            with self.subTest(kind=kind), mock.patch.object(sources.subprocess, 'run', side_effect=fail):
                with self.assertRaises((sources.SourceError, OSError, subprocess.SubprocessError)):
                    sources.fetch_go_source()
                self.assertFalse(list(self.root.glob('.loki-go-source-*')))
                if kind == 'concurrent':
                    self.assertEqual(self.go_archive.read_bytes(), b'preserve concurrent output')
                else:
                    self.assertFalse(self.go_archive.exists())
        with mock.patch.object(sources.subprocess, 'run') as network:
            with self.assertRaises(sources.SourceError):
                sources.fetch_go_source()
            network.assert_not_called()

    def test_a_same_size_corrupt_cached_go_archive_is_preserved_and_not_used(self):
        corrupt = b'x' * len(self.go_source_bytes)
        self.write(self.go_archive, corrupt)
        with mock.patch.object(sources.subprocess, 'run') as network:
            with self.assertRaises(sources.SourceError): sources.fetch_go_source()
            network.assert_not_called()
        self.assertEqual(self.go_archive.read_bytes(), corrupt)

    def test_fetch_checks_new_parent_paths_before_writing(self):
        self.go_archive.unlink()
        parent = self.root / 'new' / 'nested'
        destination = parent / self.go_archive.name
        with mock.patch.object(sources, 'go_source_path', return_value=destination):
            with mock.patch.object(sources.subprocess, 'run', side_effect=lambda args, **kwargs:
                                   Path(args[args.index('--output') + 1]).write_bytes(self.go_source_bytes)):
                self.assertEqual(sources.fetch_go_source(), destination)
            self.assertEqual(parent.stat().st_mode & 0o777, 0o700)
        foreign = self.root / 'foreign'
        foreign.mkdir()
        alias = self.root / 'alias'
        alias.symlink_to(foreign, target_is_directory=True)
        for path in (alias / 'new' / self.go_archive.name, self.root / 'unsafe' / self.go_archive.name):
            (self.root / 'unsafe').mkdir(mode=0o777, exist_ok=True)
            (self.root / 'unsafe').chmod(0o777)
            try:
                with mock.patch.object(sources, 'go_source_path', return_value=path), \
                        mock.patch.object(sources.subprocess, 'run') as network:
                    with self.assertRaises(sources.SourceError): sources.fetch_go_source()
                    network.assert_not_called()
                    self.assertFalse((foreign / 'new').exists())
            finally:
                (self.root / 'unsafe').chmod(0o700)

    def test_go_mod_hash_matches_pinned_independent_source_sum(self):
        self.assertEqual(sources.mod_sum(self.mod), self.mod_hash)

    def test_preliminary_reader_shares_metadata_and_does_not_buffer_source_blobs(self):
        manifest = self.collect()
        parsed, entries, payloads = sources.read_archive(self.output)
        self.assertEqual(parsed, manifest)
        self.assertEqual(entries, {row['path']: row for row in manifest['entries']})
        self.assertTrue(payloads)
        self.assertFalse(any(name.endswith(('.zip', '.tar.gz')) for name in payloads))
        self.assertNotIn('SOURCES.json', entries)
        self.assertNotIn('SOURCES.json', payloads)

    def test_preliminary_reader_rejects_member_excess_even_with_the_manifest_first(self):
        with tarfile.open(self.output, 'w:gz') as archive:
            body = b'{"binaries":[]}'
            entry = tarfile.TarInfo('SOURCES.json')
            entry.size, entry.mode = len(body), 0o644
            archive.addfile(entry, io.BytesIO(body))
            for index in range(20001):
                entry = tarfile.TarInfo('empty/%05d' % index)
                entry.mode = 0o644
                archive.addfile(entry)
        calls = []
        original = tarfile.TarFile.next
        def counted(archive):
            calls.append(True)
            return original(archive)
        with mock.patch.object(tarfile.TarFile, 'next', counted):
            with self.assertRaisesRegex(sources.SourceError, 'source-archive-resource-limit'):
                sources.read_archive(self.output)
        self.assertLessEqual(len(calls), 20002)

    def test_preliminary_reader_refuses_oversized_headers_before_reading_payloads(self):
        for name, limit in [('SOURCES.json', 4194304), ('modules/large.zip', sources.ZIP_LIMIT),
                            ('toolchain/' + self.go_archive.name, self.go_pin['size'])]:
            with self.subTest(name=name):
                with tarfile.open(self.output, 'w:gz') as archive:
                    entry = tarfile.TarInfo(name)
                    entry.size, entry.mode = limit + 1, 0o644
                    archive.addfile(entry)
                self.assertLess(self.output.stat().st_size, 1024)
                with self.assertRaisesRegex(sources.SourceError, 'invalid-source-archive-member'):
                    sources.read_archive(self.output)

    def test_asset_is_reproducible_bound_and_has_only_portable_metadata(self):
        manifest = self.collect()
        self.assertEqual(sources.verify_archive(self.output, manifest['source_tree'],
                         [self.manifest(self.source, self.binary)]), manifest)
        original = self.output.read_bytes()
        other = self.root / 'second.tar.gz'
        sources.collect(self.source, [self.binary], other)
        self.assertEqual(original, other.read_bytes())
        with tarfile.open(self.output) as archive:
            records = {m.name: m for m in archive.getmembers()}
            self.assertTrue(all(m.isfile() and m.mode == 0o644 and m.uid == m.gid == m.mtime == 0
                                for m in records.values()))
            payload = json.loads(archive.extractfile('SOURCES.json').read())
            self.assertEqual(payload, manifest)
            for entry in payload['entries']:
                data = archive.extractfile(entry['path']).read()
                self.assertEqual(len(data), entry['size'])
                self.assertEqual(hashlib.sha256(data).hexdigest(), entry['sha256'])
            info = archive.extractfile('modules/cache/download/golang.org/x/net/@v/v0.57.0.info').read()
            self.assertNotIn(b'private-build-path', info)
            self.assertEqual(set(json.loads(info)), {'Version', 'Time'})

    def rewrite_archive(self, change):
        with tarfile.open(self.output) as archive:
            contents = {m.name: archive.extractfile(m).read() for m in archive}
        manifest = json.loads(contents.pop('SOURCES.json'))
        change(contents, manifest)
        manifest['entries'] = [{'path': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                               for name, data in contents.items()]
        contents['SOURCES.json'] = json.dumps(manifest).encode()
        with tarfile.open(self.output, 'w:gz') as archive:
            for name, data in contents.items():
                member = tarfile.TarInfo(name)
                member.size, member.mode = len(data), 0o644
                archive.addfile(member, io.BytesIO(data))

    def test_archive_verifier_refuses_a_different_source_or_binary(self):
        manifest = self.collect()
        binary = self.manifest(self.source, self.binary)
        for source, profile in (({'sha256': '0' * 64, 'files': 2}, binary),
                                (manifest['source_tree'], dict(binary, binary_sha256='0' * 64))):
            with self.subTest(source=source):
                with self.assertRaises(sources.SourceError):
                    sources.verify_archive(self.output, source, [profile])

    def test_archive_verifier_refuses_missing_modules_extra_paths_and_changed_psl(self):
        manifest = self.collect()
        original = self.output.read_bytes()
        mutations = [lambda data, _: data.pop('modules/cache/download/golang.org/x/net/@v/v0.57.0.zip'),
                     lambda data, _: data.update({'../outside': b'not a module source'}),
                     lambda data, _: data.update({'source-data/publicsuffix/public_suffix_list.dat': b'wrong source'}),
                     lambda data, _: data.update({'modules/cache/download/golang.org/x/net/@v/v0.57.0.mod': b'changed go.mod'})]
        for change in mutations:
            self.output.write_bytes(original)
            self.rewrite_archive(change)
            with self.subTest(change=change):
                with self.assertRaises((sources.SourceError, KeyError)):
                    sources.verify_archive(self.output, manifest['source_tree'],
                                           [self.manifest(self.source, self.binary)])

    def test_archive_verifier_refuses_info_with_private_origin_even_if_hashes_match(self):
        manifest = self.collect()
        def change(data, _):
            path = 'modules/cache/download/golang.org/x/net/@v/v0.57.0.info'
            info = json.loads(data[path])
            info['Origin'] = {'Dir': 'synthetic-private-path'}
            data[path] = json.dumps(info).encode()
        self.rewrite_archive(change)
        with self.assertRaises(sources.SourceError):
            sources.verify_archive(self.output, manifest['source_tree'], [self.manifest(self.source, self.binary)])

    def test_archive_verifier_refuses_links_duplicates_and_unsafe_modes(self):
        manifest = self.collect()
        for kind in ('symlink', 'duplicate', 'mode'):
            with self.subTest(kind=kind):
                with tarfile.open(self.output, 'w:gz') as archive:
                    member = tarfile.TarInfo('SOURCES.json')
                    member.mode = 0o666 if kind == 'mode' else 0o644
                    if kind == 'symlink':
                        member.type, member.linkname = tarfile.SYMTYPE, '/outside'
                    archive.addfile(member)
                    if kind == 'duplicate':
                        archive.addfile(member)
                with self.assertRaises(sources.SourceError):
                    sources.verify_archive(self.output, manifest['source_tree'], [self.manifest(self.source, self.binary)])

    def test_existing_file_and_symlink_are_preserved(self):
        self.write(self.output, b'keep')
        with self.assertRaises(sources.SourceError):
            self.collect()
        self.assertEqual(self.output.read_bytes(), b'keep')
        self.output.unlink()
        target = self.root / 'foreign'
        self.write(target, b'foreign')
        self.output.symlink_to(target)
        with self.assertRaises(sources.SourceError):
            self.collect()
        self.assertTrue(self.output.is_symlink())
        self.assertEqual(target.read_bytes(), b'foreign')

    def test_untrusted_output_parent_refuses_before_metadata_tools(self):
        self.root.chmod(0o777)
        try:
            with mock.patch.object(sources, 'go') as tool:
                self.assert_refused()
                tool.assert_not_called()
        finally:
            self.root.chmod(0o700)

    def test_changed_cached_zip_hash_and_missing_zip_are_refused(self):
        path = Path(str(self.leaf) + '.ziphash')
        self.write(path, b'h1:wrong\n')
        self.assert_refused()
        self.write(path, (self.zip_hash + '\n').encode())
        Path(str(self.leaf) + '.zip').unlink()
        self.assert_refused()

    def test_cached_input_symlinks_and_hardlinks_are_refused(self):
        path = Path(str(self.leaf) + '.zip')
        target = self.root / 'foreign'
        self.write(target, path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.assert_refused()
        path.unlink()
        path.hardlink_to(target)
        self.assert_refused()
        self.assertEqual(target.read_bytes(), b'synthetic verified opaque ZIP')

    def test_modified_go_mod_and_unreviewed_binary_refuse_without_output(self):
        self.write(Path(str(self.leaf) + '.mod'), self.mod + b'// changed\n')
        self.assert_refused()
        self.write(Path(str(self.leaf) + '.mod'), self.mod)
        manifest = self.manifest(self.source, self.binary)
        manifest['unresolved'] = [{'kind': 'synthetic unknown module'}]
        with mock.patch.object(sources, 'binary_manifest', return_value=manifest):
            self.assert_refused()

    def test_go_verification_error_does_not_leave_an_asset(self):
        original = self.go
        def refuse(source, *args):
            if args == ('mod', 'verify'):
                raise sources.SourceError('synthetic-go-verify-failure')
            return original(source, *args)
        with mock.patch.object(sources, 'go', side_effect=refuse):
            self.assert_refused()

    def test_invalid_info_version_or_secret_timestamp_is_not_copied(self):
        path = Path(str(self.leaf) + '.info')
        for info in ({'Version': 'v9.9.9', 'Time': '2026-01-01T00:00:00Z'},
                     {'Version': self.version, 'Time': 'synthetic-secret-must-not-be-copied'},
                     {'Version': self.version, 'Time': '2026-02-31T00:00:00Z'}):
            with self.subTest(info=info['Version']):
                self.write(path, json.dumps(info).encode())
                self.assert_refused()

    def test_required_info_and_aggregate_metadata_budget_are_enforced(self):
        path = Path(str(self.leaf) + '.info')
        previous = path.read_bytes()
        path.unlink()
        self.assert_refused()
        self.write(path, previous)
        with mock.patch.object(sources, 'METADATA_TOTAL_LIMIT', len(self.mod) - 1):
            self.assert_refused()

    def test_ziphash_replacement_during_go_verification_is_detected(self):
        path = Path(str(self.leaf) + '.ziphash')
        original = self.go
        def replace(source, *args):
            if args == ('mod', 'verify'):
                data = path.read_bytes()
                path.rename(self.root / 'previous-ziphash')
                self.write(path, data)
            return original(source, *args)
        with mock.patch.object(sources, 'go', side_effect=replace):
            self.assert_refused()

    def test_metadata_tools_cannot_silently_change_the_bound_core_source(self):
        original = self.go
        def change(source, *args):
            if args == ('mod', 'verify'):
                path = self.source / 'go.sum'
                self.write(path, path.read_bytes() + b'\n')
            return original(source, *args)
        with mock.patch.object(sources, 'go', side_effect=change):
            self.assert_refused()

    def test_missing_binary_and_conflicting_profiles_are_refused(self):
        with self.assertRaises(sources.SourceError):
            sources.collect(self.source, [], self.output)
        with self.assertRaises(sources.SourceError):
            sources.collect(self.source, [self.binary, self.binary], self.output)
        other = self.root / 'other-binary'
        self.write(other, b'different synthetic profile')
        original = self.manifest
        def conflict(source, binary):
            result = original(source, binary)
            if binary == other:
                result['modules'][0]['version'] = 'v0.58.0'
            return result
        with mock.patch.object(sources, 'binary_manifest', side_effect=conflict):
            with self.assertRaises(sources.SourceError):
                sources.collect(self.source, [self.binary, other], self.output)
        self.assertFalse(self.output.exists())

    def test_sparse_oversized_zip_is_rejected_before_reading_it(self):
        with Path(str(self.leaf) + '.zip').open('wb') as stream:
            stream.seek(sources.ZIP_LIMIT)
            stream.write(b'x')
        self.assert_refused()

    def test_post_verification_input_change_is_not_published(self):
        original = tarfile.TarFile.addfile
        path = Path(str(self.leaf) + '.zip')
        def change(archive, info, stream=None):
            if info.name.endswith('.zip'):
                self.write(path, b'replaced after verification')
            return original(archive, info, stream)
        with mock.patch.object(tarfile.TarFile, 'addfile', new=change):
            self.assert_refused()

    def test_lazy_graph_mod_without_info_is_included(self):
        name, version = 'example.com/lazy', 'v1.2.3'
        data = b'module example.com/lazy\n'
        checksum = sources.mod_sum(data)
        with (self.source / 'go.sum').open('ab') as stream:
            stream.write(f'{name} {version}/go.mod {checksum}\n'.encode())
        self.write(self.cache / 'cache/download/example.com/lazy/@v/v1.2.3.mod', data)
        manifest = self.collect()
        self.assertIn('modules/cache/download/example.com/lazy/@v/v1.2.3.mod',
                      {r['path'] for r in manifest['entries']})


if __name__ == '__main__':
    unittest.main()
