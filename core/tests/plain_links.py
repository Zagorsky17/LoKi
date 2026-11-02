"""Compare generated plain links with the native parser using loopback peers only.

Usage: python3 core/tests/plain_links.py CORE OUTPUT_DIR [REFERENCE_R3]
OUTPUT_DIR must be a new directory. CORE and REFERENCE_R3 are trusted, previously
verified binaries. Stock runs need
REFERENCE_R3 for the parser control. No installed service or network rules change.
"""
import base64
import contextlib
import copy
import json
import os
from pathlib import Path
import socket
import socketserver
import ssl
import subprocess
import sys
import threading
import time
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[2]
USER, PASSWORD = 'test+user', 'synthetic:p@ss'
MARKER = b'authenticated-loopback-proxy'
AUTH = 'Basic ' + base64.b64encode(f'{USER}:{PASSWORD}'.encode()).decode()


def exact(stream, count):
    value = stream.read(count)
    if len(value) != count:
        raise EOFError('short local handshake')
    return value


def terminated(stream):
    value = b''
    while len(value) <= 1024:
        byte = exact(stream, 1)
        if byte == b'\0':
            return value.decode()
        value += byte
    raise AssertionError('oversized local handshake')


class Proxy(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(3)
        try:
            first = exact(self.rfile, 1)
            if first == b'\x05':
                methods = exact(self.rfile, exact(self.rfile, 1)[0])
                assert 2 in methods
                self.wfile.write(b'\x05\x02')
                assert exact(self.rfile, 1) == b'\x01'
                user = exact(self.rfile, exact(self.rfile, 1)[0]).decode()
                password = exact(self.rfile, exact(self.rfile, 1)[0]).decode()
                if self.server.reject_auth or (user, password) != (USER, PASSWORD):
                    self.server.rejected += 1
                    self.wfile.write(b'\x01\x01')
                    return
                self.wfile.write(b'\x01\x00')
                header = exact(self.rfile, 4)
                assert header[:3] == b'\x05\x01\x00'
                if header[3] == 1:
                    host = socket.inet_ntoa(exact(self.rfile, 4))
                elif header[3] == 3:
                    host = exact(self.rfile, exact(self.rfile, 1)[0]).decode()
                else:
                    raise AssertionError('unexpected local address family')
                port = int.from_bytes(exact(self.rfile, 2), 'big')
                self.wfile.write(b'\x05\x00\x00\x01' + b'\0' * 6)
                record = ('5', user, password, host, port)
                line = self.rfile.readline(8193)
            elif first == b'\x04':
                assert exact(self.rfile, 1) == b'\x01'
                port = int.from_bytes(exact(self.rfile, 2), 'big')
                address = exact(self.rfile, 4)
                user = terminated(self.rfile)
                host = terminated(self.rfile) if address == b'\0\0\0\x01' else socket.inet_ntoa(address)
                assert user == USER
                self.wfile.write(b'\0\x5a' + b'\0' * 6)
                record = ('4', user, '', host, port)
                line = self.rfile.readline(8193)
            else:
                line = first + self.rfile.readline(8193)
                headers = self.headers()
                if self.server.reject_auth or headers.get('proxy-authorization') != AUTH:
                    self.server.rejected += 1
                    self.wfile.write(b'HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                    return
                record = ('http', USER, PASSWORD, line.decode().strip())
                assert line.startswith(b'CONNECT '), line
                self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n')
                self.wfile.flush()
                line = self.rfile.readline(8193)
            assert line.startswith(b'GET '), line
            self.headers()
            self.server.records.append(record)
            self.wfile.write(b'HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: ' + str(len(MARKER)).encode() + b'\r\n\r\n' + MARKER)
        except (EOFError, OSError):
            pass
        except Exception as error:
            self.server.failures.append(str(error))

    def headers(self):
        result = {}
        for _ in range(64):
            line = self.rfile.readline(8193)
            if line in (b'\r\n', b'\n', b''):
                return result
            name, value = line.decode().split(':', 1)
            result[name.lower()] = value.strip()
        raise AssertionError('oversized local headers')


class Peer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(3)
        if self.tls:
            try:
                connection = self.tls.wrap_socket(connection, server_side=True)
            except OSError:
                connection.close()
                self.tls_rejected += 1
                raise
        return connection, address


class Trap(socketserver.StreamRequestHandler):
    def handle(self):
        self.server.hits += 1
        self.connection.settimeout(1)
        self.wfile.write(b'HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\nbypass')


def serve(stack, handler, tls=None, port=0):
    server = Peer(('127.0.0.1', port), handler)
    server.tls, server.records, server.failures = tls, [], []
    server.rejected, server.tls_rejected, server.hits = 0, 0, 0
    server.reject_auth = False
    threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .02}, daemon=True).start()
    stack.callback(server.server_close)
    stack.callback(server.shutdown)
    return server


def free_port():
    with socket.socket() as value:
        value.bind(('127.0.0.1', 0))
        return value.getsockname()[1]


def generate_fixture(fixture, output):
    program = output / 'generate.uc'
    program.write_text('let f=require("fixture");f.seed(json(getenv("LINK_FIXTURE")));'
                       'print(sprintf("%J",require("singbox.generator").build({service_address:"127.0.0.1",local_prefixes:[]})));\n')
    reply = subprocess.run(['ucode', '-L', str(ROOT / 'tests/fakes'), '-L', str(ROOT / 'tests/lib'),
                            '-L', str(ROOT / 'forkop/files/usr/lib'), str(program)],
                           env={**os.environ, 'LINK_FIXTURE': json.dumps(fixture)}, check=True, capture_output=True, text=True, timeout=10)
    return json.loads(reply.stdout)


def generate(uri, output):
    fixture = {'settings': {'dns_server': ['127.0.0.1'], 'bootstrap_dns_server': ['127.0.0.1'], 'unified_delay': '0'},
               'section': [{'.name': 'main', 'action': 'connection'}],
               'connection_link': [{'.name': 'link', 'section': 'main', 'name': 'Node', 'uri': uri}]}
    product = generate_fixture(fixture, output)
    outbound = next(item for item in product['outbounds'] if item['tag'] == 'main/Node')
    assert outbound['type'] != 'parser', 'the ordinary link did not become a standard outbound'
    return product, outbound


def request(port, target):
    with socket.create_connection(('127.0.0.1', port), timeout=3) as sock:
        sock.sendall(f'GET http://127.0.0.1:{target}/test HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n'.encode())
        reply = b''
        while len(reply) < 16384:
            try:
                part = sock.recv(4096)
            except ConnectionResetError:
                break
            if not part:
                break
            reply += part
        return reply


@contextlib.contextmanager
def running(binary, outbounds, final, directory, certificate):
    directory.mkdir(mode=0o700)
    port = free_port()
    config = {'log': {'level': 'error'},
              'inbounds': [{'type': 'mixed', 'tag': 'test', 'listen': '127.0.0.1', 'listen_port': port}],
              'outbounds': outbounds, 'route': {'final': final},
              'certificate': {'store': 'none'}}
    if certificate:
        config['certificate']['certificate_path'] = str(certificate)
    path = directory / 'runtime.json'
    path.write_text(json.dumps(config))
    subprocess.run([str(binary), 'check', '-c', str(path)], check=True, capture_output=True, timeout=10)
    with (directory / 'core.log').open('wb') as log:
        process = subprocess.Popen([str(binary), 'run', '-c', str(path)], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 5
            while True:
                assert process.poll() is None, 'core exited before readiness'
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=3):
                        break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise AssertionError('core did not become ready')
                    time.sleep(.02)
            yield port, process
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def run(binary, outbound, directory, target, certificate):
    with running(binary, [outbound], outbound['tag'], directory, certificate) as (port, _):
        return request(port, target)


def test_certificate(output, name):
    certificate, key = output / f'{name}.crt', output / f'{name}.key'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-keyout', str(key), '-out', str(certificate), '-subj', '/CN=127.0.0.1',
                    '-addext', 'subjectAltName=IP:127.0.0.1'], check=True, capture_output=True, timeout=20)
    key.chmod(0o600)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(certificate, key)
    return certificate, tls


def main(core, output, reference):
    output.mkdir(mode=0o700, parents=True)
    certificate, tls = test_certificate(output, 'loopback')
    with contextlib.ExitStack() as stack:
        plain = serve(stack, Proxy)
        secure = serve(stack, Proxy, tls)
        trap = serve(stack, Trap)
        records = []
        for scheme in ('http', 'https', 'socks', 'socks4', 'socks4a', 'socks5', 'socks5h', 'base64'):
            peer = secure if scheme == 'https' else plain
            auth = quote(USER, safe='') + ':' + quote(PASSWORD, safe='')
            if scheme == 'base64':
                auth = base64.b64encode(f'{USER}:{PASSWORD}'.encode()).decode()
            uri = f'{"socks" if scheme == "base64" else scheme}://{auth}@127.0.0.1:{peer.server_address[1]}'
            uri += '/custom%2Fconnect' if scheme == 'https' else ''
            uri += '#Node'
            product, converted = generate(uri, output)
            config = output / f'{scheme}-generated.json'
            config.write_text(json.dumps(product))
            subprocess.run([str(core), 'check', '-c', str(config)], check=True, capture_output=True, timeout=10)
            control = {'type': 'parser', 'tag': converted['tag'], 'link': uri}
            variants = [('parser', reference, control), ('converted-reference', reference, converted), ('converted-target', core, converted)]
            expected = None
            for label, binary, outbound in variants:
                start = len(peer.records)
                reply = run(binary, outbound, output / f'{scheme}-{label}', trap.server_address[1], certificate)
                assert reply.endswith(MARKER), f'{scheme}/{label}: local proxy traffic failed'
                assert len(peer.records) == start + 1, f'{scheme}/{label}: proxy not reached exactly once'
                actual = peer.records[-1]
                if expected is None:
                    expected = actual
                assert actual == expected, f'{scheme}/{label}: wire parameters differ from the native parser'
                assert not peer.failures, peer.failures
                records.append({'scheme': scheme, 'variant': label, 'accepted': True})
                if scheme in ('http', 'socks5', 'https'):
                    bad = copy.deepcopy(outbound)
                    if scheme != 'https':
                        if label == 'parser':
                            bad['link'] = uri.replace(quote(PASSWORD, safe=''), 'wrong-password')
                        else:
                            bad['password'] = 'wrong-password'
                    previous = len(peer.records)
                    refused = peer.tls_rejected if scheme == 'https' else peer.rejected
                    reply = run(binary, bad, output / f'{scheme}-{label}-refused', trap.server_address[1], None if scheme == 'https' else certificate)
                    assert MARKER not in reply and len(peer.records) == previous, 'a refused connection became successful'
                    assert (peer.tls_rejected if scheme == 'https' else peer.rejected) > refused, 'the intended refusal was not reached'
                    records.append({'scheme': scheme, 'variant': label, 'accepted': False})
            assert trap.hits == 0, 'traffic bypassed the selected proxy'
        (output / 'results.json').write_text(json.dumps(records, indent=2))
        print(f'{len(records)} loopback link scenarios passed; auth, TLS and wire parameters match the native parser')


if __name__ == '__main__':
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    core, output = (Path(value).resolve() for value in sys.argv[1:3])
    reference = Path(sys.argv[3]).resolve() if len(sys.argv) == 4 else core
    main(core, output, reference)
