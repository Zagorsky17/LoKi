"""Check source integrity and the installer's core manifest without running installation."""
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
                 'core-source-1.14.4-r3.tar.gz'})
            self.assertEqual(json.loads((output / 'core-release.json').read_text())['tag'], '2.0.0')
            subprocess.run(['sha256sum', '--check', 'SHA256SUMS'], cwd=output, check=True, capture_output=True)

    def test_only_packages_and_manifests_are_published_as_build_outputs(self):
        self.build_case()

    def test_a_binary_only_build_is_not_a_package_release(self):
        self.build_case(binary_only=True)

    def manifest_case(self, core=True, missing=False, mirror=False):
        with tempfile.TemporaryDirectory() as work:
            work = Path(work)
            manifest = {'schema': 1, 'name': 'sing-box-forkop' if core else 'forkop',
                        'version': '1.14.4-r3', 'tag': '2.0.0', 'requires': {'forkop': '2.0.0'}}
            (work / 'manifest.json').write_text(json.dumps(manifest))
            assets = [{'name': 'release.json', 'url': 'https://api.github.com/app-manifest'}]
            if not missing:
                assets.append({'name': 'core-release.json', 'url': 'https://api.github.com/core-manifest'})
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
            functions = '\n'.join(shell_function(name) for name in ('release_url', 'asset_url', 'read_manifest', 'fetch_release'))
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
        https://api.github.com/core-manifest|https://mirror.test/Zagorsky17/LoKi/releases/latest/download/core-release.json) cp "$WORK/manifest.json" "$2" ;;
        *) return 2 ;;
    esac
}
fetch_release core
printf '%s %s %s\n' "$C_VERSION" "$C_TAG" "$C_FORKOP_MIN"
'''
            result = subprocess.run(['busybox', 'ash', '-c', script],
                env=dict(os.environ, WORK=str(work), USE_MIRROR='yes' if mirror else 'no',
                         PATH=str(binary) + os.pathsep + os.environ['PATH']), capture_output=True, text=True)
            downloads = (work / 'downloads').read_text().splitlines()
            self.assertFalse(any('ushan0v' in url or url.endswith('/app-manifest') for url in downloads))
            return result

    def test_core_uses_its_manifest_from_the_project_repository(self):
        for mirror in (False, True):
            with self.subTest(mirror=mirror):
                result = self.manifest_case(mirror=mirror)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), '1.14.4-r3 2.0.0 2.0.0')

    def test_application_manifest_is_not_accepted_as_a_core_manifest(self):
        self.assertNotEqual(self.manifest_case(core=False).returncode, 0)

    def test_missing_core_manifest_does_not_fall_back_to_application_or_upstream(self):
        self.assertNotEqual(self.manifest_case(missing=True).returncode, 0)


if __name__ == '__main__':
    unittest.main()
