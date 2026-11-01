"""Verify a local LoKi build before uploading its package assets."""
import io
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tarfile
import tempfile

if len(sys.argv) != 2:
    raise SystemExit(f'Usage: {sys.argv[0]} PACKAGE-DIRECTORY')
root = Path(sys.argv[1]).resolve()
assert root.is_dir()
assert all(p.is_file() for p in root.iterdir()), 'release output contains a build/source directory'
subprocess.run(['sha256sum', '--check', 'SHA256SUMS'], cwd=root, check=True)
app = json.loads((root / 'release.json').read_text())
core = json.loads((root / 'core-release.json').read_text())
assert app['name'] == 'forkop' and core['name'] == 'sing-box-forkop'
assert app['tag'] == core['tag']
assert app['requires']['sing-box-forkop'] == core['version']
assert core['requires']['forkop'] == app['version']
assert core['page'] == f"https://github.com/Zagorsky17/LoKi/releases/tag/{app['tag']}"
with tarfile.open(root / f"core-source-{core['version']}.tar.gz") as source:
    names = {name.removeprefix('./') for name in source.getnames()}
    assert 'common/dialer/resolve_connect.go' in names
    assert 'common/dialer/resolve_test.go' in names
    assert 'log/error_repeats.go' in names and 'log/error_repeats_test.go' in names
    assert 'go.mod' in names and 'go.sum' in names and 'LICENSE' in names
    assert not any(name == '.git' or name.startswith('.git/') for name in names)
packages = sorted(root.glob('sing-box-forkop_*.ipk'))
assert packages, 'no core packages'
native = None
for package in packages:
    _, version, variant, architecture = package.stem.split('_', 3)
    assert version == core['version']
    with tarfile.open(package) as outer:
        outer_members = {m.name.removeprefix('./'): m for m in outer.getmembers()}
        control = tarfile.open(fileobj=io.BytesIO(outer.extractfile(outer_members['control.tar.gz']).read()))
        data = tarfile.open(fileobj=io.BytesIO(outer.extractfile(outer_members['data.tar.gz']).read()))
        control_members = {m.name.removeprefix('./'): m for m in control.getmembers()}
        fields = control.extractfile(control_members['control']).read().decode()
        assert f'Version: {version}\n' in fields
        assert f'Architecture: {architecture}\n' in fields
        assert 'Maintainer: Zagorsky17\n' in fields
        members = {m.name.removeprefix('./'): m for m in data.getmembers()}
        assert all(m.uid == 0 and m.gid == 0 for m in members.values()), 'non-root package ownership'
        assert data.extractfile(members['usr/share/sing-box-forkop/version']).read().decode().strip() == version
        assert data.extractfile(members['usr/share/sing-box-forkop/variant']).read().decode().strip() == variant
        license_text = data.extractfile(members['usr/share/licenses/sing-box/LICENSE']).read().decode()
        assert 'Copyright (C) 2022 by nekohasekai' in license_text
        assert 'In addition, no derivative work' in license_text
        assert '29 June 2007' in license_text
        binary = data.extractfile(members['usr/bin/sing-box']).read()
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
    owners = re.findall(r'^\s+(?:user|group): (\S+)$', metadata, re.M)
    assert owners and all(value == 'root' for value in owners)
if native is not None:
    with tempfile.TemporaryDirectory() as work:
        executable = Path(work) / 'sing-box'
        executable.write_bytes(native)
        executable.chmod(0o755)
        version = subprocess.check_output([str(executable), 'version'], text=True)
        assert f"sing-box version {core['version']}\n" in version
        assert 'with_clash_api' in version
        print(version.splitlines()[0])
print(f'{len(packages)} core IPK/APK pairs verified; manifests, ownership, licenses and architectures match.')
