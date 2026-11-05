#!/usr/bin/env python3
"""Make an owned workspace from the already installed Go toolchain."""
import argparse
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys

from module_sources import ENV, SourceError, input_stat, output_directory, signature


def isolate(source, output):
    source, output = Path(source).resolve(strict=True), Path(output).absolute()
    output_directory(output)
    if (not source.is_dir() or source == output or source in output.parents or
            not (source / 'bin/go').is_file() or not (source / 'VERSION').is_file()):
        raise SourceError('invalid-toolchain-workspace-source')
    output.mkdir(mode=0o700)
    created = output.stat()
    result = {'files': 0, 'source_writable_files': 0, 'source_other_owner_files': 0,
              'source_multi_link_files': 0}
    try:
        for path in sorted(source.rglob('*'), key=lambda p: (len(p.parts), str(p))):
            info = path.lstat()
            target = output / path.relative_to(source)
            if stat.S_ISDIR(info.st_mode):
                target.mkdir(mode=0o700)
                continue
            if not stat.S_ISREG(info.st_mode):
                raise SourceError('unsupported-toolchain-workspace-entry')
            shutil.copyfile(path, target)
            target.chmod(0o700 if info.st_mode & 0o111 else 0o600)
            if signature(path.lstat()) != signature(info):
                raise SourceError('toolchain-changed-during-copy')
            input_stat(target, info.st_size)
            result['files'] += 1
            result['source_writable_files'] += bool(info.st_mode & 0o022)
            result['source_other_owner_files'] += info.st_uid not in (0, os.getuid())
            result['source_multi_link_files'] += info.st_nlink != 1
        return result
    except BaseException:
        current = output.lstat()
        if stat.S_ISDIR(current.st_mode) and (current.st_dev, current.st_ino) == (created.st_dev, created.st_ino):
            shutil.rmtree(output)
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        root = subprocess.check_output(['go', 'env', 'GOROOT'], env=ENV, text=True,
                                       stderr=subprocess.DEVNULL, timeout=30).strip()
        print(json.dumps(isolate(root, args.output), sort_keys=True))
    except SourceError as error:
        print('core-toolchain-workspace: ' + str(error), file=sys.stderr)
        raise SystemExit(2)
    except (OSError, ValueError, shutil.Error, subprocess.SubprocessError):
        print('core-toolchain-workspace: preparation-failed', file=sys.stderr)
        raise SystemExit(2)
