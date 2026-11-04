#!/usr/bin/env python3
# Modified for LoKi on 2026-11-04: attach reviewed notices to the actual packaged binary.
"""Copy an explicit notice map; this is not a license detector or a source archive."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


SETTINGS = {'GOOS', 'GOARCH', 'GOAMD64', 'GOARM', 'GO386', 'GOMIPS', 'GOMIPS64',
            'GOPPC64', 'GORISCV64', 'CGO_ENABLED', '-tags', '-trimpath', '-buildmode', '-compiler'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def source_receipt(source):
    result = hashlib.sha256()
    count = 0
    for path in sorted(source.rglob('*'), key=lambda p: p.relative_to(source).as_posix()):
        name = path.relative_to(source).as_posix()
        if name.split('/')[0] == '.git':
            continue
        if path.is_symlink():
            raise ValueError('Source receipt refuses symlinks')
        if path.is_file():
            result.update(name.encode() + b'\0' + hashlib.sha256(path.read_bytes()).digest())
            count += 1
    return {'sha256': result.hexdigest(), 'files': count}


def json_objects(text):
    decoder = json.JSONDecoder()
    while text.strip():
        text = text.lstrip()
        value, end = decoder.raw_decode(text)
        yield value
        text = text[end:]


def module_name(name):
    if not name or name.startswith('/') or any(part in ('', '.', '..') for part in name.split('/')):
        raise ValueError('Invalid module identity')
    if any(not (c.isascii() and (c.isalnum() or c in './_+-!')) for c in name):
        raise ValueError('Invalid module identity')
    return name


def collect(source, binary, destination):
    source, binary, destination = Path(source).resolve(), Path(binary).resolve(), Path(destination)
    reviewed = json.loads((Path(__file__).parent / 'notice-files.json').read_text())
    if reviewed['schema'] != 1:
        raise ValueError('Unsupported notice map schema')
    env = dict(os.environ, GOTOOLCHAIN='local', GOPROXY='off', GOSUMDB='off',
               GONOPROXY='none', GOWORK='off', GOENV='off', GOFLAGS='-mod=readonly')

    def go(*args):
        return subprocess.check_output(['go', *args], cwd=source, env=env, text=True)

    info = json.loads(go('version', '-m', '-json', str(binary)))
    toolchain = json.loads(go('env', '-json', 'GOROOT', 'GOMODCACHE', 'GOVERSION'))
    if (info['Path'] != 'github.com/sagernet/sing-box/cmd/sing-box' or
            info['Main']['Path'] != 'github.com/sagernet/sing-box'):
        raise ValueError('Unexpected core binary identity')
    if info['GoVersion'] != toolchain['GOVERSION'] or info['GoVersion'] != reviewed['go']['version']:
        raise ValueError('The binary needs its reviewed Go toolchain notices')
    settings = {item['Key']: item['Value'] for item in info['Settings'] if item['Key'] in SETTINGS}
    if settings.get('GOOS') != 'linux':
        raise ValueError('Expected a Linux core binary')
    modules, known, unresolved = [], [], []
    for dep in info['Deps']:
        name = module_name(dep['Path'])
        module = {'path': name, 'version': dep['Version'], 'sum': dep.get('Sum', '')}
        replacement = dep.get('Replace')
        expected = reviewed['modules'].get(name)
        if not expected or expected['version'] != dep['Version']:
            unresolved.append({'kind': 'module', 'path': name, 'version': dep['Version']})
        elif module['sum'] != expected['sum']:
            raise ValueError('Changed checksum for reviewed module: ' + name)
        elif ((replacement or {}).get('Path') != expected['replacement'] or
              (replacement or {}).get('Version', '') != ('(devel)' if expected['replacement'] else '')):
            module['replacement'] = 'unreviewed'
            unresolved.append({'kind': 'replacement', 'path': name, 'version': dep['Version']})
        else:
            module['replacement'] = expected['replacement']
            known.append(name)
        modules.append(module)
    if len({m['path'] for m in modules}) != len(modules):
        raise ValueError('Duplicate module identity')
    if settings.get('CGO_ENABLED') != '0':
        unresolved.append({'kind': 'native-components'})
    metadata = {m['Path']: m for m in json_objects(go('list', '-m', '-json', *known))} if known else {}
    output = bytearray(b'Third-party notices for this core binary. Original section bytes follow each header.\n')
    sections = []

    def append_files(origin, directory, files):
        directory = Path(directory).resolve()
        for name, expected_hash in sorted(files.items()):
            relative = Path(name)
            if relative.is_absolute() or '..' in relative.parts:
                raise ValueError('Unsafe reviewed notice path')
            path = directory / relative
            if path.is_symlink() or not path.resolve().is_relative_to(directory) or not path.is_file():
                raise ValueError('Missing or unsafe reviewed notice: ' + origin + '/' + name)
            data = path.read_bytes()
            if digest(data) != expected_hash:
                raise ValueError('Changed reviewed notice: ' + origin + '/' + name)
            output.extend(('\n===== ' + origin + ' / ' + name + ' =====\n').encode())
            sections.append({'origin': origin, 'path': name, 'offset': len(output),
                             'bytes': len(data), 'sha256': expected_hash})
            output.extend(data)
            output.extend(b'\n')

    append_files('core', source, reviewed['core'])
    append_files(info['GoVersion'], toolchain['GOROOT'], reviewed['go']['files'])
    for name in sorted(known):
        expected, module = reviewed['modules'][name], metadata.get(name)
        if not module or module.get('Version') != expected['version']:
            raise ValueError('Source metadata does not match the binary: ' + name)
        if expected['replacement']:
            replacement = module.get('Replace', {})
            directory = Path(replacement.get('Dir', '')).resolve()
            if (replacement.get('Path') != expected['replacement'] or
                    directory != (source / expected['replacement']).resolve() or
                    not directory.is_relative_to(source)):
                raise ValueError('Unexpected local replacement source: ' + name)
        else:
            directory = Path(module.get('Dir', '')).resolve()
            if module.get('Sum') != expected['sum'] or not directory.is_relative_to(Path(toolchain['GOMODCACHE']).resolve()):
                raise ValueError('Unexpected cached module source: ' + name)
        append_files(name + '@' + expected['version'], directory, expected['files'])
    manifest = {
        'schema': 1, 'binary_sha256': digest(binary.read_bytes()),
        'go_version': info['GoVersion'], 'settings': settings,
        'source_tree': source_receipt(source),
        'notice_map_sha256': digest((Path(__file__).parent / 'notice-files.json').read_bytes()),
        'modules': sorted(modules, key=lambda m: m['path']),
        'unresolved': unresolved, 'notices_sha256': digest(output), 'sections': sections,
        'scope': 'Reviewed notice map only; not a complete license or corresponding-source audit.',
    }
    if destination.is_symlink():
        raise ValueError('Refusing a symlink notice directory')
    destination.mkdir(parents=True, exist_ok=True)
    for name in ('THIRD_PARTY_NOTICES', 'build-info.json'):
        path = destination / name
        if path.exists() or path.is_symlink():
            raise ValueError('Refusing an existing notice output')
    for name, data in [('THIRD_PARTY_NOTICES', bytes(output)),
                       ('build-info.json', (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode())]:
        path = destination / name
        path.write_bytes(data)
        path.chmod(0o644)
    return manifest


def verify_notice_bundle(manifest, notices, binary, source_tree, build_info):
    reviewed_bytes = (Path(__file__).parent / 'notice-files.json').read_bytes()
    reviewed = json.loads(reviewed_bytes)
    if (manifest['schema'] != 1 or manifest['unresolved'] or
            manifest['go_version'] != reviewed['go']['version'] or
            manifest['settings'].get('CGO_ENABLED') != '0' or
            manifest['notice_map_sha256'] != digest(reviewed_bytes)):
        raise ValueError('Unreviewed dependency notices')
    if manifest['binary_sha256'] != digest(binary) or manifest['source_tree'] != source_tree:
        raise ValueError('Binary/source notice binding mismatch')
    actual_modules = []
    for dep in build_info['Deps']:
        known = reviewed['modules'].get(dep['Path'])
        replacement = dep.get('Replace') or {}
        if (not known or dep['Version'] != known['version'] or
                replacement.get('Path') != known['replacement'] or
                replacement.get('Version', '') != ('(devel)' if known['replacement'] else '')):
            raise ValueError('Unreviewed binary dependency')
        actual_modules.append({'path': dep['Path'], 'version': dep['Version'],
                               'sum': dep.get('Sum', ''), 'replacement': replacement.get('Path')})
    actual_settings = {s['Key']: s['Value'] for s in build_info['Settings'] if s['Key'] in SETTINGS}
    if (build_info['Path'] != 'github.com/sagernet/sing-box/cmd/sing-box' or
            build_info['Main']['Path'] != 'github.com/sagernet/sing-box' or
            build_info['GoVersion'] != manifest['go_version'] or actual_settings.get('GOOS') != 'linux' or
            actual_settings != manifest['settings'] or
            sorted(actual_modules, key=lambda m: m['path']) != manifest['modules'] or
            len({m['path'] for m in actual_modules}) != len(actual_modules)):
        raise ValueError('Binary build information does not match notice inventory')
    expected = {('core', p): h for p, h in reviewed['core'].items()}
    expected.update({(manifest['go_version'], p): h for p, h in reviewed['go']['files'].items()})
    for module in manifest['modules']:
        known = reviewed['modules'].get(module['path'])
        if not known or any(module.get(key) != known[key] for key in ('version', 'sum', 'replacement')):
            raise ValueError('Unreviewed dependency module')
        expected.update({(module['path'] + '@' + module['version'], p): h for p, h in known['files'].items()})
    sections = manifest['sections']
    if (manifest['notices_sha256'] != digest(notices) or len(sections) != len(expected) or
            {(s['origin'], s['path']) for s in sections} != set(expected)):
        raise ValueError('Incomplete dependency notices')
    for section in sections:
        offset, size = section['offset'], section['bytes']
        if offset < 0 or size <= 0 or offset + size > len(notices):
            raise ValueError('Invalid notice section range')
        actual = digest(notices[offset:offset + size])
        if actual != section['sha256'] or actual != expected[(section['origin'], section['path'])]:
            raise ValueError('Changed dependency notice bytes')


if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit('Usage: notices.py SOURCE-DIRECTORY BINARY NOTICE-DIRECTORY')
    collect(*sys.argv[1:])
