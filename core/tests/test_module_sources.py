"""Check source-asset trust boundaries without executing a module's code."""
import hashlib
import io
import json
from pathlib import Path
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
        self.patches = [mock.patch.object(sources, 'HERE', self.recipe),
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
        if args == ('env', '-json', 'GOMODCACHE', 'GOVERSION'):
            return json.dumps({'GOMODCACHE': str(self.cache), 'GOVERSION': 'go1.26.10'})
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

    def test_go_mod_hash_matches_pinned_independent_source_sum(self):
        self.assertEqual(sources.mod_sum(self.mod), self.mod_hash)

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
