#!/usr/bin/env python3
"""Run the real metadata resolver against synthetic loopback HTTPS releases."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import shlex
import ssl
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'install.sh').read_text().rsplit('\nmain "$@"', 1)[0]
q = shlex.quote


def main():
    boundary = subprocess.run(['/bin/sh', '-c', SOURCE + '\nunset LOKI_ENABLED\nresolves() { return 1; }\nnetwork_hint\nprintf "\\nPATH=%s\\n" "$PATH"\n'],
                              env={'PATH': '/nonexistent', 'LC_ALL': 'C'}, capture_output=True, text=True, timeout=5)
    assert boundary.returncode == 0 and boundary.stderr == '', boundary.stderr
    assert 'cannot resolve' in boundary.stdout and 'PATH=/usr/sbin:/usr/bin:/sbin:/bin' in boundary.stdout
    with tempfile.TemporaryDirectory(prefix='loki-update-check-') as tmp:
        root = Path(tmp)
        cert, key = root / 'cert.pem', root / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1', '-keyout', str(key), '-out', str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assets = {}
        hits = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                name = self.path.rsplit('/', 1)[-1]
                hits.append(name)
                data = assets.get(name)
                if data is None:
                    self.send_error(404)
                else:
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    try:
                        self.wfile.write(data)
                    except (BrokenPipeError, ssl.SSLEOFError):
                        pass

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            shim = root / 'jsonfilter'
            shim.write_text('''#!/usr/bin/env python3
import json,sys,re
args=sys.argv[1:]
try:
 d=json.load(open(args[args.index('-i')+1])) if '-i' in args else json.load(sys.stdin)
 e=args[args.index('-e')+1]
 if e.startswith('@.assets['):
  name=re.search(r'@.name="([^"]+)"',e).group(1)
  values=[a['url'] for a in d['assets'] if a.get('name')==name]
 else:
  keys=re.findall(r'[A-Za-z0-9_-]+',e[2:]); v=d
  for k in keys:v=v[k]
  values=[v]
 for v in values: print(str(v).lower() if isinstance(v,bool) else v)
except (ValueError,KeyError,TypeError,AttributeError):sys.exit(1)
''')
            shim.chmod(0o755)
            for case in ['current-apk', 'current-opkg', 'available', 'custom', 'incompatible', 'unsupported-arch', 'bad-manifest', 'nul-manifest', 'bad-core-tag', 'stock-core-version', 'bad-checksum', 'duplicate-checksum', 'missing', 'tls', 'http-source', 'busy', 'memory', 'memory-20', 'tmp-small', 'oversized']:
                work = root / case
                work.mkdir()
                events = work / 'events'
                log = work / 'install.log'
                log.write_text('existing installation log\n')
                (work / 'openwrt_release').touch()
                (work / 'variant').write_text('custom' if case == 'custom' else 'base')
                app_version = '2.0.1' if case in ['available', 'custom'] else '2.0.0'
                core_version = '1.14.4-r4' if case == 'available' else '1.14.4-r3'
                app = {'schema': 1, 'name': 'loki', 'version': app_version, 'tag': app_version, 'requires': {'loki-core': '9.0.0-r1' if case == 'incompatible' else '1.14.4-r3'}}
                if case == 'bad-manifest': app['version'] = '../synthetic-secret'
                if case == 'nul-manifest': app['version'] = '2.0.0\0evil'
                core = {'schema': 1, 'name': 'loki-core', 'version': core_version, 'tag': app_version, 'requires': {'loki': '2.0.0'}}
                if case == 'bad-core-tag': core['tag'] = 'v' + core_version
                if case == 'stock-core-version': core['version'] = '1.14.4'
                ext = 'ipk' if case == 'current-opkg' else 'apk'
                assets.clear()
                assets['release.json'] = json.dumps(app).encode()
                assets['core-release.json'] = json.dumps(core).encode()
                names = ['release.json', 'core-release.json', f'loki_{app_version}_all.{ext}', f'luci-app-loki_{app_version}_all.{ext}', f'loki-core_{core_version}_base_x86_64.{ext}']
                sums = ''.join(f'{hashlib.sha256(assets.get(n, b"package")).hexdigest()}  {n}\n' for n in names)
                if case == 'bad-checksum': sums = sums.replace(hashlib.sha256(assets['release.json']).hexdigest(), '0' * 64)
                if case == 'duplicate-checksum': sums += sums.splitlines()[0] + '\n'
                assets['SHA256SUMS'] = sums.encode()
                if case == 'missing': del assets['release.json']
                if case == 'oversized': assets['release.json'] = b'x' * (3 * 1024 * 1024)
                hits.clear()
                pm = 'opkg' if ext == 'ipk' else 'apk'
                mirror = f'https://127.0.0.1:{server.server_port}'
                if case == 'http-source': mirror = mirror.replace('https:', 'http:')
                script = SOURCE.replace('/etc/openwrt_release', str(work / 'openwrt_release')).replace('/usr/share/loki-core/variant', str(work / 'variant'))
                script = script.replace('PATH=/usr/sbin:/usr/bin:/sbin:/bin', 'PATH=' + q(str(root)) + ':/usr/sbin:/usr/bin:/sbin:/bin', 1)
                overrides = f'''
LOG={q(str(log))} MIRROR={q(mirror)} FOREIGN_CORES='' FOREIGN_CORE_FILES=''
id() {{ echo 0; }}
uci() {{ [ "$3" != loki.settings.config_version ] || echo 2.0.0; }}
detect_package_manager() {{ PM={pm}; EXT={ext}; }}
identify_system() {{ RELEASE=24.10; ARCH={'missing_arch' if case == 'unsupported-arch' else 'x86_64'}; }}
refresh_db() {{ :; }}
pkg_version() {{ case "$1" in loki|luci-app-loki) echo 2.0.0;; loki-core) echo 1.14.4-r3;; esac; }}
pkg_url() {{ echo https://github.com/Zagorsky17/LoKi; }}
file_owner() {{ :; }}
in_world() {{ return 1; }}
free_kb() {{ echo {1280 if case == 'tmp-small' else 1048576}; }}
mem_available_kb() {{ echo {1024 if case == 'memory' else 20480 if case == 'memory-20' else 1048576}; }}
date() {{ [ "${{1:-}}" != +%Y ] || {{ echo 2024; return; }}; command date "$@"; }}
pidof() {{ return {0 if case == 'busy' else 1}; }}
compare() {{ command python3 -c 'import re,sys; a,b=[tuple(map(int,re.findall(r"[0-9]+",s))) for s in sys.argv[1:]]; print("<" if a<b else ">" if a>b else "=")' "$1" "$2"; }}
apk() {{ [ "$*" != info ] || return 0; [ "$1 $2" != 'version -t' ] || {{ compare "$3" "$4"; return; }}; echo forbidden-apk >>{q(str(events))}; return 99; }}
opkg() {{ [ "$*" != list-installed ] || return 0; [ "$1" != compare-versions ] || {{ local order; order=$(compare "$2" "$4"); case "$3:$order" in =:= | '<<:<') return 0;; *) return 1;; esac; }}; echo forbidden-opkg >>{q(str(events))}; return 99; }}
ntpd() {{ echo forbidden-clock >>{q(str(events))}; return 99; }}
loki_status() {{ echo forbidden-service >>{q(str(events))}; return 99; }}
lock() {{ echo forbidden-lock >>{q(str(events))}; return 99; }}
apply() {{ echo forbidden-apply >>{q(str(events))}; return 99; }}
download_packages() {{ echo forbidden-packages >>{q(str(events))}; return 99; }}
network_hint() {{ echo loopback-test; }}
sleep() {{ [ "$1" != 1 ] || command sleep 0.05; }}
deadline() {{ shift; "$@"; }}
# Keep the real fetch and TLS verification; only trust this test's CA.
wget() {{ command wget {'--ca-certificate=' + q(str(cert)) if case != 'tls' else ''} "$@"; }}
main --check --lang en
'''
                script_path = work / 'check.sh'
                script_path.write_text(script + overrides)
                env = {**os.environ, 'PATH': str(root) + ':' + os.environ['PATH'], 'https_proxy': '', 'http_proxy': '', 'HTTPS_PROXY': '', 'HTTP_PROXY': '', 'ALL_PROXY': '', 'NO_PROXY': '127.0.0.1'}
                run = subprocess.run(['sh', str(script_path)], capture_output=True, text=True, env=env, timeout=30)
                records = [json.loads(line) for line in run.stdout.splitlines() if line.startswith('{')]
                assert len(records) == 1, (case, run.returncode, run.stdout, run.stderr)
                result = records[0]
                failures = {'incompatible': 'incompatible', 'unsupported-arch': 'unsupported_arch', 'bad-manifest': 'release', 'nul-manifest': 'release', 'bad-core-tag': 'release', 'stock-core-version': 'release', 'bad-checksum': 'checksum', 'duplicate-checksum': 'checksum', 'missing': 'release', 'tls': 'network', 'http-source': 'source', 'busy': 'locked', 'memory': 'no_memory', 'memory-20': 'no_memory', 'tmp-small': 'no_memory', 'oversized': 'network'}
                if case in failures:
                    assert run.returncode != 0 and result['success'] is False and result['reason'] == failures[case], (case, result, run.stderr)
                else:
                    assert run.returncode == 0 and result['success'] is True, (case, result, run.stderr)
                    assert result['available'] == (case in ['available', 'custom']), (case, result)
                    assert result['installed']['app'] == '2.0.0' and result['latest']['app'] == app_version, result
                if case in ['memory', 'memory-20', 'tmp-small']: assert not hits, (case, hits)
                assert not events.exists(), (case, events.read_text())
                assert log.read_text() == 'existing installation log\n', case
                assert not any(n.endswith(('.apk', '.ipk')) for n in hits), (case, hits)
                assert 'synthetic-secret' not in run.stdout + run.stderr, case
                print('PASS', case)
        finally:
            server.shutdown()
            server.server_close()
    print('20 isolated metadata-only HTTPS checks passed')


if __name__ == '__main__':
    main()
