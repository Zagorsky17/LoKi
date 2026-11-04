"""Verify a local LoKi build before uploading its package assets."""
# Modified for LoKi on 2026-11-04: verify binary-specific third-party notices.
import io
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from notices import verify_notice_bundle
from module_sources import verify_archive

if len(sys.argv) != 2:
    raise SystemExit(f'Usage: {sys.argv[0]} PACKAGE-DIRECTORY')
root = Path(sys.argv[1]).resolve()
assert root.is_dir()
assert all(p.is_file() for p in root.iterdir()), 'release output contains a build/source directory'
subprocess.run(['sha256sum', '--check', 'SHA256SUMS'], cwd=root, check=True)
app = json.loads((root / 'release.json').read_text())
core = json.loads((root / 'core-release.json').read_text())
assert app['name'] == 'loki' and core['name'] == 'loki-core'
assert app['tag'] == core['tag']
assert app['requires']['loki-core'] == core['version']
assert core['requires']['loki'] == app['version']
assert core['page'] == f"https://github.com/Zagorsky17/LoKi/releases/tag/{app['tag']}"
with tarfile.open(root / f"core-source-{core['version']}.tar.gz") as source:
    names = {name.removeprefix('./') for name in source.getnames()}
    assert 'common/dialer/resolve_connect.go' in names
    assert 'common/dialer/resolve_test.go' in names
    assert 'log/error_repeats.go' in names and 'log/error_repeats_test.go' in names
    assert 'go.mod' in names and 'go.sum' in names and 'LICENSE' in names
    assert not any(name == '.git' or name.startswith('.git/') for name in names)
    source_hash = hashlib.sha256()
    source_hooks = {}
    source_files = 0
    for member in sorted(source.getmembers(), key=lambda m: m.name.removeprefix('./')):
        if member.isdir():
            continue
        assert member.isfile(), 'core source archive contains a non-regular entry'
        name = member.name.removeprefix('./')
        body = source.extractfile(member).read()
        source_hash.update(name.encode() + b'\0' + hashlib.sha256(body).digest())
        if name == 'release/config/openwrt.postinst':
            source_hooks.update({'post-install': body.decode(), 'post-upgrade': body.decode()})
        elif name == 'release/config/openwrt.prerm':
            source_hooks['pre-deinstall'] = body.decode()
        source_files += 1
    source_receipt = {'sha256': source_hash.hexdigest(), 'files': source_files}

packages = sorted(root.glob('loki-core_*.ipk'))
assert packages, 'no core packages'
native = None
binary_inventories = {}
legacy_paths = ('usr/bin/sing-box', 'etc/config/sing-box', 'etc/init.d/sing-box', 'etc/sing-box',
                'usr/share/sing-box', 'usr/share/sing-box-forkop', 'usr/share/licenses/sing-box',
                'lib/upgrade/keep.d/sing-box')
for package in packages:
    _, version, variant, architecture = package.stem.split('_', 3)
    assert version == core['version']
    with tarfile.open(package) as outer:
        outer_members = {m.name.removeprefix('./'): m for m in outer.getmembers()}
        control = tarfile.open(fileobj=io.BytesIO(outer.extractfile(outer_members['control.tar.gz']).read()))
        data = tarfile.open(fileobj=io.BytesIO(outer.extractfile(outer_members['data.tar.gz']).read()))
        control_members = {m.name.removeprefix('./'): m for m in control.getmembers()}
        fields = control.extractfile(control_members['control']).read().decode()
        assert 'Package: loki-core\n' in fields
        assert not re.search(r'^(Provides|Conflicts|Replaces):', fields, re.M), 'foreign package replacement metadata'
        assert control.extractfile(control_members['prerm']).read().decode() == source_hooks['pre-deinstall']
        assert f'Version: {version}\n' in fields
        assert f'Architecture: {architecture}\n' in fields
        assert 'Maintainer: Zagorsky17\n' in fields
        members = {m.name.removeprefix('./'): m for m in data.getmembers()}
        assert {'usr/bin/loki-core', 'etc/init.d/loki-core', 'etc/config/loki-core',
                'etc/loki-core/config.json', 'lib/upgrade/keep.d/loki-core'} <= set(members)
        for config in ('etc/config/loki-core', 'etc/loki-core/config.json'):
            assert members[config].mode == 0o600, 'core credential storage must be private'
        assert not any(name == old or name.startswith(old + '/') for name in members for old in legacy_paths)
        assert all(m.uid == 0 and m.gid == 0 for m in members.values()), 'non-root package ownership'
        assert data.extractfile(members['usr/share/loki-core/version']).read().decode().strip() == version
        assert data.extractfile(members['usr/share/loki-core/variant']).read().decode().strip() == variant
        license_text = data.extractfile(members['usr/share/licenses/loki-core/LICENSE']).read().decode()
        assert 'Copyright (C) 2022 by nekohasekai' in license_text
        assert 'In addition, no derivative work' in license_text
        assert '29 June 2007' in license_text
        binary = data.extractfile(members['usr/bin/loki-core']).read()
        notice_info = json.loads(data.extractfile(members['usr/share/licenses/loki-core/build-info.json']).read())
        notices = data.extractfile(members['usr/share/licenses/loki-core/THIRD_PARTY_NOTICES']).read()
        with tempfile.TemporaryDirectory() as work:
            metadata_binary = Path(work) / 'core'
            metadata_binary.write_bytes(binary)
            build_info = json.loads(subprocess.check_output(
                ['go', 'version', '-m', '-json', str(metadata_binary)], text=True))
        verify_notice_bundle(notice_info, notices, binary, source_receipt, build_info)
        binary_inventories[notice_info['binary_sha256']] = notice_info
        for name in ('build-info.json', 'THIRD_PARTY_NOTICES'):
            assert members['usr/share/licenses/loki-core/' + name].mode == 0o644
        assert binary[:4] == b'\x7fELF'
        machine = int.from_bytes(binary[18:20], 'little' if binary[5] == 1 else 'big')
        if architecture == 'x86_64':
            assert machine == 62
            if platform.machine() in ('x86_64', 'amd64') and variant == 'base':
                native = binary
        elif architecture.startswith('aarch64_'):
            assert machine == 183
    apk = package.with_suffix('.apk')
    assert apk.is_file(), f'missing APK for {package.name}'
    metadata = subprocess.check_output(['apk', 'adbdump', str(apk)], text=True)
    assert re.search(r'^  version: ' + re.escape(version) + r'$', metadata, re.M)
    assert re.search(r'^  arch: ' + re.escape(architecture) + r'$', metadata, re.M)
    assert re.search(r'^  maintainer: Zagorsky17$', metadata, re.M)
    package_info = json.loads(subprocess.check_output(['apk', 'adbdump', '--format', 'json', str(apk)], text=True))
    info = package_info['info']
    assert info['name'] == 'loki-core' and info['origin'] == 'loki-core'
    assert not info.get('provides') and not info.get('replaces') and not info.get('provider-priority'), 'foreign APK replacement metadata'
    assert all(not item.startswith('!') for item in info['depends'])
    assert package_info['scripts'] == source_hooks, 'APK hooks differ from the reviewed core source'
    owners = re.findall(r'^\s+(?:user|group): (\S+)$', metadata, re.M)
    assert owners and all(value == 'root' for value in owners)
    with tempfile.TemporaryDirectory() as extracted:
        subprocess.run(['apk', 'extract', '--allow-untrusted', '--no-chown', '--destination', extracted, str(apk)],
                       check=True, capture_output=True)
        tree = Path(extracted)
        assert not any((tree / old).exists() or (tree / old).is_symlink() for old in legacy_paths)
        assert (tree / 'usr/bin/loki-core').read_bytes() == binary, 'IPK/APK binary mismatch'
        for config in ('etc/config/loki-core', 'etc/loki-core/config.json'):
            assert (tree / config).stat().st_mode & 0o777 == 0o600
        for name, expected in [('build-info.json', json.dumps(notice_info, sort_keys=True, indent=2).encode() + b'\n'),
                               ('THIRD_PARTY_NOTICES', notices)]:
            notice_file = tree / 'usr/share/licenses/loki-core' / name
            assert notice_file.read_bytes() == expected, 'IPK/APK notice mismatch'
            assert notice_file.stat().st_mode & 0o777 == 0o644

covered = set()
source_assets = sorted(root.glob(f"core-module-sources-{core['version']}-*.tar.gz"))
assert source_assets, 'no offline Go module sources'
for asset in source_assets:
    with asset.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    assert asset.name == f"core-module-sources-{core['version']}-{digest}.tar.gz"
    with tarfile.open(asset) as archive:
        member = archive.getmember('SOURCES.json')
        assert member.isfile() and member.size <= 4194304
        manifest = json.loads(archive.extractfile(member).read())
    hashes = [profile['sha256'] for profile in manifest['binaries']]
    assert hashes and len(set(hashes)) == len(hashes) and set(hashes) <= binary_inventories.keys()
    verify_archive(asset, source_receipt, [binary_inventories[h] for h in hashes])
    covered.update(hashes)
assert covered == binary_inventories.keys(), 'package profiles are missing their module source assets'

if native is not None:
    with tempfile.TemporaryDirectory() as work:
        executable = Path(work) / 'loki-core'
        executable.write_bytes(native)
        executable.chmod(0o755)
        version = subprocess.check_output([str(executable), 'version'], text=True)
        assert f"sing-box version {core['version']}\n" in version
        assert 'with_clash_api' in version
        print(version.splitlines()[0])
print(f'{len(packages)} core IPK/APK pairs verified; manifests, ownership, licenses and architectures match.')
