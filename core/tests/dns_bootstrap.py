#!/usr/bin/env python3
"""Verify bootstrap DNS timing against a real core using loopback-only peers."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import socket
import socketserver
import ssl
import struct
import subprocess
import sys
import threading
import time

if len(sys.argv) != 3:
    raise SystemExit(f'Usage: {sys.argv[0]} CORE-BINARY OUTPUT-DIRECTORY')
ROOT = Path(__file__).resolve().parents[2]
CORE = Path(sys.argv[1]).resolve()
WORK = Path(sys.argv[2]).resolve()
WORK.mkdir(parents=True, exist_ok=True, mode=0o700)
CERT, KEY = WORK / 'localhost.crt', WORK / 'localhost.key'
BAD_CERT, BAD_KEY = WORK / 'untrusted.crt', WORK / 'untrusted.key'
QUERY = struct.pack('!HHHHHH', 1234, 0x0100, 1, 0, 0, 0) + b'\x06target\x04test\x00' + struct.pack('!HH', 1, 1)

def exact(conn, size):
    result = b''
    while len(result) < size:
        part = conn.recv(size - len(result))
        if not part:
            raise EOFError('peer closed')
        result += part
    return result

def answer(query, modes):
    end = 12
    while query[end]:
        end += query[end] + 1
    end += 5
    kind = struct.unpack('!H', query[end - 4:end - 2])[0]
    mode = modes.get(kind, 'empty')
    if mode == 'delayed':
        time.sleep(.1)
        mode = 'good'
    if mode == 'silent':
        return None, kind
    record = b''
    if mode == 'good':
        address = socket.inet_pton(socket.AF_INET if kind == 1 else socket.AF_INET6,
                                   '127.0.0.1' if kind == 1 else '::1')
        record = b'\xc0\x0c' + struct.pack('!HHIH', kind, 1, 0, len(address)) + address
    return (query[:2] + struct.pack('!HHHHH', 0x8180, 1, int(bool(record)), 0, 0)
            + query[12:end] + record), kind

class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        query, sock = self.request
        if b'\x06target\x04test\x00' in query:
            self.server.client_leak = True
            return
        response, kind = answer(query, self.server.modes)
        self.server.queries.append(kind)
        if response is not None:
            sock.sendto(response, self.client_address)

class TCP(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    def handle_error(self, request, address):
        pass

class TCP6(TCP):
    address_family = socket.AF_INET6

class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(6)
        data = b''
        while not data.endswith(b'\r\n\r\n') and len(data) < 4096:
            data += exact(self.request, 1)
        assert data.startswith(b'CONNECT target.test:443 '), data
        self.server.accepted.append(self.server.address_family)
        self.request.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
        while True:
            data = self.request.recv(1024)
            if not data:
                return
            self.request.sendall(data)

class TLS(TCP):
    def get_request(self):
        conn, address = super().get_request()
        conn.settimeout(6)
        try:
            return self.tls.wrap_socket(conn, server_side=True), address
        except Exception:
            conn.close()
            raise

class TLSHandler(socketserver.BaseRequestHandler):
    def handle(self):
        size = struct.unpack('!H', exact(self.request, 2))[0]
        response, kind = answer(exact(self.request, size), {1: 'good', 28: 'good'})
        self.server.queries.append(kind)
        self.request.sendall(struct.pack('!H', len(response)) + response)

class HTTPSHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        response, kind = answer(self.rfile.read(int(self.headers['Content-Length'])), {1: 'good', 28: 'good'})
        self.server.queries.append(kind)
        self.send_response(200)
        self.send_header('Content-Type', 'application/dns-message')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response)
    def log_message(self, *args):
        pass

def serve(stack, server):
    threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .02}, daemon=True).start()
    stack.callback(server.server_close)
    stack.callback(server.shutdown)
    return server

def port(kind):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def generated(strategy, bootstrap, proxy_port, dns_port, protocol):
    fixture = {'settings': {
        'dns_encryption': '1', 'dns_encrypted_protocol': protocol,
        'dns_server': [f'{protocol}://dns.test:{dns_port}' + ('/dns-query' if protocol == 'https' else '')],
        'bootstrap_dns_server': [f'127.0.0.1:{bootstrap}'],
        'dns_strategy': strategy, 'dns_timeout': '2s',
    }, 'section': [{'.name': 'proxy', 'enabled': '1', 'action': 'connection',
                   'destinations': 'target.test',
                   'outbound_jsons': [json.dumps({'type': 'http', 'tag': 'Node',
                       'server': 'proxy.test', 'server_port': proxy_port})]}]}
    env = dict(os.environ, DNS_FIXTURE=json.dumps(fixture))
    result = subprocess.run(['ucode', '-L', 'tests/fakes', '-L', 'tests/lib', '-L',
        'forkop/files/usr/lib', str(WORK / 'generate.uc')], cwd=ROOT, env=env,
        capture_output=True, text=True, check=True)
    product = json.loads(result.stdout)
    assert product['route']['default_domain_resolver'] == 'bootstrap-dns-server'
    assert product['dns']['strategy'] == strategy
    dns = product['dns']
    dns['servers'] = [s for s in dns['servers'] if s['tag'] in ('dns-server', 'bootstrap-dns-server')]
    dns['rules'] = []
    dns['disable_cache'] = True
    outbound = next(o for o in product['outbounds'] if o['tag'] == 'proxy/Node')
    assert 'domain_resolver' not in outbound
    return dns, outbound, product['route']['default_domain_resolver']

def run_case(strategy, mode, path='proxy', explicit=False, literal=False):
    name = '-'.join([path, strategy, mode] + (['explicit'] if explicit else []) + (['literal'] if literal else []))
    modes = {'both': {1: 'good', 28: 'good'}, 'aaaa-silent': {1: 'good', 28: 'silent'},
             'a-silent': {1: 'silent', 28: 'good'}, 'aaaa-empty': {1: 'good', 28: 'empty'},
             'both-silent': {1: 'silent', 28: 'silent'},
             'badcert': {1: 'good', 28: 'good'},
             'main-dns-failure': {1: 'good', 28: 'good'},
             'ipv4-refused-ipv6-late': {1: 'good', 28: 'delayed'}}[mode]
    with contextlib.ExitStack() as stack:
        bootstrap = socketserver.ThreadingUDPServer(('127.0.0.1', 0), UDPHandler)
        bootstrap.modes, bootstrap.queries = modes, []
        bootstrap.client_leak = False
        serve(stack, bootstrap)
        main = TLS(('127.0.0.1', 0), HTTPSHandler if path != 'tls' else TLSHandler)
        main.queries = []
        main.tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        main.tls.load_cert_chain(BAD_CERT if mode == 'badcert' else CERT,
                                 BAD_KEY if mode == 'badcert' else KEY)
        serve(stack, main)
        proxy = TCP(('127.0.0.1', 0), ProxyHandler)
        proxy.accepted = []
        serve(stack, proxy)
        proxy6 = TCP6(('::1', proxy.server_address[1]), ProxyHandler)
        proxy6.accepted = proxy.accepted
        serve(stack, proxy6)
        if mode == 'ipv4-refused-ipv6-late':
            proxy.shutdown()
            proxy.server_close()
        dns, outbound, resolver = generated(strategy, bootstrap.server_address[1], proxy.server_address[1], main.server_address[1], 'tls' if path == 'tls' else 'https')
        next(s for s in dns['servers'] if s['tag'] == 'dns-server')['tls'] = {
            'certificate_path': str(CERT), 'server_name': '127.0.0.1'}
        inbound_port = port(socket.SOCK_STREAM if path == 'proxy' else socket.SOCK_DGRAM)
        if explicit:
            outbound['domain_resolver'] = {'server': resolver, 'strategy': 'ipv4_only'}
        if literal:
            outbound['server'] = '127.0.0.1'
        if path == 'proxy':
            inbound = {'type': 'socks', 'tag': 'probe', 'listen': '127.0.0.1', 'listen_port': inbound_port}
        else:
            inbound = {'type': 'direct', 'tag': 'probe', 'listen': '127.0.0.1', 'listen_port': inbound_port, 'network': 'udp'}
            server = next(s for s in dns['servers'] if s['tag'] == 'dns-server')
            server['type'] = path
            server['tls'] = {'certificate_path': str(CERT), 'server_name': '127.0.0.1'}
            if explicit:
                server['domain_resolver'] = {'server': resolver, 'strategy': 'ipv4_only'}
            if literal:
                server['server'] = '127.0.0.1'
            if path == 'tls':
                server.pop('path', None)
        config = {'log': {'level': 'debug'}, 'dns': dns, 'inbounds': [inbound],
                  'outbounds': [outbound], 'route': {'default_domain_resolver': resolver,
                  'final': outbound['tag'], 'rules': [] if path == 'proxy' else [{'inbound': 'probe', 'action': 'hijack-dns'}]}}
        if mode == 'main-dns-failure':
            dns_port = port(socket.SOCK_DGRAM)
            config['inbounds'].append({'type': 'direct', 'tag': 'dns-probe', 'listen': '127.0.0.1',
                                       'listen_port': dns_port, 'network': 'udp'})
            config['route']['rules'].append({'inbound': 'dns-probe', 'action': 'hijack-dns'})
        config_file = WORK / f'{name}.json'
        config_file.write_text(json.dumps(config, indent=2) + '\n')
        check = subprocess.run([str(CORE), 'check', '-c', str(config_file)], capture_output=True, text=True)
        (WORK / f'{name}.check.log').write_text(check.stdout + check.stderr)
        assert check.returncode == 0, check.stderr
        log_file = WORK / f'{name}.log'
        with log_file.open('w') as log:
            process = subprocess.Popen([str(CORE), 'run', '-c', str(config_file)], stdout=log, stderr=log)
            try:
                for _ in range(100):
                    if 'sing-box started' in log_file.read_text():
                        break
                    assert process.poll() is None, log_file.read_text()
                    time.sleep(.02)
                else:
                    raise TimeoutError('core startup')
                if mode == 'main-dns-failure':
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as check:
                        check.settimeout(1)
                        check.sendto(QUERY, ('127.0.0.1', dns_port))
                        reply, _ = check.recvfrom(4096)
                        assert reply[3] & 15 == 0 and struct.unpack('!H', reply[6:8])[0] == 1
                success = False
                start = time.monotonic()
                if path == 'proxy':
                    with socket.create_connection(('127.0.0.1', inbound_port), timeout=6) as client:
                        client.sendall(b'\x05\x01\x00')
                        assert exact(client, 2) == b'\x05\x00'
                        client.sendall(b'\x05\x01\x00\x03\x0btarget.test\x01\xbb')
                        reply = exact(client, 4)
                        if reply[1] == 0:
                            assert reply[3] in (1, 4), reply
                            exact(client, (4 if reply[3] == 1 else 16) + 2)
                            client.sendall(b'loki-probe')
                            assert exact(client, 10) == b'loki-probe'
                            success = True
                            if mode == 'main-dns-failure':
                                main.shutdown()
                                main.server_close()
                                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as check:
                                    check.settimeout(3)
                                    check.sendto(QUERY, ('127.0.0.1', dns_port))
                                    live_start = time.monotonic()
                                    client.sendall(b'loki-live')
                                    assert exact(client, 9) == b'loki-live'
                                    assert time.monotonic() - live_start < 1
                                    try:
                                        reply, _ = check.recvfrom(4096)
                                        assert reply[3] & 15 != 0 or struct.unpack('!H', reply[6:8])[0] == 0
                                    except socket.timeout:
                                        pass
                                client.sendall(b'loki-after')
                                assert exact(client, 10) == b'loki-after'
                else:
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                        client.settimeout(6)
                        client.sendto(QUERY, ('127.0.0.1', inbound_port))
                        try:
                            reply, _ = client.recvfrom(4096)
                            success = reply[3] & 15 == 0 and struct.unpack('!H', reply[6:8])[0] == 1
                        except socket.timeout:
                            success = False
                elapsed = time.monotonic() - start
                expected = literal or mode not in ('both-silent', 'badcert')
                assert success == expected, name
                assert not bootstrap.client_leak, 'client DNS leaked to bootstrap'
                if mode == 'ipv4-refused-ipv6-late':
                    assert proxy.accepted == [socket.AF_INET6], proxy.accepted
                if path == 'proxy' and mode != 'main-dns-failure':
                    assert not main.queries, 'proxy unexpectedly used main DNS'
                else:
                    assert bool(main.queries) == expected, main.queries
                    assert set(main.queries) <= {1}, main.queries
                if literal:
                    assert not bootstrap.queries, 'literal IP unexpectedly resolved'
                elif explicit or strategy == 'ipv4_only':
                    assert set(bootstrap.queries) == {1}, bootstrap.queries
                elif strategy == 'ipv6_only':
                    assert set(bootstrap.queries) == {28}, bootstrap.queries
                else:
                    assert bootstrap.queries and set(bootstrap.queries) <= {1, 28}, bootstrap.queries
                    if expected:
                        used = 28 if proxy.accepted == [socket.AF_INET6] else 1
                        assert used in bootstrap.queries, bootstrap.queries
                    elif mode == 'both-silent':
                        assert set(bootstrap.queries) == {1, 28}, bootstrap.queries
                    else:
                        assert 1 in bootstrap.queries, bootstrap.queries
                if expected and mode != 'main-dns-failure':
                    assert elapsed < 1, (name, elapsed)
                elif mode == 'both-silent':
                    assert elapsed >= 1.7, (name, elapsed)
                result = {'case': name, 'success': success, 'elapsed_s': round(elapsed, 3),
                          'bootstrap_qtypes': bootstrap.queries, 'main_qtypes': main.queries,
                          'proxy_family': 'ipv6' if proxy.accepted == [socket.AF_INET6] else 'ipv4' if proxy.accepted == [socket.AF_INET] else None}
                print(json.dumps(result), flush=True)
                return result
            finally:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)

def main():
    openssl_config = WORK / 'openssl.cnf'
    openssl_config.write_text('''[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=localhost
[v3]
subjectAltName=IP:127.0.0.1
basicConstraints=critical,CA:TRUE
''')
    for cert, key in ((CERT, KEY), (BAD_CERT, BAD_KEY)):
        subprocess.run(['openssl', 'req', '-config', str(openssl_config), '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key),
            '-out', str(cert), '-days', '1'],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        key.chmod(0o600)
    (WORK / 'generate.uc').write_text('let fixture = require("fixture");\nlet generator = require("singbox.generator");\nfixture.seed(json(getenv("DNS_FIXTURE")));\nprint(sprintf("%J", generator.build({ service_address: "127.0.0.1" })));\n')
    results = []
    cases = [('prefer_ipv4', mode) for mode in ('both', 'aaaa-silent', 'aaaa-empty', 'a-silent', 'both-silent')]
    cases += [('prefer_ipv6', mode) for mode in ('both', 'a-silent', 'aaaa-silent')]
    cases += [('ipv4_only', 'aaaa-silent'), ('ipv6_only', 'a-silent')]
    for strategy, mode in cases:
        results.append(run_case(strategy, mode))
    results.append(run_case('prefer_ipv4', 'ipv4-refused-ipv6-late'))
    results.append(run_case('prefer_ipv4', 'main-dns-failure'))
    results.append(run_case('prefer_ipv6', 'aaaa-silent', explicit=True))
    results.append(run_case('prefer_ipv4', 'both-silent', literal=True))
    for path in ('https', 'tls'):
        results.append(run_case('prefer_ipv4', 'both', path))
        results.append(run_case('prefer_ipv4', 'aaaa-silent', path))
        results.append(run_case('prefer_ipv4', 'aaaa-silent', path, explicit=True))
        results.append(run_case('prefer_ipv4', 'both-silent', path, literal=True))
        results.append(run_case('prefer_ipv4', 'badcert', path))
    (WORK / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    assert len(results) == 24
    print('24 bootstrap DNS scenarios passed.')

if __name__ == '__main__':
    main()
