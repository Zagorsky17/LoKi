"""Check the prepared core's independent namespace and non-mutating install hook."""
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile


def snapshot(root):
    result = {}
    for path in root.rglob('*'):
        relative = str(path.relative_to(root))
        mode = stat.S_IMODE(path.lstat().st_mode)
        result[relative] = ('link', os.readlink(path), mode) if path.is_symlink() else (
            ('file', path.read_bytes(), mode) if path.is_file() else ('directory', mode))
    return result


def main(source):
    hook = (source / 'release/config/openwrt.postinst').read_text()
    with tempfile.TemporaryDirectory(prefix='loki-core-version-') as folder:
        folder = Path(folder)
        binary, output = folder / 'binary', folder / 'output'
        binary.write_bytes(b'synthetic binary fixture')
        for version in ('1.14.4', '1.2.3.4-r6', '1.2.3-r6+text', '1.2.3-r6+../escape'):
            done = subprocess.run(['bash', str(source / 'release/forkop/package.sh'), '--binary', str(binary),
                '--arch', 'x86_64', '--version', version, '--variant', 'base', '--output', str(output)],
                env=dict(os.environ, SOURCE_DATE_EPOCH='0'), capture_output=True, timeout=10)
            assert done.returncode == 2, f'{version}: invalid own version must refuse before packaging, got {done.returncode}'
            assert not output.exists(), version
    for kind in ('file', 'link', 'dangling-link', 'directory', 'absent', 'offline'):
        with tempfile.TemporaryDirectory(prefix='loki-core-hook-') as folder:
            folder = Path(folder)
            tree, tools = folder / 'root', folder / 'bin'
            service = tree / 'etc/init.d'
            service.mkdir(parents=True)
            tools.mkdir()
            old, new = service / 'loki-core', service / 'loki-core.apk-new'
            old.write_bytes(b'custom existing service\n')
            victim = tree / 'user-data'
            victim.write_bytes(b'foreign fixture data\n')
            if kind in ('file', 'offline'):
                new.write_bytes(b'prepared service\n')
            elif kind in ('link', 'dangling-link'):
                new.symlink_to(victim if kind == 'link' else tree / 'missing')
            elif kind == 'directory':
                new.mkdir()
            log = folder / 'logger.log'
            logger = tools / 'logger'
            logger.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$NAMESPACE_LOG"\n')
            logger.chmod(0o755)
            program = folder / 'postinst'
            program.write_text(hook.replace('/etc/', str(tree / 'etc') + '/'))
            before = snapshot(tree)
            for attempt in range(2):
                done = subprocess.run(['/bin/sh', str(program)], env=dict(os.environ,
                    PATH=str(tools) + ':/usr/bin:/bin', NAMESPACE_LOG=str(log),
                    IPKG_INSTROOT=str(tree) if kind == 'offline' else ''), capture_output=True, timeout=5)
                expected = 0 if kind in ('absent', 'offline') else 1
                assert done.returncode == expected, f'{kind}: expected refusal={expected}, got {done.returncode}'
                assert done.stdout == done.stderr == b'', kind
                assert snapshot(tree) == before, f'{kind}: foreign files or prepared service changed'
            if kind in ('absent', 'offline'):
                assert not log.exists(), kind
            else:
                assert log.read_text().splitlines() == [
                    '-t loki-core The existing service script requires review; the prepared script was preserved'] * 2
    init = (source / 'release/config/openwrt.init').read_text()
    config = (source / 'release/config/openwrt.conf').read_text()
    recipe = (source / 'release/forkop/package.sh').read_text()
    assert 'PROG="/usr/bin/loki-core"' in init
    assert 'config_load "loki-core"' in init
    assert "config loki-core 'main'" in config and "'/etc/loki-core/config.json'" in config
    assert 'PACKAGE=loki-core\n' in recipe
    for forbidden in ('Provides:', 'Conflicts:', 'Replaces:', 'provides:', 'provider-priority:',
                      '/usr/bin/sing-box', '/etc/config/sing-box', '/usr/share/licenses/sing-box/'):
        assert forbidden not in recipe, forbidden
    print('core namespace and six repeated hook cases passed')


if __name__ == '__main__':
    if sys.platform != 'linux' or len(sys.argv) != 2:
        raise SystemExit('Usage on Linux: package_namespace.py PREPARED_CORE_SOURCE')
    main(Path(sys.argv[1]))
