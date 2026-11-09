"""Verify provider selection by authenticated traffic through local synthetic peers.

Usage: python3 core/tests/subscription_selection.py CORE NEW_OUTPUT_DIR
CORE must be a trusted LoKi build. No external servers or router settings are used.
"""
import base64
import contextlib
import copy
import http.server
import json
from pathlib import Path
import subprocess
import sys
import time
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import ProxyHandler, Request, build_opener
import plain_links as links

OPENER = build_opener(ProxyHandler({}))
API_SECRET = 'synthetic-loopback-api'


class Proxy(links.Proxy):
    def handle(self):
        self.connection.settimeout(3)
        try:
            line = self.rfile.readline(8193)
            headers = self.headers()
            assert line.startswith(b'CONNECT '), 'unexpected local proxy request'
            markers = getattr(self.server, 'auth_markers', {links.AUTH: self.server.marker})
            marker = markers.get(headers.get('proxy-authorization'))
            if marker is None:
                self.server.rejected += 1
                self.wfile.write(b'HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n')
                return
            self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n')
            self.wfile.flush()
            assert self.rfile.readline(8193).startswith(b'GET ')
            self.headers()
            self.server.records.append(line)
            body = marker.encode()
            self.wfile.write(b'HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
        except (EOFError, OSError):
            pass
        except Exception as error:
            self.server.failures.append(str(error))


class Subscription(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.hits += 1
        payload = self.server.payloads.get(self.path)
        if payload is None:
            self.send_error(404)
            return
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain' if body.startswith(b'http://') else 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def api(port, path, method='GET', data=None, authenticated=True, timeout=4):
    body = json.dumps(data).encode() if data is not None else (b'' if method == 'PUT' else None)
    headers = {'Content-Type': 'application/json'}
    if authenticated:
        headers['Authorization'] = 'Bearer ' + API_SECRET
    request = Request(f'http://127.0.0.1:{port}{path}', data=body, method=method, headers=headers)
    with OPENER.open(request, timeout=timeout) as reply:
        content = reply.read(65537)
        assert len(content) <= 65536, 'oversized local API response'
        return json.loads(content) if content else None


class Runtime:
    def __init__(self, core, product, directory, expected_members=4):
        self.core, self.directory = core, directory
        self.expected_members = expected_members
        self.api_port, self.port = links.free_port(), links.free_port()
        config = copy.deepcopy(product)
        config['inbounds'] = [{'type': 'mixed', 'tag': 'harness', 'listen': '127.0.0.1', 'listen_port': self.port}]
        config['route']['rules'] = [{'inbound': ['harness'], 'action': 'route', 'outbound': 'main'}]
        config['route']['final'] = 'direct-out'
        config['route'].pop('default_mark', None)
        config['log'] = {'level': 'error'}
        config['experimental']['clash_api'] = {'external_controller': f'127.0.0.1:{self.api_port}', 'secret': API_SECRET}
        config['experimental']['cache_file']['path'] = str(directory / 'cache.db')
        for provider in config['providers']:
            provider['health_check'] = {'enabled': False}
        self.path = directory / 'runtime.json'
        self.path.write_text(json.dumps(config))
        self.runs = 0

    @contextlib.contextmanager
    def running(self):
        self.runs += 1
        with (self.directory / f'core-{self.runs}.log').open('wb') as log:
            process = subprocess.Popen([str(self.core), '-D', str(self.directory), 'run', '-c', str(self.path)], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 8
                while True:
                    assert process.poll() is None, 'core exited before local API readiness'
                    try:
                        group = self.group()
                        members = group.get('all') if isinstance(group, dict) else None
                        # The API can be ready before its asynchronous providers populate the group.
                        if isinstance(members, list) and len(members) == self.expected_members and all(
                                isinstance(member, str) and member for member in members):
                            break
                    except (OSError, ValueError, KeyError):
                        pass
                    assert time.monotonic() < deadline, 'provider startup exceeded its deadline'
                    time.sleep(.02)
                yield process
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

    def group(self):
        return api(self.api_port, '/proxies/main')

    def choose(self, tag):
        api(self.api_port, '/proxies/main', 'PUT', {'name': tag})

    def refresh(self):
        api(self.api_port, '/providers/proxies/' + quote('main/Two', safe=''), 'PUT')


def main(core, output):
    output.mkdir(mode=0o700, parents=True)
    results = []
    with contextlib.ExitStack() as stack:
        peers = {marker: links.serve(stack, Proxy) for marker in 'ACD'}
        for marker, peer in peers.items():
            peer.marker = marker
        trap = links.serve(stack, links.Trap)
        subscription = links.serve(stack, Subscription)

        def node(marker, tag='Node'):
            return {'type': 'http', 'tag': tag, 'server': '127.0.0.1', 'server_port': peers[marker].server_address[1],
                    'username': links.USER, 'password': links.PASSWORD}

        for position in (0, 1):
            directory = output / f'chosen-position-{position}'
            directory.mkdir(mode=0o700)
            subscription.payloads = {'/one': {'outbounds': [node('A'), node('C', 'Copy')]},
                                     '/two': {'outbounds': [node('C'), node('D')]}}
            if position:
                subscription.payloads['/two']['outbounds'].reverse()
            subscription.payloads['/two'].update({
                'inbounds': [{'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': trap.server_address[1]}],
                'route': {'final': 'client-only-missing'},
                'log': {'output': str(directory / 'client-log-must-not-exist')},
            })
            fixture = {'settings': {'dns_server': ['127.0.0.1:9'], 'bootstrap_dns_server': ['127.0.0.1:9'], 'unified_delay': '0'},
                       'section': [{'.name': 'main', 'action': 'connection'}],
                       'subscription_url': [{'.name': name, 'section': 'main', 'tag': name,
                                             'url': f'http://127.0.0.1:{subscription.server_address[1]}/{path}',
                                             'subscription_update_enabled': '0'} for name, path in [('One', 'one'), ('Two', 'two')]]}
            product = links.generate_fixture(fixture, directory)
            generated = directory / 'generated.json'
            generated.write_text(json.dumps(product))
            subprocess.run([str(core), 'check', '-c', str(generated)], check=True, capture_output=True, timeout=10)
            runtime = Runtime(core, product, directory)

            def check(marker, provider='main/Two'):
                selected = runtime.group()['now']
                assert selected.startswith(provider + '/'), 'choice moved to a different subscription'
                before = {name: len(peer.records) for name, peer in peers.items()}
                reply = links.request(runtime.port, trap.server_address[1])
                actual = reply.split(b'\r\n\r\n', 1)[-1].decode()
                assert actual == marker, f'expected connection {marker}, reached {actual}'
                assert len(peers[marker].records) == before[marker] + 1, 'selected peer did not authenticate exactly once'
                assert all(len(peer.records) == before[name] for name, peer in peers.items() if name != marker)
                assert not trap.hits, 'request bypassed the selected proxy'
                assert not any(peer.failures or peer.rejected for peer in peers.values())
                results.append({'position': position, 'marker': marker, 'provider': provider})

            with runtime.running():
                chosen = 'main/Two/Node' + (' #2' if position else '')
                runtime.choose(chosen)
                check('C')
                try:
                    runtime.choose('missing-node')
                    raise AssertionError('unknown selection succeeded')
                except HTTPError as error:
                    assert error.code == 400
                check('C')
                try:
                    api(runtime.api_port, '/proxies/main', authenticated=False)
                    raise AssertionError('local API accepted missing credentials')
                except HTTPError as error:
                    assert error.code == 401

            with runtime.running():
                check('C')
                subscription.payloads['/two']['outbounds'].reverse()
                runtime.refresh()
                check('C')
                runtime.refresh()
                check('C')

            with runtime.running():
                check('C')
                subscription.payloads['/two']['outbounds'] = [node('D'), node('C', 'Renamed'), node('C', 'Clone')]
                runtime.refresh()
                check('C')
                subscription.payloads['/two']['outbounds'] = [node('C', 'Clone')]
                runtime.refresh()
                check('C')
                subscription.payloads['/two']['outbounds'] = [node('D')]
                runtime.refresh()
                check('A', 'main/One')
                subscription.payloads['/two']['outbounds'] = [node('D'), node('C', 'Returned')]
                runtime.refresh()
                check('C')
                subscription.payloads['/two']['outbounds'] = [node('D')]
                runtime.refresh()
                check('A', 'main/One')
                runtime.choose(runtime.group()['now'])
                subscription.payloads['/two']['outbounds'] = [node('D'), node('C', 'Returned')]
                runtime.refresh()
                check('A', 'main/One')
                runtime.choose('main/Two/Returned')
                check('C')
                valid = subscription.payloads['/two']
                subscription.payloads['/two'] = b'{"outbounds": ['
                try:
                    runtime.refresh()
                    raise AssertionError('malformed provider refresh succeeded')
                except HTTPError as error:
                    assert error.code == 503
                check('C')
                subscription.payloads['/two'] = valid
                runtime.refresh()
                check('C')
                # Prove that receiving any authenticated marker is not enough.
                runtime.choose('main/Two/Node')
                try:
                    check('C')
                    raise RuntimeError('traffic oracle accepted the wrong connection')
                except AssertionError as error:
                    assert str(error) == 'expected connection C, reached D'
                runtime.choose('main/Two/Returned')
                check('C')
                assert not (directory / 'client-log-must-not-exist').exists()

        # The same endpoint can authenticate different accounts whose JSON strings look equal.
        account_peer = links.serve(stack, Proxy)
        account_peer.marker = 'unused'
        account_peer.auth_markers = {
            'Basic ' + base64.b64encode(links.USER.encode() + b':' + password).decode(): marker
            for password, marker in [(b'\xff', 'raw-account'), ('\uFFFD'.encode(), 'unicode-account')]
        }
        urls = [f'http://{quote(links.USER, safe="")}:{password}@127.0.0.1:{account_peer.server_address[1]}#ByteNode'
                for password in ('%FF', '%EF%BF%BD')]
        subscription.payloads['/two'] = '\n'.join(urls).encode()
        directory = output / 'binary-credentials'
        directory.mkdir(mode=0o700)
        product = links.generate_fixture(fixture, directory)
        runtime = Runtime(core, product, directory)

        def check_account():
            assert runtime.group()['now'].startswith('main/Two/')
            before = len(account_peer.records)
            reply = links.request(runtime.port, trap.server_address[1])
            assert reply.split(b'\r\n\r\n', 1)[-1] == b'raw-account', 'credential bytes selected another account'
            assert len(account_peer.records) == before + 1
            assert not account_peer.failures and not account_peer.rejected and not trap.hits
            results.append({'position': 'binary', 'marker': 'raw-account', 'provider': 'main/Two'})

        with runtime.running():
            runtime.choose('main/Two/ByteNode')
            check_account()
            subscription.payloads['/two'] = '\n'.join(reversed(urls)).encode()
            runtime.refresh()
            check_account()
        with runtime.running():
            check_account()
            chosen = runtime.group()['now']
            other = next(tag for tag in runtime.group()['all'] if tag.startswith('main/Two/') and tag != chosen)
            runtime.choose(other)
            try:
                check_account()
                raise RuntimeError('traffic oracle accepted the wrong account')
            except AssertionError as error:
                assert str(error) == 'credential bytes selected another account'
            runtime.choose(chosen)
            check_account()

    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    print(json.dumps({'traffic_checks': len(results), 'reorder_positions': 2, 'binary_credential_checks': 4, 'oracle_controls': 3}))


if __name__ == '__main__':
    main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
