"""Check source integrity and the installer's core manifest without running installation."""
# Modified for LoKi on 2026-11-04: verify binary-specific third-party notices.
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = (ROOT / 'install.sh').read_text()


def shell_function(name):
    found = re.search(r'^' + name + r'\(\).*?^}\n', INSTALLER, re.M | re.S)
    if not found:
        raise AssertionError(f'Missing installer function: {name}')
    return found.group()


class ReleaseTests(unittest.TestCase):
    def test_corrupt_cached_source_is_not_extracted(self):
        commit = re.search(r'^CORE_COMMIT=(\w+)$', (ROOT / 'core/upstream.env').read_text(), re.M)[1]
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            cache = work / 'cache/loki/core'
            cache.mkdir(parents=True)
            (cache / f'{commit}.tar.gz').write_bytes(b'not the pinned source archive')
            destination = work / 'source'
            result = subprocess.run([str(ROOT / 'core/prepare.sh'), str(destination)],
                env=dict(os.environ, XDG_CACHE_HOME=str(work / 'cache')), capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(destination.exists())

    def test_prepare_does_not_overwrite_an_existing_directory_or_symlink(self):
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            existing = work / 'existing'
            existing.mkdir()
            marker = existing / 'keep'
            marker.write_text('keep')
            link = work / 'link'
            link.symlink_to(existing)
            for destination in (existing, link):
                with self.subTest(destination=destination.name):
                    result = subprocess.run([str(ROOT / 'core/prepare.sh'), str(destination)], capture_output=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(marker.read_text(), 'keep')

    def test_release_tag_is_validated_before_building(self):
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            marker, output = work / 'injected', work / 'output'
            result = subprocess.run([str(ROOT / 'core/build.sh'), f'1.2.3;touch {marker}', str(output)], capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(marker.exists())
            self.assertFalse(output.exists())

    def build_case(self, binary_only=False):
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            recipe, binary, output = work / 'recipe', work / 'bin', work / 'output'
            recipe.mkdir()
            binary.mkdir()
            for name in ('build.sh', 'upstream.env', 'GO_VERSION'):
                (recipe / name).write_bytes((ROOT / 'core' / name).read_bytes())
            (recipe / 'build.sh').chmod(0o755)
            go = binary / 'go'
            go.write_text('#!/bin/sh\nprintf "go' + (recipe / 'GO_VERSION').read_text().strip() + '\\n"\n')
            go.chmod(0o755)
            prepare = recipe / 'prepare.sh'
            prepare.write_text('''#!/bin/sh
set -eu
mkdir "$1"
cat > "$1/build.sh" <<'BUILD'
#!/bin/sh
set -eu
only=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --binary-only) only=1; shift ;;
        --output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
mkdir -p "$output/build"
printf binary > "$output/build/sing-box"
[ "$only" = 0 ] || exit 0
printf ipk > "$output/core.ipk"
printf apk > "$output/core.apk"
BUILD
chmod +x "$1/build.sh"
''')
            prepare.chmod(0o755)
            args = [str(recipe / 'build.sh'), '2.0.0', str(output)]
            if binary_only:
                args.append('--binary-only')
            result = subprocess.run(args, env=dict(os.environ,
                PATH=str(binary) + os.pathsep + os.environ['PATH']), capture_output=True, text=True)
            if binary_only:
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((output / 'core-release.json').exists())
                return
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual({p.name for p in output.iterdir()},
                {'core.ipk', 'core.apk', 'core-release.json', 'SHA256SUMS',
                 'core-source-1.14.4-r6.tar.gz'})
            self.assertEqual(json.loads((output / 'core-release.json').read_text())['tag'], '2.0.0')
            subprocess.run(['sha256sum', '--check', 'SHA256SUMS'], cwd=output, check=True, capture_output=True)

    def test_only_packages_and_manifests_are_published_as_build_outputs(self):
        self.build_case()

    def test_a_binary_only_build_is_not_a_package_release(self):
        self.build_case(binary_only=True)

    def manifest_case(self, core=True, missing=False, mirror=False, bad_url=False, bad_digest=False):
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            manifest = {'schema': 1, 'name': 'sing-box-forkop' if core else 'forkop',
                        'version': '1.14.4-r6', 'tag': '2.0.0', 'requires': {'forkop': '2.0.0'}}
            (work / 'manifest.json').write_text(json.dumps(manifest))
            digest = hashlib.sha256((work / 'manifest.json').read_bytes()).hexdigest()
            (work / 'sums').write_text(('0' * 64 if bad_digest else digest) + '  core-release.json\n')
            assets = [{'name': 'release.json', 'url': 'https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/1'},
                      {'name': 'SHA256SUMS', 'url': 'https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/3'}]
            if not missing:
                assets.append({'name': 'core-release.json', 'url': 'https://elsewhere.invalid/core-manifest' if bad_url else
                               'https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/2'})
            (work / 'listing.json').write_text(json.dumps({'assets': assets}))
            binary = work / 'bin'
            binary.mkdir()
            jsonfilter = binary / 'jsonfilter'
            jsonfilter.write_text('''#!/usr/bin/env python3
import json, re, sys
args = sys.argv[1:]
data = json.load(open(args[args.index('-i') + 1]))
expression = args[args.index('-e') + 1]
if expression.startswith('@.assets'):
    name = re.search(r'name="([^"]+)"', expression)[1]
    value = next((asset['url'] for asset in data['assets'] if asset['name'] == name), None)
else:
    value = data
    for key in expression[2:].replace('["', '.').replace('"]', '').split('.'):
        if not isinstance(value, dict) or key not in value:
            raise SystemExit(1)
        value = value[key]
if value is not None:
    print(value)
''')
            jsonfilter.chmod(0o755)
            repos = '\n'.join(re.findall(r'^(?:FORKOP_REPO|CORE_REPO)=.*$', INSTALLER, re.M))
            functions = '\n'.join(shell_function(name) for name in (
                'release_url', 'valid_mirror', 'valid_asset_url', 'asset_url', 'valid_release_version',
                'checksum_of', 'verify_named', 'fetch_or_fail', 'read_manifest', 'fetch_release'))
            script = repos + '\n' + functions + '''
API_URL=https://api.github.com
MIRROR=''
[ "$USE_MIRROR" != yes ] || MIRROR=https://mirror.test
C_TAG=''
t() { template=$1; shift 2; printf "$template" "$@"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
network_hint() { :; }
rate_limited() { exit 3; }
download() {
    printf '%s\n' "$1" >> "$WORK/downloads"
    case "$1" in
        https://api.github.com/repos/Zagorsky17/LoKi/releases/latest) cp "$WORK/listing.json" "$2" ;;
        https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/2|https://mirror.test/Zagorsky17/LoKi/releases/latest/download/core-release.json) cp "$WORK/manifest.json" "$2" ;;
        https://api.github.com/repos/Zagorsky17/LoKi/releases/assets/3|https://mirror.test/Zagorsky17/LoKi/releases/download/2.0.0/SHA256SUMS) cp "$WORK/sums" "$2" ;;
        *) return 2 ;;
    esac
}
fetch_release core
printf '%s %s %s\n' "$C_VERSION" "$C_TAG" "$C_FORKOP_MIN"
'''
            result = subprocess.run(['busybox', 'ash', '-c', script],
                env=dict(os.environ, WORK=str(work), USE_MIRROR='yes' if mirror else 'no',
                         PATH=str(binary) + os.pathsep + os.environ['PATH']), capture_output=True, text=True)
            downloads = (work / 'downloads').read_text().splitlines() if (work / 'downloads').exists() else []
            self.assertFalse(any('ushan0v' in url or url.endswith('/assets/1') or 'elsewhere.invalid' in url for url in downloads))
            return result

    def test_core_uses_its_manifest_from_the_project_repository(self):
        for mirror in (False, True):
            with self.subTest(mirror=mirror):
                result = self.manifest_case(mirror=mirror)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), '1.14.4-r6 2.0.0 2.0.0')

    def test_application_manifest_is_not_accepted_as_a_core_manifest(self):
        self.assertNotEqual(self.manifest_case(core=False).returncode, 0)

    def test_missing_core_manifest_does_not_fall_back_to_application_or_upstream(self):
        self.assertNotEqual(self.manifest_case(missing=True).returncode, 0)

    def test_manifest_source_cannot_leave_the_project_asset_namespace(self):
        self.assertNotEqual(self.manifest_case(bad_url=True).returncode, 0)

    def test_a_core_manifest_needs_its_matching_sha256(self):
        for mirror in (False, True):
            with self.subTest(mirror=mirror):
                self.assertNotEqual(self.manifest_case(mirror=mirror, bad_digest=True).returncode, 0)

class NoticeTests(unittest.TestCase):
    def setUp(self):
        import importlib.util
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('core_notices', ROOT / 'core/notices.py')
        self.notices = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.notices)
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.work = Path(self.work.name)
        self.source, self.cache, self.goroot = (self.work / name for name in ('source', 'cache', 'go'))
        self.module = self.cache / 'module@v1.2.3'
        self.local = self.source / 'third_party/local'
        for path in (self.source, self.module, self.local, self.goroot):
            path.mkdir(parents=True, exist_ok=True)
        self.binary = self.work / 'core'
        self.binary.write_bytes(b'synthetic binary')
        self.destination = self.work / 'notices'
        for path in (self.source, self.module, self.local, self.goroot):
            (path / 'LICENSE').write_bytes(b'Copyright fixture\r\nPermission fixture\n')
        self.profile = {'schema': 1, 'core': {'LICENSE': self.notices.digest((self.source / 'LICENSE').read_bytes())},
                        'go': {'version': 'go1.26.10', 'files': {'LICENSE': self.notices.digest((self.goroot / 'LICENSE').read_bytes())}},
                        'modules': {
                            'example.test/module': {'version': 'v1.2.3', 'sum': 'h1:fixture', 'replacement': None,
                                                    'files': {'LICENSE': self.notices.digest((self.module / 'LICENSE').read_bytes())}},
                            'example.test/local': {'version': 'v0.0.0', 'sum': '', 'replacement': './third_party/local',
                                                   'files': {'LICENSE': self.notices.digest((self.local / 'LICENSE').read_bytes())}},
                        }}
        self.profile_path = self.work / 'notice-files.json'
        self.profile_path.write_text(json.dumps(self.profile))
        self.info = {'GoVersion': 'go1.26.10', 'Path': 'github.com/sagernet/sing-box/cmd/sing-box',
                     'Main': {'Path': 'github.com/sagernet/sing-box'},
                     'Deps': [{'Path': 'example.test/module', 'Version': 'v1.2.3', 'Sum': 'h1:fixture'},
                              {'Path': 'example.test/local', 'Version': 'v0.0.0',
                               'Replace': {'Path': './third_party/local', 'Version': '(devel)'}}],
                     'Settings': [{'Key': 'GOOS', 'Value': 'linux'}, {'Key': 'CGO_ENABLED', 'Value': '0'},
                                  {'Key': 'CGO_CFLAGS', 'Value': '/private/builder/path'}]}
        self.metadata = [{'Path': 'example.test/module', 'Version': 'v1.2.3', 'Sum': 'h1:fixture', 'Dir': str(self.module)},
                         {'Path': 'example.test/local', 'Version': 'v0.0.0',
                          'Replace': {'Path': './third_party/local', 'Dir': str(self.local)}}]
        def go(argv, **kwargs):
            self.assertEqual(kwargs['env']['GOPROXY'], 'off')
            self.assertEqual(kwargs['env']['GOFLAGS'], '-mod=readonly')
            self.assertEqual(kwargs['env']['GOWORK'], 'off')
            if argv[1] == 'version':
                return json.dumps(self.info)
            if argv[1] == 'env':
                return json.dumps({'GOROOT': str(self.goroot), 'GOMODCACHE': str(self.cache), 'GOVERSION': 'go1.26.10'})
            self.assertEqual(argv[1:4], ['list', '-m', '-json'])
            return '\n'.join(json.dumps(m) for m in self.metadata if m['Path'] in argv[4:])
        self.patch_file = patch.object(self.notices, '__file__', str(self.work / 'notices.py'))
        self.patch_go = patch.object(self.notices.subprocess, 'check_output', go)
        self.patch_file.start()
        self.patch_go.start()
        self.addCleanup(self.patch_file.stop)
        self.addCleanup(self.patch_go.stop)

    def collect(self):
        return self.notices.collect(self.source, self.binary, self.destination)

    def verify(self, manifest):
        self.notices.verify_notice_bundle(manifest, (self.destination / 'THIRD_PARTY_NOTICES').read_bytes(),
                                          self.binary.read_bytes(), self.notices.source_receipt(self.source), self.info)

    def test_exact_notice_bytes_offsets_modes_privacy_and_source_binding(self):
        manifest = self.collect()
        self.verify(manifest)
        blob = (self.destination / 'THIRD_PARTY_NOTICES').read_bytes()
        self.assertEqual(len(manifest['sections']), 4)
        for section in manifest['sections']:
            self.assertEqual(blob[section['offset']:section['offset'] + section['bytes']], b'Copyright fixture\r\nPermission fixture\n')
        text = (self.destination / 'build-info.json').read_text()
        self.assertNotIn(str(self.work), text)
        self.assertNotIn('/private/builder/path', text)
        for name in ('THIRD_PARTY_NOTICES', 'build-info.json'):
            self.assertEqual((self.destination / name).stat().st_mode & 0o777, 0o644)
        (self.source / 'added.go').write_text('changed source')
        with self.assertRaisesRegex(ValueError, 'Binary/source'):
            self.verify(manifest)

    def test_missing_changed_and_symlinked_known_notice_refuse_before_output(self):
        license_file = self.module / 'LICENSE'
        original = license_file.read_bytes()
        for failure in ('missing', 'changed', 'symlink'):
            with self.subTest(failure=failure):
                if license_file.exists() or license_file.is_symlink():
                    license_file.unlink()
                if failure == 'changed':
                    license_file.write_bytes(b'changed')
                elif failure == 'symlink':
                    license_file.symlink_to(self.goroot / 'LICENSE')
                with self.assertRaises(ValueError):
                    self.collect()
                self.assertFalse(self.destination.exists())
        license_file.unlink()
        license_file.write_bytes(original)

    def test_unknown_module_can_build_but_cannot_pass_release_gate(self):
        self.info['Deps'].append({'Path': 'example.test/unreviewed', 'Version': 'v4.0.0', 'Sum': 'h1:other'})
        manifest = self.collect()
        self.assertEqual(manifest['unresolved'][0]['kind'], 'module')
        with self.assertRaisesRegex(ValueError, 'Unreviewed'):
            self.verify(manifest)

        manifest['unresolved'] = []
        with self.assertRaisesRegex(ValueError, 'Unreviewed'):
            self.verify(manifest)

    def test_unknown_replacement_is_private_and_cannot_bypass_release_gate(self):
        self.info['Deps'][0]['Replace'] = {'Path': str(self.work / 'private-replacement')}
        manifest = self.collect()
        self.assertNotIn(str(self.work), json.dumps(manifest))
        self.assertEqual(manifest['unresolved'][0]['kind'], 'replacement')
        manifest['unresolved'] = []
        with self.assertRaisesRegex(ValueError, 'Unreviewed'):
            self.verify(manifest)

        self.destination = self.work / 'versioned-replacement-notices'
        del self.info['Deps'][0]['Replace']
        self.info['Deps'][1]['Replace']['Version'] = 'v1.2.3'
        manifest = self.collect()
        self.assertEqual(manifest['unresolved'][0]['kind'], 'replacement')
        manifest['unresolved'] = []
        with self.assertRaisesRegex(ValueError, 'Unreviewed'):
            self.verify(manifest)

    def test_native_component_coverage_remains_unresolved(self):
        self.info['Settings'][1]['Value'] = '1'
        manifest = self.collect()
        self.assertIn({'kind': 'native-components'}, manifest['unresolved'])
        with self.assertRaisesRegex(ValueError, 'Unreviewed'):
            self.verify(manifest)

    def test_changed_module_checksum_source_identity_and_toolchain_refuse(self):
        import copy
        original_info, original_metadata = copy.deepcopy(self.info), copy.deepcopy(self.metadata)
        for failure in ('sum', 'source-version', 'cache-escape', 'replacement-escape', 'toolchain', 'identity'):
            with self.subTest(failure=failure):
                self.info, self.metadata = copy.deepcopy(original_info), copy.deepcopy(original_metadata)
                if failure == 'sum': self.info['Deps'][0]['Sum'] = 'h1:changed'
                elif failure == 'source-version': self.metadata[0]['Version'] = 'v9.0.0'
                elif failure == 'cache-escape': self.metadata[0]['Dir'] = str(self.goroot)
                elif failure == 'replacement-escape': self.metadata[1]['Replace']['Dir'] = str(self.goroot)
                elif failure == 'toolchain': self.info['GoVersion'] = 'go1.27.0'
                else: self.info['Main']['Path'] = 'example.test/not-core'
                with self.assertRaises(ValueError):
                    self.collect()
                self.assertFalse(self.destination.exists())

    def test_repeat_does_not_overwrite_existing_notice_output(self):
        self.collect()
        marker = self.destination / 'build-info.json'
        marker.write_text('preserve')
        before = (self.destination / 'THIRD_PARTY_NOTICES').read_bytes()
        with self.assertRaisesRegex(ValueError, 'existing notice output'):
            self.collect()
        self.assertEqual(marker.read_text(), 'preserve')
        self.assertEqual((self.destination / 'THIRD_PARTY_NOTICES').read_bytes(), before)

    def test_release_gate_rejects_changed_or_omitted_notice_sections(self):
        import copy
        manifest = self.collect()
        for failure in ('section', 'offset', 'hash', 'map'):
            with self.subTest(failure=failure):
                changed = copy.deepcopy(manifest)
                if failure == 'section': changed['sections'].pop()
                elif failure == 'offset': changed['sections'][0]['offset'] = -1
                elif failure == 'hash': changed['sections'][0]['sha256'] = '0' * 64
                else: changed['notice_map_sha256'] = '0' * 64
                with self.assertRaises(ValueError):
                    self.verify(changed)

    def test_release_gate_reads_binary_inventory_independently_of_manifest(self):
        import copy
        manifest = self.collect()
        for failure in ('module', 'settings', 'go-version', 'identity'):
            with self.subTest(failure=failure):
                changed = copy.deepcopy(manifest)
                if failure == 'module':
                    omitted = changed['modules'].pop()
                    changed['sections'] = [s for s in changed['sections']
                                           if s['origin'] != omitted['path'] + '@' + omitted['version']]
                elif failure == 'settings': changed['settings']['GOARCH'] = 'invented'
                elif failure == 'go-version': changed['go_version'] = 'go1.27.0'
                else: self.info['Main']['Path'] = 'example.test/not-core'
                with self.assertRaises(ValueError):
                    self.verify(changed)
        self.info['Main']['Path'] = 'github.com/sagernet/sing-box'
        self.info['Deps'].append({'Path': 'example.test/unreviewed', 'Version': 'v1.0.0'})
        with self.assertRaisesRegex(ValueError, 'Unreviewed binary dependency'):
            self.verify(manifest)

    def test_unsafe_map_path_and_output_directory_refuse(self):
        self.profile['core'] = {'../go/LICENSE': self.profile['core']['LICENSE']}
        self.profile_path.write_text(json.dumps(self.profile))
        with self.assertRaisesRegex(ValueError, 'Unsafe reviewed notice path'):
            self.collect()
        self.assertFalse(self.destination.exists())
        self.profile['core'] = {'LICENSE': self.notices.digest((self.source / 'LICENSE').read_bytes())}
        self.profile_path.write_text(json.dumps(self.profile))
        self.destination.symlink_to(self.goroot, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'symlink notice directory'):
            self.collect()
        self.assertFalse((self.goroot / 'build-info.json').exists())

    def test_duplicate_or_unsafe_module_identity_refuses(self):
        import copy
        original = copy.deepcopy(self.info['Deps'])
        for failure in ('duplicate', 'path', 'shell'):
            with self.subTest(failure=failure):
                self.info['Deps'] = copy.deepcopy(original)
                if failure == 'duplicate': self.info['Deps'].append(copy.deepcopy(original[0]))
                elif failure == 'path': self.info['Deps'][0]['Path'] = '../private/module'
                else: self.info['Deps'][0]['Path'] = 'example.test/module;touch-injected'
                with self.assertRaises(ValueError):
                    self.collect()
                self.assertFalse(self.destination.exists())

    def test_source_receipt_has_stable_archive_order_and_refuses_symlinks(self):
        (self.source / 'a').mkdir()
        (self.source / 'a/file').write_bytes(b'nested')
        (self.source / 'a.file').write_bytes(b'sibling')
        before = self.notices.source_receipt(self.source)
        archive = self.work / 'source.tar'
        import tarfile
        with tarfile.open(archive, 'w') as output:
            output.add(self.source, arcname='.')
        with tarfile.open(archive) as saved:
            checksum = hashlib.sha256()
            count = 0
            for member in sorted(saved.getmembers(), key=lambda m: m.name.removeprefix('./')):
                if not member.isfile(): continue
                checksum.update(member.name.removeprefix('./').encode() + b'\0' + hashlib.sha256(saved.extractfile(member).read()).digest())
                count += 1
        self.assertEqual(before, {'sha256': checksum.hexdigest(), 'files': count})
        (self.source / 'link').symlink_to(self.goroot / 'LICENSE')
        with self.assertRaisesRegex(ValueError, 'symlinks'):
            self.notices.source_receipt(self.source)


if __name__ == '__main__':
    unittest.main()
