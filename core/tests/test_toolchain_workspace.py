"""Keep permissive installed tool caches outside the checked build workspace."""
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from isolate_toolchain import isolate
from module_sources import SourceError, input_stat, signature


class ToolchainWorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.source, self.output = self.root / 'installed', self.root / 'private'
        for name, body in {'bin/go': b'synthetic existing tool', 'VERSION': b'go1.26.10\n',
                           'src/runtime/proc.go': b'// original source\n'}.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(body)
            path.chmod(0o777 if name == 'bin/go' else 0o666)

    def test_writable_cache_refuses_but_the_owned_copy_preserves_its_bytes(self):
        before = {p.relative_to(self.source): (p.read_bytes(), signature(p.stat()))
                  for p in self.source.rglob('*') if p.is_file()}
        with self.assertRaises(SourceError):
            input_stat(self.source / 'src/runtime/proc.go', 1024)
        result = isolate(self.source, self.output)
        self.assertEqual(result, {'files': 3, 'source_writable_files': 3,
                                 'source_other_owner_files': 0, 'source_multi_link_files': 0})
        for relative, (body, original) in before.items():
            self.assertEqual((self.source / relative).read_bytes(), body)
            self.assertEqual(signature((self.source / relative).stat()), original)
            self.assertEqual((self.output / relative).read_bytes(), body)
            input_stat(self.output / relative, len(body))
        self.assertEqual((self.output / 'bin/go').stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.output / 'src/runtime/proc.go').stat().st_mode & 0o777, 0o600)
        self.assertTrue(all(p.stat().st_mode & 0o777 == 0o700 for p in self.output.rglob('*') if p.is_dir()))

    def test_existing_outputs_and_links_are_preserved(self):
        for kind in ('file', 'directory', 'symlink'):
            with self.subTest(kind=kind):
                foreign = self.root / ('foreign-' + kind)
                foreign.write_bytes(b'keep')
                if kind == 'file': self.output.write_bytes(b'keep')
                elif kind == 'directory': self.output.mkdir()
                else: self.output.symlink_to(foreign)
                with self.assertRaises(SourceError): isolate(self.source, self.output)
                self.assertEqual(foreign.read_bytes(), b'keep')
                if kind == 'directory': self.output.rmdir()
                else: self.output.unlink()

    def test_unsafe_parent_and_destination_inside_source_refuse(self):
        with self.assertRaises(SourceError): isolate(self.source, self.source / 'copy')
        self.assertFalse((self.source / 'copy').exists())
        self.root.chmod(0o777)
        try:
            with self.assertRaises(SourceError): isolate(self.source, self.output)
            self.assertFalse(self.output.exists())
        finally:
            self.root.chmod(0o700)

    def test_source_links_and_special_files_are_not_followed_or_opened(self):
        foreign = self.root / 'foreign'
        foreign.write_bytes(b'keep')
        for kind in ('symlink', 'fifo'):
            path = self.source / 'unexpected'
            if kind == 'symlink': path.symlink_to(foreign)
            else: os.mkfifo(path)
            try:
                with self.assertRaises(SourceError): isolate(self.source, self.output)
                self.assertFalse(self.output.exists())
                self.assertEqual(foreign.read_bytes(), b'keep')
            finally:
                path.unlink()

    def test_original_hardlinks_are_not_carried_into_the_owned_copy(self):
        path = self.source / 'src/runtime/proc.go'
        foreign = self.root / 'hardlink'
        foreign.hardlink_to(path)
        result = isolate(self.source, self.output)
        self.assertEqual(result['source_multi_link_files'], 1)
        copied = self.output / 'src/runtime/proc.go'
        input_stat(copied, 1024)
        self.assertEqual(copied.stat().st_nlink, 1)
        self.assertEqual(foreign.read_bytes(), copied.read_bytes())

    def test_source_changes_during_copy_refuse_and_remove_only_our_partial_copy(self):
        original = shutil.copyfile
        def change(source, target):
            result = original(source, target)
            Path(source).write_bytes(b'changed during copy')
            return result
        with patch.object(shutil, 'copyfile', side_effect=change):
            with self.assertRaisesRegex(SourceError, 'toolchain-changed-during-copy'):
                isolate(self.source, self.output)
        self.assertFalse(self.output.exists())
        self.assertTrue(self.source.is_dir())


if __name__ == '__main__':
    unittest.main()
