#!/usr/bin/env python3
"""Collect offline Go module sources for trusted, freshly prepared LoKi builds."""
import argparse
import base64
from contextlib import contextmanager
from datetime import datetime
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tarfile
import tempfile

from notices import module_name, source_receipt


HERE = Path(__file__).resolve().parent
METADATA_LIMIT = 1048576
ZIP_LIMIT = 536870912
METADATA_TOTAL_LIMIT = 16777216
ENV = dict(os.environ, GOTOOLCHAIN='local', GOPROXY='off', GOSUMDB='off',
           GONOPROXY='none', GOWORK='off', GOENV='off', GOFLAGS='-mod=readonly')
PSL_REVISION = 'd6c92f1bbb7433e5db7b8405c25d4035fb8ff376'
EXTRA = {
    'public_suffix_list.dat': 'a5638281157e8c902b127a5376f9ea2d024bf2ee11524133a6a76cd1d14ee7be',
    'MPL-2.0.txt': '66a3107d5ad6a058aab753eaac2047ccb2ed0e39465dd0fe5844da3e300d5172',
}


class SourceError(ValueError):
    pass


def signature(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def input_stat(path, limit):
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, os.getuid()) or
            info.st_mode & 0o022 or info.st_nlink != 1 or info.st_size > limit):
        raise SourceError('unsafe-or-oversized-input')
    return info


@contextmanager
def input_file(path, limit, expected=None):
    before = input_stat(path, limit)
    if expected is not None and signature(before) != expected:
        raise SourceError('input-changed-since-verification')
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as stream:
        if signature(os.fstat(stream.fileno())) != signature(before):
            raise SourceError('input-changed-during-open')
        yield stream, before
        if (signature(os.fstat(stream.fileno())) != signature(before) or
                signature(path.lstat()) != signature(before)):
            raise SourceError('input-changed-during-read')


def read_input(path, limit, expected=None):
    with input_file(path, limit, expected) as (stream, _):
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise SourceError('input-byte-limit')
        return data


def go(source, *arguments):
    return subprocess.check_output(['go', *arguments], cwd=source, env=ENV,
                                   stderr=subprocess.DEVNULL, timeout=120, text=True)


def escape(value):
    return ''.join('!' + c.lower() if c.isupper() else c for c in value)


def identity(path, version):
    module_name(path)
    if not re.fullmatch(r'v[0-9][A-Za-z0-9.+-]*', version):
        raise SourceError('invalid-module-version')
    return escape(path) + '/@v/' + escape(version)


def sums(source):
    result = {}
    for line in read_input(source / 'go.sum', 4194304).decode().splitlines():
        fields = line.split()
        if len(fields) != 3 or not re.fullmatch(r'h1:[A-Za-z0-9+/]{43}=', fields[2]):
            raise SourceError('invalid-source-go-sum')
        name, version, checksum = fields
        identity(name, version.removesuffix('/go.mod'))
        key = (name, version)
        if key in result and result[key] != checksum:
            raise SourceError('ambiguous-source-go-sum')
        result[key] = checksum
        if len(result) > 8192:
            raise SourceError('module-metadata-count-limit')
    return result


def mod_sum(data):
    line = hashlib.sha256(data).hexdigest().encode() + b'  go.mod\n'
    return 'h1:' + base64.b64encode(hashlib.sha256(line).digest()).decode()


def binary_manifest(source, binary):
    with tempfile.TemporaryDirectory(prefix='loki-module-notices-') as work:
        subprocess.run([sys.executable, '-B', str(HERE / 'notices.py'), str(source),
                        str(binary), work], cwd=source, env=ENV, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
        manifest = json.loads(read_input(Path(work) / 'build-info.json', 4194304))
    return manifest


def info_bytes(path, version, required):
    try:
        info = json.loads(read_input(path, METADATA_LIMIT))
    except FileNotFoundError:
        if required:
            raise SourceError('required-module-info-unavailable') from None
        return None
    timestamp = info.get('Time') if isinstance(info, dict) else None
    if (not isinstance(info, dict) or info.get('Version') != version or
            not isinstance(timestamp, str) or not re.fullmatch(
                r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})', timestamp)):
        raise SourceError('module-info-mismatch')
    try:
        datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
    except ValueError:
        raise SourceError('module-info-time-invalid') from None
    return (json.dumps({'Version': version, 'Time': timestamp}, sort_keys=True) + '\n').encode()


def output_directory(output):
    parent = output.parent
    if parent.resolve(strict=True) != parent:
        raise SourceError('unsafe-output-directory')
    for path in (parent, *parent.parents):
        info = path.lstat()
        sticky_root = info.st_uid == 0 and info.st_mode & stat.S_ISVTX
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.getuid()) or
                (info.st_mode & 0o022 and not sticky_root)):
            raise SourceError('unsafe-output-directory')
    if output.exists() or output.is_symlink():
        raise SourceError('output-already-exists')


def add_bytes(archive, name, data, entries):
    info = tarfile.TarInfo(name)
    info.size, info.mode = len(data), 0o644
    archive.addfile(info, io.BytesIO(data))
    entries.append({'path': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()})


def add_zip(archive, name, path, expected, entries):
    with input_file(path, ZIP_LIMIT, expected) as (stream, before):
        digest, count = hashlib.sha256(), 0
        while block := stream.read(131072):
            count += len(block)
            if count > ZIP_LIMIT:
                raise SourceError('module-zip-byte-limit')
            digest.update(block)
        if count != before.st_size:
            raise SourceError('module-zip-size-changed')
        stream.seek(0)
        info = tarfile.TarInfo(name)
        info.size, info.mode = count, 0o644
        archive.addfile(info, stream)
        entries.append({'path': name, 'size': count, 'sha256': digest.hexdigest()})


def collect(source, binaries, output):
    source, output = Path(source).resolve(strict=True), Path(output).absolute()
    output_directory(output)
    if not binaries:
        raise SourceError('binary-required')
    before = source_receipt(source)
    toolchain = json.loads(go(source, 'env', '-json', 'GOMODCACHE', 'GOVERSION'))
    cache = Path(toolchain['GOMODCACHE']).resolve(strict=True)
    manifests = [binary_manifest(source, Path(binary).resolve(strict=True)) for binary in binaries]
    modules = {}
    binary_hashes = set()
    for manifest in manifests:
        if (manifest['unresolved'] or manifest['source_tree'] != before or
                manifest['go_version'] != toolchain['GOVERSION']):
            raise SourceError('binary-source-toolchain-mismatch')
        if manifest['binary_sha256'] in binary_hashes:
            raise SourceError('duplicate-binary-profile')
        binary_hashes.add(manifest['binary_sha256'])
        for module in manifest['modules']:
            name = module_name(module['path'])
            if name in modules and modules[name] != module:
                raise SourceError('binary-module-graph-conflict')
            modules[name] = module
    checksums = sums(source)
    required, snapshots = {}, {}
    total = 0
    for name, module in sorted(modules.items()):
        if module['replacement']:
            continue  # Local replacements are part of the separately bound core source tree.
        version, checksum = module['version'], module['sum']
        leaf = identity(name, version)
        if checksums.get((name, version)) != checksum or (name, version + '/go.mod') not in checksums:
            raise SourceError('module-not-bound-to-source-sums')
        zip_path = cache / 'cache/download' / (leaf + '.zip')
        hash_path = cache / 'cache/download' / (leaf + '.ziphash')
        snapshots[zip_path] = signature(input_stat(zip_path, ZIP_LIMIT))
        snapshots[hash_path] = signature(input_stat(hash_path, 256))
        if read_input(hash_path, 256, snapshots[hash_path]).decode().strip() != checksum:
            raise SourceError('cached-module-hash-mismatch')
        total += zip_path.stat().st_size
        if total > ZIP_LIMIT:
            raise SourceError('module-zip-total-limit')
        required[(name, version)] = leaf
    go(source, 'mod', 'verify')
    for path, expected in snapshots.items():
        if signature(input_stat(path, ZIP_LIMIT)) != expected:
            raise SourceError('input-changed-since-verification')
    if source_receipt(source) != before:
        raise SourceError('prepared-source-changed')
    xnet = modules.get('golang.org/x/net')
    if not xnet or xnet['version'] != 'v0.57.0' or xnet['replacement']:
        raise SourceError('unreviewed-publicsuffix-module')
    table = cache / (escape('golang.org/x/net') + '@v0.57.0/publicsuffix/table.go')
    if ('git revision ' + PSL_REVISION).encode() not in read_input(table, METADATA_LIMIT):
        raise SourceError('publicsuffix-revision-mismatch')
    entries, metadata, metadata_bytes = [], [], 0
    fd, temporary = tempfile.mkstemp(prefix='.loki-module-sources-', dir=output.parent)
    try:
        with os.fdopen(fd, 'wb') as raw:
            with gzip.GzipFile(filename='', mode='wb', fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode='w|') as archive:
                    for (name, version), checksum in sorted(checksums.items()):
                        if not version.endswith('/go.mod'):
                            continue
                        version = version.removesuffix('/go.mod')
                        leaf = identity(name, version)
                        path = cache / 'cache/download' / (leaf + '.mod')
                        if not path.exists() and not path.is_symlink() and (name, version) not in required:
                            continue
                        data = read_input(path, METADATA_LIMIT)
                        if mod_sum(data) != checksum:
                            raise SourceError('module-go-mod-checksum-mismatch')
                        # Lazy graph nodes can have a verified .mod without a downloaded .info.
                        info = info_bytes(path.with_suffix('.info'), version, (name, version) in required)
                        metadata_bytes += len(data) + (len(info) if info is not None else 0)
                        if metadata_bytes > METADATA_TOTAL_LIMIT:
                            raise SourceError('module-metadata-total-limit')
                        prefix = 'modules/cache/download/' + leaf
                        add_bytes(archive, prefix + '.mod', data, entries)
                        if info is not None:
                            add_bytes(archive, prefix + '.info', info, entries)
                        metadata.append({'path': name, 'version': version, 'go_mod_sum': checksum})
                        if (name, version) in required:
                            zip_path = path.with_suffix('.zip')
                            add_zip(archive, prefix + '.zip', zip_path, snapshots[zip_path], entries)
                            add_bytes(archive, prefix + '.ziphash', (modules[name]['sum'] + '\n').encode(), entries)
                    for name, checksum in sorted(EXTRA.items()):
                        data = read_input(HERE / 'source-data' / name, METADATA_LIMIT)
                        if hashlib.sha256(data).hexdigest() != checksum:
                            raise SourceError('extra-source-checksum-mismatch')
                        add_bytes(archive, 'source-data/publicsuffix/' + name, data, entries)
                    result = {'schema': 1, 'scope': 'Go module sources and pinned PSL; not a complete license audit.',
                              'go_version': toolchain['GOVERSION'], 'source_tree': before,
                              'binaries': sorted([{'sha256': m['binary_sha256'], 'settings': m['settings']} for m in manifests], key=lambda m: m['sha256']),
                              'modules': sorted(modules.values(), key=lambda m: m['path']),
                              'module_metadata': metadata, 'publicsuffix_revision': PSL_REVISION,
                              'entries': entries}
                    add_bytes(archive, 'SOURCES.json', (json.dumps(result, sort_keys=True, indent=2) + '\n').encode(), [])
            raw.flush()
            os.fsync(raw.fileno())
        if source_receipt(source) != before:
            raise SourceError('prepared-source-changed')
        os.chmod(temporary, 0o644)
        os.link(temporary, output)
        return result
    finally:
        os.unlink(temporary)


def verify_archive(path, source_tree, binaries):
    """Check a local source asset against already verified package notice inventories."""
    actual, payloads, total, metadata_bytes = {}, {}, 0, 0
    with input_file(path, ZIP_LIMIT) as (stream, _):
        with tarfile.open(fileobj=stream, mode='r|gz') as archive:
            for member in archive:
                if (not member.isfile() or member.name in actual or member.size < 0 or
                        member.mode != 0o644 or member.uid or member.gid or member.mtime or
                        member.size > (ZIP_LIMIT if member.name.endswith('.zip') else 4194304)):
                    raise SourceError('invalid-source-archive-member')
                total += member.size
                if not member.name.endswith('.zip'):
                    metadata_bytes += member.size
                if metadata_bytes > METADATA_TOTAL_LIMIT + 8388608:
                    raise SourceError('source-archive-metadata-limit')
                if total > ZIP_LIMIT + METADATA_TOTAL_LIMIT + 8388608 or len(actual) >= 20000:
                    raise SourceError('source-archive-resource-limit')
                digest, data = hashlib.sha256(), bytearray()
                with archive.extractfile(member) as content:
                    while block := content.read(131072):
                        digest.update(block)
                        if not member.name.endswith('.zip'):
                            data.extend(block)
                actual[member.name] = {'path': member.name, 'size': member.size, 'sha256': digest.hexdigest()}
                if not member.name.endswith('.zip'):
                    payloads[member.name] = bytes(data)
    manifest = json.loads(payloads.pop('SOURCES.json'))
    actual.pop('SOURCES.json')
    modules = {}
    for binary in binaries:
        for module in binary['modules']:
            if module['path'] in modules and modules[module['path']] != module:
                raise SourceError('binary-module-graph-conflict')
            modules[module['path']] = module
    profiles = sorted([{'sha256': b['binary_sha256'], 'settings': b['settings']} for b in binaries],
                      key=lambda b: b['sha256'])
    if (not binaries or manifest['schema'] != 1 or manifest['source_tree'] != source_tree or
            manifest['binaries'] != profiles or any(b['go_version'] != manifest['go_version'] for b in binaries) or
            manifest['modules'] != sorted(modules.values(), key=lambda m: m['path']) or
            manifest['publicsuffix_revision'] != PSL_REVISION or
            len(manifest['entries']) != len(actual) or
            {entry['path']: entry for entry in manifest['entries']} != actual):
        raise SourceError('source-archive-binding-mismatch')
    required, optional, metadata = set(), set(), {}
    for row in manifest['module_metadata']:
        key = (row['path'], row['version'])
        leaf = 'modules/cache/download/' + identity(*key)
        if key in metadata or mod_sum(payloads[leaf + '.mod']) != row['go_mod_sum']:
            raise SourceError('source-archive-module-metadata-mismatch')
        metadata[key] = row
        required.add(leaf + '.mod')
        optional.add(leaf + '.info')
        if leaf + '.info' in payloads:
            info = json.loads(payloads[leaf + '.info'])
            if set(info) != {'Version', 'Time'} or info['Version'] != row['version']:
                raise SourceError('source-archive-module-info-mismatch')
    for module in modules.values():
        if module['replacement']:
            continue
        key = (module['path'], module['version'])
        leaf = 'modules/cache/download/' + identity(*key)
        if key not in metadata or payloads[leaf + '.ziphash'].decode().strip() != module['sum']:
            raise SourceError('source-archive-required-module-mismatch')
        required.update(leaf + suffix for suffix in ('.mod', '.info', '.zip', '.ziphash'))
    for name, checksum in EXTRA.items():
        leaf = 'source-data/publicsuffix/' + name
        required.add(leaf)
        if actual[leaf]['sha256'] != checksum:
            raise SourceError('source-archive-extra-source-mismatch')
    if not required <= actual.keys() or not actual.keys() <= required | optional:
        raise SourceError('source-archive-entry-set-mismatch')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('binaries', nargs='+', type=Path)
    args = parser.parse_args()
    try:
        collect(args.source, args.binaries, args.output)
    except SourceError as error:
        print('core-module-sources: ' + str(error), file=sys.stderr)
        raise SystemExit(2)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        print('core-module-sources: input-or-tool-check-failed', file=sys.stderr)
        raise SystemExit(2)
