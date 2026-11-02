"""Record the current schema boundary against trusted, pre-verified Linux binaries.

Usage: python3 core/tests/compatibility.py REFERENCE_R3 STOCK_BINARY_DIR OUTPUT_DIR
The directory holds each sing-box-VERSION and its official archive filename;
archives match the pinned official release digests in compatibility_releases.json.
This checks known schema boundaries and one limited manual profile, not full stock support.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
REFERENCE_VERSION = re.search(r'^CORE_VERSION=(.+)$', (ROOT / 'core/upstream.env').read_text(), re.M)[1]
RELEASES = json.loads((ROOT / 'core/tests/compatibility_releases.json').read_text())
SCHEMA_BOUNDARIES = {
    '1.12.22': {
        'manual-json': 'unknown field "timeout"',
        'manual-json-native': 'unknown field "timeout"',
        'share-link': 'unknown field "timeout"',
        'dns-fallback': 'unknown transport type: fallback',
        'subscription': 'unknown field "timeout"',
    },
    '1.13.21': {
        'manual-json': 'unknown field "timeout"',
        'manual-json-native': 'unknown field "timeout"',
        'share-link': 'unknown field "timeout"',
        'dns-fallback': 'unknown transport type: fallback',
        'subscription': 'unknown field "timeout"',
    },
    '1.14.4': {
        'manual-json': 'unknown field "unified_delay"',
        'manual-json-native': None,
        'share-link': 'unknown outbound type: parser',
        'dns-fallback': 'unknown transport type: fallback',
        'subscription': 'unknown field "providers"',
    },
}


def verify_stock_binary(directory, release):
    version = release['version']
    archive = directory / release['url'].rsplit('/', 1)[1]
    binary = directory / f'sing-box-{version}'
    with archive.open('rb') as data:
        if hashlib.file_digest(data, 'sha256').hexdigest() != release['sha256']:
            raise AssertionError(f'{version}: archive digest mismatch')
    if binary.is_symlink() or not binary.is_file():
        raise AssertionError(f'{version}: expected a regular extracted binary')
    with tarfile.open(archive) as data:
        member = data.getmember(f'sing-box-{version}-linux-amd64/sing-box')
        if not member.isfile():
            raise AssertionError(f'{version}: binary archive entry is not a regular file')
        expected = hashlib.file_digest(data.extractfile(member), 'sha256').digest()
    with binary.open('rb') as data:
        if hashlib.file_digest(data, 'sha256').digest() != expected:
            raise AssertionError(f'{version}: extracted binary differs from its verified archive')
    return binary


def assert_result(profile, version, status, output):
    if version == REFERENCE_VERSION:
        expected = None
    elif version in SCHEMA_BOUNDARIES and profile in SCHEMA_BOUNDARIES[version]:
        expected = SCHEMA_BOUNDARIES[version][profile]
    else:
        raise AssertionError(f'Uncharacterized core/profile: {version}/{profile}')
    if expected is None:
        if status != 0:
            raise AssertionError(f'{profile}/{version}: the supported schema failed: {output[:1200]}')
    elif status != 1 or expected not in output:
        raise AssertionError(f'{profile}/{version}: expected the known schema boundary, got {status}: {output[:1200]}')


def profiles(output):
    base = {
        'settings': {'config_format': 'loki', 'config_version': '2.0.0', 'dns_encryption': '0',
                     'dns_server': ['127.0.0.1'], 'bootstrap_dns_server': ['127.0.0.1'],
                     'cache_path': str(output / 'cache.db')},
        'section': [{'.name': 'main', 'action': 'connection', 'enabled': '1', 'outbound_jsons': [json.dumps({
            'type': 'socks', 'tag': 'local-socks', 'server': '127.0.0.1', 'server_port': 18080})]}],
    }
    native = json.loads(json.dumps(base))
    native['settings']['unified_delay'] = '0'
    result = {'manual-json': base, 'manual-json-native': native}
    links = json.loads(json.dumps(base))
    links['section'][0].pop('outbound_jsons')
    links['connection_link'] = [{'.name': 'link', 'section': 'main', 'name': 'Local', 'order': '0',
                                'uri': 'socks://user:synthetic-password@127.0.0.1:18080#Local'}]
    result['share-link'] = links
    dns = json.loads(json.dumps(base))
    dns['settings']['dns_server'] = ['127.0.0.1', '127.0.0.2']
    result['dns-fallback'] = dns
    subscription = json.loads(json.dumps(base))
    subscription['section'][0].pop('outbound_jsons')
    subscription['subscription_url'] = [{'.name': 'sub', 'section': 'main', 'tag': 'Local',
                                        'url': 'http://127.0.0.1:18081/sub', 'subscription_update_enabled': '0'}]
    result['subscription'] = subscription
    return result


def main(reference, directory, output):
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    cores = {REFERENCE_VERSION: reference}
    cores.update({release['version']: verify_stock_binary(directory, release) for release in RELEASES})
    for version, binary in cores.items():
        reply = subprocess.run([str(binary), 'version'], check=True, capture_output=True, text=True, timeout=10)
        if f'sing-box version {version}' not in reply.stdout.splitlines():
            raise AssertionError(f'Unexpected binary version: {binary}')
        (output / f'version-{version}.log').write_text(reply.stdout)
    generator = output / 'generate.uc'
    generator.write_text('let fixture=require("fixture"); let generator=require("singbox.generator"); '
                         'fixture.seed(json(getenv("FORKOP_COMPAT_FIXTURE"))); '
                         'print(sprintf("%J",generator.build({service_address:"127.0.0.1",local_prefixes:[]})));\n')
    results = []
    for profile, fixture in profiles(output).items():
        environment = {**os.environ, 'FORKOP_COMPAT_FIXTURE': json.dumps(fixture)}
        generated = subprocess.run(['ucode', '-L', str(ROOT / 'tests/fakes'), '-L', str(ROOT / 'tests/lib'),
                                    '-L', str(ROOT / 'forkop/files/usr/lib'), str(generator)], env=environment,
                                   check=True, capture_output=True, text=True, timeout=20)
        config = output / f'{profile}.json'
        json.loads(generated.stdout)
        config.write_text(generated.stdout)
        for version, binary in cores.items():
            checked = subprocess.run([str(binary), '--disable-color', 'check', '-c', str(config)],
                                     capture_output=True, text=True, timeout=20)
            message = checked.stdout + checked.stderr
            (output / f'{profile}-{version}.log').write_text(message)
            assert_result(profile, version, checked.returncode, message)
            result = {'profile': profile, 'version': version, 'status': checked.returncode}
            results.append(result)
            print(json.dumps(result), flush=True)
    (output / 'results.json').write_text(json.dumps(results, indent=2))
    print(f'{len(results)} schema boundary checks passed; only the limited manual schema is accepted by stock 1.14.4')


if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    main(*(Path(value).resolve() for value in sys.argv[1:]))
