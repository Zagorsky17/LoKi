#!/usr/bin/env python3
"""Measure synthetic Linux generation with and without the existing ucode cache."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / 'loki/files/usr/lib'
RUNS = 10


def main() -> None:
    if sys.platform != 'linux':
        raise SystemExit('Run this measurement on the Linux test server')
    ucode = shutil.which('ucode')
    if not ucode or not all(Path(tool).is_file() for tool in ['/usr/bin/time', '/usr/bin/timeout']):
        raise SystemExit('Existing ucode, GNU time and GNU timeout are required')
    for tool in ['/usr/bin/time', '/usr/bin/timeout']:
        version = subprocess.run([tool, '--version'], capture_output=True, timeout=5)
        if version.returncode or b'GNU' not in version.stdout:
            raise SystemExit(f'This measurement requires the GNU implementation of {tool}')
    env = {key: value for key, value in os.environ.items() if not key.startswith('LOKI_')}
    with tempfile.TemporaryDirectory(prefix='loki-bytecode-bench-') as temporary:
        folder = Path(temporary)
        env.update(LOKI_SOURCE_LIB=str(LIBRARY), LOKI_UCODE_BIN=ucode,
                   LOKI_BYTECODE_CACHE_DIR=str(folder / 'cache'))
        probe = folder / 'generate.uc'
        probe.write_text('''let source = getenv("LOKI_SOURCE_LIB");
let library = loadfile(source + "/core/bytecode.uc")().refresh();
if ((getenv("LOKI_BYTECODE_CACHE") == "1") == (library == source))
    die("Unexpected source/cache mode");
unshift(REQUIRE_SEARCH_PATH, library + "/*.uc");
require("fixture").seed({ settings: { dns_server: [ "127.0.0.1" ], bootstrap_dns_server: [ "127.0.0.1" ] },
    section: [ { ".name": "direct", enabled: "1", action: "bypass", destinations: "example.invalid" } ] });
print(sprintf("%J", require("singbox.generator").build({ service_address: "127.0.0.1", local_prefixes: [] })));
''')
        expected = None
        rows = []
        for mode, enabled, ttl, count in [('source', '0', '3', RUNS),
                                           ('cold_cache', '1', '3', 1),
                                           ('warm_cache', '1', '3', RUNS),
                                           ('validated_cache', '1', '0', RUNS)]:
            samples = []
            for _ in range(count):
                usage = folder / 'usage'
                started = time.perf_counter()
                result = subprocess.run([
                    '/usr/bin/timeout', '-s', 'KILL', '30', '/usr/bin/time', '-f', '%M', '-o', str(usage), ucode,
                    '-L', str(ROOT / 'tests/fakes'), '-L', str(ROOT / 'tests/lib'), str(probe)
                ], env={**env, 'LOKI_BYTECODE_CACHE': enabled,
                        'LOKI_BYTECODE_VALIDATION_TTL': ttl}, capture_output=True, timeout=35)
                elapsed_ms = (time.perf_counter() - started) * 1000
                if result.returncode:
                    raise RuntimeError(f'{mode} exited {result.returncode}: {result.stderr.decode()}')
                value = json.loads(result.stdout)
                if expected is None:
                    expected = value
                if value != expected:
                    raise RuntimeError(f'{mode} changed the generated configuration')
                samples.append({'wall_ms': round(elapsed_ms, 3),
                                'max_rss_kib': int(usage.read_text().strip())})
            rows.append({'mode': mode, 'samples': samples,
                         'median_ms': round(statistics.median(s['wall_ms'] for s in samples), 3),
                         'max_rss_kib': max(s['max_rss_kib'] for s in samples)})
        cache_files = [path for path in (folder / 'cache').rglob('*') if path.is_file()]
        modules = list(LIBRARY.rglob('*.uc'))
        print(json.dumps({'environment': 'synthetic Linux; fake UCI/ubus; no OpenWrt RAM claim',
                          'modules': len(modules), 'source_bytes': sum(p.stat().st_size for p in modules),
                          'cache_files': len(cache_files),
                          'cache_bytes': sum(p.stat().st_size for p in cache_files),
                          'output_sha256': hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest(),
                          'runs': rows}, indent=2))


if __name__ == '__main__':
    main()
