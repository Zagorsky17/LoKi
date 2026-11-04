"""Check connection-only import from client profiles through loopback peers.

Usage: python3 core/tests/subscription_profiles.py CORE NEW_OUTPUT_DIR [--measure-sizes]
Use a trusted LoKi core. All endpoints, certificates and credentials are synthetic.
Size measurements are optional observations, not an accepted-size or resource-cap contract.
"""
import base64
import contextlib
import copy
import gzip
import http.server
import json
import os
from pathlib import Path
import select
import socket
import socketserver
import struct
import ssl
import subprocess
import sys
import threading
import time
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
import plain_links as links
import subscription_selection as selection

UUID = '8e2948ac-2437-49b3-80d8-421628bd16cd'
SHORT_ID = '13a25b36'
SS_PASSWORDS = ['synthetic-ss-account-one', 'synthetic-ss-account-two']


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.hits += 1
        body = b'profile-loopback-origin'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class Subscription(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.hits += 1
        response = self.server.responses[self.path]
        body, headers, extra = response[:3]
        self.send_response(response[3] if len(response) == 4 else 200)
        self.send_header('Content-Length', str(len(body) + extra))
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        try:
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

    def log_message(self, *_args):
        pass


class DNS(socketserver.BaseRequestHandler):
    def handle(self):
        packet, stream = self.request
        self.server.hits += 1
        assert len(packet) >= 17 and packet[4:6] == b'\x00\x01', 'unexpected synthetic DNS question'
        end = 12
        while packet[end]:
            end += packet[end] + 1
            assert end < len(packet), 'truncated synthetic DNS question'
        question = packet[12:end + 5]
        assert question[-4:] == b'\x00\x01\x00\x01', 'only synthetic A queries are expected'
        answer = b'\xc0\x0c\x00\x01\x00\x01' + struct.pack('!IH', 1, 4) + socket.inet_aton(self.server.answer)
        stream.sendto(packet[:2] + b'\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00' + question + answer, self.client_address)


def dns_peer(stack, answer):
    peer = socketserver.ThreadingUDPServer(('127.0.0.1', 0), DNS)
    peer.daemon_threads, peer.hits, peer.answer = True, 0, answer
    threading.Thread(target=peer.serve_forever, kwargs={'poll_interval': .02}, daemon=True).start()
    stack.callback(peer.server_close)
    stack.callback(peer.shutdown)
    return peer


class Relay(socketserver.BaseRequestHandler):
    def handle(self):
        self.server.hits += 1
        self.request.settimeout(3)
        try:
            with socket.create_connection(('127.0.0.1', self.server.target), timeout=3) as peer:
                for connection in (self.request, peer):
                    connection.setblocking(False)
                deadline = time.monotonic() + 4
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([self.request, peer], [], [], .1)
                    for source in ready:
                        content = source.recv(65536)
                        if not content:
                            return
                        destination = peer if source is self.request else self.request
                        destination.setblocking(True)
                        destination.settimeout(2)
                        destination.sendall(content)
                        destination.setblocking(False)
        except OSError:
            pass


def private_json(path, value):
    path.write_text(json.dumps(value))
    path.chmod(0o600)


def wait_port(process, port):
    deadline = time.monotonic() + 6
    while True:
        assert process.poll() is None, 'trusted peer core exited before readiness'
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.1):
                return
        except OSError:
            assert time.monotonic() < deadline, 'trusted peer core startup deadline'
            time.sleep(.02)


@contextlib.contextmanager
def peer_core(core, directory, inbound, origin_port):
    directory.mkdir(mode=0o700)
    config = {'log': {'level': 'error'}, 'inbounds': [inbound],
              'outbounds': [{'type': 'direct', 'tag': 'direct'}],
              'route': {'rules': [
                  {'ip_cidr': ['127.0.0.1/32'], 'port': [origin_port], 'action': 'route', 'outbound': 'direct'},
                  {'action': 'reject'}]}}
    path = directory / 'runtime.json'
    private_json(path, config)
    subprocess.run([str(core), 'check', '-c', str(path)], check=True, capture_output=True, timeout=10)
    with (directory / 'core.log').open('wb') as log:
        process = subprocess.Popen([str(core), '-D', str(directory), 'run', '-c', str(path)], stdout=log, stderr=log)
        try:
            wait_port(process, inbound['listen_port'])
            yield process
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


def main(core, output, measure_sizes=False):
    if sys.platform != 'linux' or os.geteuid() == 0:
        raise SystemExit('Run this test as an unprivileged Linux user')
    status = Path('/proc/self/status').read_text()
    if int(next(line.split()[1] for line in status.splitlines() if line.startswith('CapEff:')), 16):
        raise SystemExit('Run this test without Linux capabilities')
    output.mkdir(mode=0o700, parents=True)
    certificate, tls = links.test_certificate(output, 'loopback')
    # Reality requires a TLS1.3 handshake peer; it remains loopback and self-signed.
    tls.minimum_version = ssl.TLSVersion.TLSv1_3
    keys = subprocess.run([str(core), 'generate', 'reality-keypair'], check=True, capture_output=True, text=True, timeout=10)
    keys = {name.strip().replace(' ', '').lower(): value.strip() for name, value in
            (line.split(':', 1) for line in keys.stdout.splitlines() if ':' in line)}
    assert 'privatekey' in keys and 'publickey' in keys, 'unexpected trusted key generator format'
    results, measurements, capacity, capacity_secrets = [], [], [], []
    with contextlib.ExitStack() as stack:
        plain = links.serve(stack, selection.Proxy)
        plain.marker = 'http-authenticated'
        secure = links.serve(stack, selection.Proxy, tls)
        secure.marker = 'https-authenticated'
        handshake = links.serve(stack, links.Proxy, tls)
        origin = links.serve(stack, Origin)
        trap = links.serve(stack, links.Trap)
        subscription = links.serve(stack, Subscription)
        subscription.responses = {}
        own_dns = dns_peer(stack, '198.18.0.42')
        client_dns = dns_peer(stack, '198.18.0.99')
        forbidden_ports = []
        for _ in range(2):
            reservation = stack.enter_context(socket.socket())
            reservation.bind(('127.0.0.1', 0))
            forbidden_ports.append(reservation.getsockname()[1])
        ws_port, reality_port = links.free_port(), links.free_port()
        ws_inbound = {'type': 'vless', 'tag': 'ws-peer', 'listen': '127.0.0.1', 'listen_port': ws_port,
                      'users': [{'uuid': UUID}],
                      'tls': {'enabled': True, 'certificate_path': str(certificate), 'key_path': str(output / 'loopback.key')},
                      'transport': {'type': 'ws', 'path': '/profile-boundary'}}
        reality_inbound = {'type': 'vless', 'tag': 'reality-peer', 'listen': '127.0.0.1', 'listen_port': reality_port,
                           'users': [{'uuid': UUID}], 'tls': {'enabled': True, 'server_name': 'profile.test',
                           'reality': {'enabled': True, 'private_key': keys['privatekey'], 'short_id': [SHORT_ID],
                                       'handshake': {'server': '127.0.0.1', 'server_port': handshake.server_address[1]}}}}
        ws_process = stack.enter_context(peer_core(core, output / 'ws-peer', ws_inbound, origin.server_address[1]))
        reality_process = stack.enter_context(peer_core(core, output / 'reality-peer', reality_inbound, origin.server_address[1]))
        ws_relay = links.serve(stack, Relay)
        ws_relay.target = ws_port
        reality_relay = links.serve(stack, Relay)
        reality_relay.target = reality_port

        def http_node(peer, encrypted=False):
            item = {'type': 'http', 'tag': 'Node', 'server': '127.0.0.1', 'server_port': peer.server_address[1],
                    'username': links.USER, 'password': links.PASSWORD}
            if encrypted:
                item['tls'] = {'enabled': True, 'server_name': '127.0.0.1', 'certificate': certificate.read_text()}
            return item

        nodes = [http_node(plain), http_node(secure, True),
                 {'type': 'vless', 'tag': 'Node', 'server': '127.0.0.1', 'server_port': ws_relay.server_address[1],
                  'uuid': UUID, 'tls': {'enabled': True, 'server_name': '127.0.0.1', 'certificate': certificate.read_text()},
                  'transport': {'type': 'ws', 'path': '/profile-boundary', 'headers': {'Host': 'profile.test'}}},
                 {'type': 'vless', 'tag': 'Node', 'server': '127.0.0.1', 'server_port': reality_relay.server_address[1],
                  'uuid': UUID, 'tls': {'enabled': True, 'server_name': 'profile.test',
                  'utls': {'enabled': True, 'fingerprint': 'chrome'},
                  'reality': {'enabled': True, 'public_key': keys['publickey'], 'short_id': SHORT_ID}}}]
        subscription.responses['/one'] = (json.dumps({'outbounds': nodes[:2]}).encode(), {}, 0)
        subscription.responses['/two'] = (json.dumps({'outbounds': nodes[2:]}).encode(), {}, 0)
        fixture = {'settings': {'dns_server': [f'127.0.0.1:{own_dns.server_address[1]}'], 'bootstrap_dns_server': [f'127.0.0.1:{own_dns.server_address[1]}'], 'unified_delay': '0'},
                   'section': [{'.name': 'main', 'action': 'connection'}],
                   'subscription_url': [{'.name': name, 'section': 'main', 'tag': name,
                                         'url': f'http://127.0.0.1:{subscription.server_address[1]}/{path}',
                                         'subscription_update_enabled': '0'} for name, path in [('One', 'one'), ('Two', 'two')]]}
        directory = output / 'profiles'
        directory.mkdir(mode=0o700)
        product = links.generate_fixture(fixture, directory)
        product['certificate'] = {'store': 'none', 'certificate_path': str(certificate)}
        runtime = selection.Runtime(core, product, directory)
        private_json(runtime.path, json.loads(runtime.path.read_text()))
        forbidden_files = [output / 'client-log-must-not-exist', output / 'client-cache-must-not-exist.db']
        interface = Path('/sys/class/net/loki-profile-canary')
        assert not interface.exists(), 'synthetic TUN canary already exists'

        def globals_for_client():
            return {'dns': {'servers': [{'type': 'udp', 'tag': 'client-only', 'server': '127.0.0.1',
                    'server_port': client_dns.server_address[1]}], 'final': 'client-only'},
                    'route': {'final': 'client-route-must-not-exist'},
                    'inbounds': [{'type': 'mixed', 'listen': '127.0.0.1', 'listen_port': forbidden_ports[0]},
                                 {'type': 'tun', 'interface_name': interface.name, 'address': ['198.19.0.1/30'],
                                  'auto_route': False}],
                    'log': {'level': 'debug', 'output': str(forbidden_files[0])},
                    'experimental': {'cache_file': {'enabled': True, 'path': str(forbidden_files[1])},
                                     'clash_api': {'external_controller': f'127.0.0.1:{forbidden_ports[1]}',
                                                   'secret': 'client-api-key-must-not-apply'}}}

        expected = ['main/One/Node', 'main/One/Node #2', 'main/Two/Node', 'main/Two/Node #2']
        processes = [ws_process, reality_process]
        active_peers = [plain, secure, ws_relay, reality_relay]
        uses_origin = [False, False, True, True]
        markers = [b'http-authenticated', b'https-authenticated', b'profile-loopback-origin', b'profile-loopback-origin']
        active_format = 'sing-box'
        ss_nodes = []

        def check_side_effects():
            assert not any(path.exists() for path in forbidden_files), 'client profile created its own file'
            assert not interface.exists(), 'client profile created a TUN interface'
            for port in forbidden_ports:
                with socket.socket() as probe:
                    probe.settimeout(.1)
                    assert probe.connect_ex(('127.0.0.1', port)) != 0, 'client profile opened a listener'
            assert not client_dns.hits, 'client profile replaced LoKi DNS'
            assert not trap.hits, 'request bypassed its selected peer'
            assert all(process.poll() is None for process in processes), 'a test core exited'

        dns_serial = 0

        def check_dns():
            nonlocal dns_serial
            dns_serial += 1
            before = own_dns.hits
            value = selection.api(runtime.api_port, '/dns/query?name=profile-' + str(dns_serial) + '.test&type=A')
            assert value['Status'] == 0 and value['Answer'][0]['data'] == '198.18.0.42', 'DNS oracle detected another resolver answer'
            assert own_dns.hits == before + 1, 'DNS answer did not come from LoKi resolver'
            check_side_effects()

        def check(index, successful=True):
            runtime.choose(expected[index])
            peer = active_peers[index]
            before, before_origin = peer.hits if uses_origin[index] else len(peer.records), origin.hits
            reply = links.request(runtime.port, origin.server_address[1] if uses_origin[index] else trap.server_address[1])
            body = reply.split(b'\r\n\r\n', 1)[-1]
            expected_body = markers[index]
            if successful:
                assert body == expected_body, f'connection {index} did not reach its authenticated loopback peer'
                assert (peer.hits if uses_origin[index] else len(peer.records)) == before + 1, 'connection bypassed the protocol peer'
                if uses_origin[index]:
                    assert origin.hits == before_origin + 1
            else:
                assert body != expected_body, 'invalid connection parameters still reached the marker'
                assert origin.hits == before_origin, 'invalid connection reached the origin'
                if not uses_origin[index]:
                    assert len(peer.records) == before
                else:
                    assert peer.hits > before, 'negative control did not reach its protocol peer'
            check_side_effects()
            results.append({'format': active_format, 'connection': index,
                            'result': 'authenticated-loopback' if successful else 'refused'})

        def refresh(provider):
            selection.api(runtime.api_port, '/providers/proxies/' + quote('main/' + provider, safe=''), 'PUT')
            check_side_effects()

        def native_profiles(values):
            return [dict(globals_for_client(), outbounds=values[:2]), dict(globals_for_client(), outbounds=values[2:])]

        def publish(profiles):
            for path, value in zip(['/one', '/two'], profiles):
                subscription.responses[path] = (json.dumps(value).encode(), {}, 0)

        profiles = native_profiles(nodes)
        publish(profiles)
        with runtime.running() as process:
            processes.append(process)
            assert set(runtime.group()['all']) == set(expected), 'subscription namespace changed or lost duplicate names'
            for index in range(4):
                check(index)
            check_dns()
            # Protocol peers must not become general proxies, even with valid test credentials.
            for index in [2, 3]:
                runtime.choose(expected[index])
                peer = [ws_relay, reality_relay][index - 2]
                before_peer, before_origin = peer.hits, origin.hits
                reply = links.request(runtime.port, trap.server_address[1])
                assert b'profile-loopback-origin' not in reply
                assert peer.hits == before_peer + 1, 'target restriction was not exercised at the peer'
                assert origin.hits == before_origin, 'rejected target reached the origin'
                check_side_effects()
            # Alter only globals, one section at a time: the selected connection and DNS stay.
            for name, value in globals_for_client().items():
                subscription.responses['/two'] = (json.dumps({'outbounds': nodes[2:], name: value}).encode(), {}, 0)
                refresh('Two')
                assert runtime.group()['now'] == expected[3], 'globals changed the chosen subscription member'
                check(3)
                check_dns()
            publish(profiles)
            refresh('Two')
            # Each negative control changes a real connection parameter, not the global profile.
            for index, field, wrong in [(0, 'password', 'incorrect-account'), (1, 'password', 'incorrect-account'),
                                        (2, 'uuid', '65f676b9-cb1f-45b4-a824-a0a5856cf009'),
                                        (3, 'uuid', '65f676b9-cb1f-45b4-a824-a0a5856cf009')]:
                changed = copy.deepcopy(nodes)
                changed[index][field] = wrong
                publish(native_profiles(changed))
                refresh('One' if index < 2 else 'Two')
                check(index, False)
                publish(profiles)
                refresh('One' if index < 2 else 'Two')
                check(index)
            for index, field, wrong in [(1, 'server_name', 'wrong.test'), (2, 'server_name', 'wrong.test')]:
                changed = copy.deepcopy(nodes)
                changed[index]['tls'][field] = wrong
                publish(native_profiles(changed))
                refresh('One' if index == 1 else 'Two')
                check(index, False)
                publish(profiles)
                refresh('One' if index == 1 else 'Two')
                check(index)
            for part, field, wrong in [('transport', 'path', '/wrong-path'), ('tls', 'short_id', '87b65a24')]:
                index = 2 if part == 'transport' else 3
                changed = copy.deepcopy(nodes)
                destination = changed[index][part] if part == 'transport' else changed[index]['tls']['reality']
                destination[field] = wrong
                publish(native_profiles(changed))
                refresh('Two')
                check(index, False)
                publish(profiles)
                refresh('Two')
                check(index)
            # Failed HTTP bodies cannot replace the previously authenticated set.
            valid = subscription.responses['/two']
            for body, extra in [(b'{"outbounds":[', 0), (b'not-a-subscription', 0), (b'{"outbounds":[]}', 0),
                                (b'{"outbounds":[{"password":' + json.dumps(links.PASSWORD).encode() + b',"server":', 0),
                                (valid[0], 11), (valid[0][:len(valid[0]) // 2], len(valid[0])),
                                (b'\xff\x00invalid', 0), (b'{"outbounds":[null]}', 0), (b'{"outbounds":"invalid"}', 0)]:
                subscription.responses['/two'] = (body, {}, extra)
                try:
                    refresh('Two')
                    raise AssertionError('malformed or truncated provider response succeeded')
                except HTTPError as error:
                    assert error.code == 503
                check(3)
                subscription.responses['/two'] = valid
                refresh('Two')
                check(3)
            subscription.responses['/two'] = (valid[0], {}, 0, 503)
            try:
                refresh('Two')
                raise AssertionError('HTTP status failure replaced the provider')
            except HTTPError as error:
                assert error.code == 503
            check(3)
            subscription.responses['/two'] = valid
            refresh('Two')
            # Exercise the owner's 30-per-provider/50-total workload and double-sized headroom.
            # Unique authenticated markers prove that every advertised member remains usable.
            for counts in [(30, 20), (60, 40)]:
                baseline_memory = {line.split(':')[0]: int(line.split()[1]) for line in Path(f'/proc/{process.pid}/status').read_text().splitlines() if line.startswith(('VmRSS:', 'VmHWM:'))}
                for peer in [plain, secure]:
                    peer.auth_markers = {links.AUTH: peer.marker}
                expected_capacity, documents = {}, []
                for provider, count in zip(['One', 'Two'], counts):
                    members = []
                    for index in range(count):
                        encrypted = index % 2 == 1
                        peer = secure if encrypted else plain
                        item = http_node(peer, encrypted)
                        marker = f'capacity-{provider}-{index:03d}'
                        item.update(tag=marker, username=marker + '-user', password=marker + '-password')
                        capacity_secrets.extend([item['username'], item['password']])
                        auth = 'Basic ' + base64.b64encode(f"{item['username']}:{item['password']}".encode()).decode()
                        peer.auth_markers[auth] = marker
                        expected_capacity[f'main/{provider}/{marker}'] = (peer, marker.encode())
                        members.append(item)
                    documents.append({'outbounds': members})
                publish(documents)
                refresh('One')
                refresh('Two')
                assert set(runtime.group()['all']) == set(expected_capacity), 'capacity workload lost or merged a member'
                for tag, (peer, marker) in expected_capacity.items():
                    runtime.choose(tag)
                    before = len(peer.records)
                    response = links.request(runtime.port, trap.server_address[1])
                    assert response.split(b'\r\n\r\n', 1)[-1] == marker, 'capacity member reached another identity'
                    assert len(peer.records) == before + 1, 'capacity traffic bypassed its authenticated peer'
                    check_side_effects()
                old_members = runtime.group()['all']
                good = subscription.responses['/two']
                subscription.responses['/two'] = (b'{"outbounds":[', {}, 0)
                try:
                    refresh('Two')
                    raise AssertionError('capacity workload accepted a truncated update')
                except HTTPError as error:
                    assert error.code == 503
                assert runtime.group()['all'] == old_members, 'failed capacity update replaced the old set'
                last_peer, last_marker = expected_capacity[tag]
                before = len(last_peer.records)
                assert links.request(runtime.port, trap.server_address[1]).split(b'\r\n\r\n', 1)[-1] == last_marker
                assert len(last_peer.records) == before + 1, 'failed update lost the selected working member'
                subscription.responses['/two'] = good
                refresh('Two')
                memory = {line.split(':')[0]: int(line.split()[1]) for line in Path(f'/proc/{process.pid}/status').read_text().splitlines() if line.startswith(('VmRSS:', 'VmHWM:'))}
                capacity.append({'provider_nodes': list(counts), 'total_nodes': sum(counts),
                                 'protocols': ['http', 'https'],
                                 'http_body_bytes': [len(subscription.responses[path][0]) for path in ['/one', '/two']],
                                 'cache_logical_bytes': sum(path.stat().st_size for path in directory.rglob('*') if path.is_file() and path.relative_to(directory).parts[0].startswith('cache.db')),
                                 'authenticated_connections': sum(counts), 'failed_update_retained': True,
                                 'before_rss_kib': baseline_memory['VmRSS'], 'before_hwm_kib': baseline_memory['VmHWM'],
                                 'rss_kib': memory['VmRSS'], 'hwm_kib': memory['VmHWM']})
                publish(profiles)
                refresh('One')
                refresh('Two')
                for peer in [plain, secure]:
                    del peer.auth_markers
                assert set(runtime.group()['all']) == set(expected), 'capacity cleanup did not restore the four-member fixture'
                check(3)
                check_dns()
            # Small bounded measurements expose amplification without imposing a new product cap.
            for decoded_size, encoding in [(65536, 'raw'), (262144, 'raw'), (1048576, 'raw'),
                                            (262144, 'gzip'), (262144, 'base64')] if measure_sizes else []:
                document = json.dumps(dict(profiles[1], ignored_padding='')).encode()
                document = json.dumps(dict(profiles[1], ignored_padding='A' * (decoded_size - len(document)))).encode()
                assert len(document) == decoded_size, 'bounded size fixture length changed'
                body = gzip.compress(document) if encoding == 'gzip' else base64.b64encode(document) if encoding == 'base64' else document
                headers = {'Content-Encoding': 'gzip'} if encoding == 'gzip' else {}
                subscription.responses['/two'] = (body, headers, 0)
                refresh('Two')
                check(3)
                cached = [path.read_bytes() for path in (directory / 'cache.db.subscriptions').iterdir() if path.is_file()]
                matches = [value for value in cached if value.endswith(document)]
                assert len(matches) == 1, 'cached provider content did not preserve the decoded fixture'
                cached_body_bytes = len(matches[0].split(b'\n', 1)[1])
                assert cached_body_bytes == len(document), 'cached normalized content length changed'
                memory = {line.split(':')[0]: int(line.split()[1]) for line in Path(f'/proc/{process.pid}/status').read_text().splitlines() if line.startswith(('VmRSS:', 'VmHWM:'))}
                measurements.append({'encoding': encoding, 'http_body_bytes': len(body), 'decoded_bytes': len(document),
                                     'accepted': True, 'cached_content_bytes': cached_body_bytes, 'rss_kib': memory['VmRSS'], 'hwm_kib': memory['VmHWM']})
            subscription.responses['/two'] = valid
            refresh('Two')
            check(3)
            check_dns()

            def clash_documents(values, partial=False):
                documents = []
                for group in [values[:2], values[2:]]:
                    proxies = []
                    for item in group:
                        proxy = {'name': 'Node', 'type': item['type'], 'server': item['server'],
                                 'port': str(item['server_port'])}
                        if item['type'] == 'http':
                            proxy.update(username=item['username'], password=item['password'])
                        else:
                            proxy['uuid'] = item['uuid']
                        if item.get('tls'):
                            tls_options = item['tls']
                            proxy.update(tls=True, sni=tls_options['server_name'], **{'skip-cert-verify': False})
                            if tls_options.get('reality'):
                                proxy.update({'client-fingerprint': 'chrome',
                                              'reality-opts': {'public-key': tls_options['reality']['public_key'],
                                                               'short-id': tls_options['reality']['short_id']}})
                            else:
                                proxy['ca-str'] = certificate.read_text()
                        if item.get('transport'):
                            proxy.update(network='ws', **{'ws-opts': {'path': item['transport']['path'],
                                                                     'headers': item['transport']['headers']}})
                        proxies.append(proxy)
                    # Clash accepts option-name case and underscore spellings; header names remain data.
                    proxies[1] = {key.upper().replace('-', '_'): value for key, value in proxies[1].items()}
                    if partial:
                        proxies.append({'name': 'Incomplete', 'type': 'vless', 'password': links.PASSWORD})
                    globals_ = dict(globals_for_client(), **{
                        'mixed-port': forbidden_ports[0], 'external-controller': f'127.0.0.1:{forbidden_ports[1]}',
                        'secret': 'client-api-key-must-not-apply', 'rules': ['MATCH,REJECT'],
                        'tun': {'enable': True, 'device': interface.name},
                        'dns': {'enable': True, 'listen': f'127.0.0.1:{forbidden_ports[0]}',
                                'nameserver': [f'udp://127.0.0.1:{client_dns.server_address[1]}']},
                        'profile': {'store-selected': True, 'store-fake-ip': True}})
                    document = 'proxies:\n' + ''.join('  - ' + json.dumps(proxy) + '\n' for proxy in proxies)
                    document += ''.join(key + ': ' + json.dumps(value) + '\n' for key, value in globals_.items())
                    documents.append(document.encode())
                return documents

            def raw_documents(values, partial=False):
                documents = []
                for group in [values[:2], values[2:]]:
                    lines = ['# client settings are comments: ' + json.dumps(globals_for_client()), '']
                    for item in group:
                        if item['type'] == 'http':
                            scheme = 'https' if item.get('tls') else 'http'
                            account = quote(item['username'], safe='') + ':' + quote(item['password'], safe='')
                            link = f'{scheme}://{account}@{item["server"]}:{item["server_port"]}'
                        else:
                            tls_options = item['tls']
                            query = {'security': 'reality' if tls_options.get('reality') else 'tls',
                                     'sni': tls_options['server_name'], 'encryption': 'none'}
                            if tls_options.get('reality'):
                                query.update(pbk=tls_options['reality']['public_key'],
                                             sid=tls_options['reality']['short_id'], fp='chrome')
                            if item.get('transport'):
                                query.update(type='ws', path=item['transport']['path'],
                                             host=item['transport']['headers']['Host'])
                            link = f'vless://{item["uuid"]}@{item["server"]}:{item["server_port"]}?' + urlencode(query)
                        lines.append('  ' + link + '#Node  ')
                    if partial:
                        lines.append('vless://')
                    documents.append(('\r\n'.join(lines) + '\r\n').encode())
                return documents

            def sip008_documents(values, partial=False):
                documents = []
                for group in [values[:2], values[2:]]:
                    servers = [{'remarks': 'Node', 'server': item['server'], 'server_port': str(item['server_port']),
                                'password': item['password'], 'method': item['method']} for item in group]
                    if partial:
                        servers.append({'remarks': 'Incomplete', 'server': '127.0.0.1', 'password': SS_PASSWORDS[0]})
                    documents.append(json.dumps(dict(globals_for_client(), version=1, bytes_used=1,
                                                     bytes_remaining=2, servers=servers)).encode())
                return documents

            def exercise_format(name, builder, values, malformed, negative_controls):
                nonlocal active_format
                active_format = name
                expected[:] = ['main/One/Node', 'main/One/Node #2', 'main/Two/Node', 'main/Two/Node #2']

                def replace_documents(documents, encoded=False):
                    for path, body in zip(['/one', '/two'], documents):
                        subscription.responses[path] = (base64.b64encode(body) if encoded else body, {}, 0)
                    refresh('One')
                    refresh('Two')
                    assert set(runtime.group()['all']) == set(expected), f'{name} lost a subscription or duplicate name'

                for encoded in [False, True]:
                    replace_documents(builder(values), encoded)
                    for index in range(4):
                        check(index)
                    check_dns()
                    refresh('One')
                    refresh('Two')
                    assert runtime.group()['now'] == expected[3], f'{name} repeated update changed selection'
                    check(3)
                # A broken sibling is skipped without losing the representable connections.
                replace_documents(builder(values, partial=True))
                for index in range(4):
                    check(index)
                for index, path, wrong in negative_controls:
                    changed = copy.deepcopy(values)
                    field = changed[index]
                    for part in path[:-1]:
                        field = field[part]
                    field[path[-1]] = wrong
                    replace_documents(builder(changed))
                    check(index, False)
                    replace_documents(builder(values))
                    check(index)
                check(3)
                valid = subscription.responses['/two']
                for body, extra, status in [(body, 0, 200) for body in malformed] + [
                        (valid[0], 11, 200), (valid[0], 0, 503)]:
                    subscription.responses['/two'] = (body, {}, extra, status)
                    before = runtime.group()
                    try:
                        refresh('Two')
                        raise AssertionError(f'{name} failed response replaced the authenticated set')
                    except HTTPError as error:
                        assert error.code == 503, 'unexpected provider update failure status'
                    after = runtime.group()
                    assert set(after['all']) == set(before['all']) and after['now'] == before['now'], \
                        f'{name} failed update changed the old set or chosen member'
                    check(3)
                    subscription.responses['/two'] = valid
                    refresh('Two')
                    check(3)
                check_dns()

            controls = [(1, ['password'], 'incorrect-account'),
                        (2, ['tls', 'server_name'], 'wrong.test'),
                        (2, ['transport', 'path'], '/wrong-path'),
                        (3, ['tls', 'reality', 'short_id'], '87b65a24')]
            exercise_format('Clash', clash_documents, nodes,
                            [b'proxies: [', b'proxies: []\n',
                             b'proxies:\n  - {name: Incomplete, type: vless, password: "' + links.PASSWORD.encode() + b'"}\n'],
                            controls)
            exercise_format('raw-links', raw_documents, nodes,
                            [b'# no connections\r\n', b'vless://\r\n',
                             b'http://test%ZZ:synthetic-payload@127.0.0.1:1#Incomplete\r\n'], controls)

            ss_relays = []
            for index, method in enumerate(['aes-128-gcm', 'chacha20-ietf-poly1305']):
                port = links.free_port()
                inbound = {'type': 'shadowsocks', 'tag': 'ss-peer', 'listen': '127.0.0.1', 'listen_port': port,
                           'method': method, 'password': SS_PASSWORDS[index], 'network': 'tcp'}
                processes.append(stack.enter_context(peer_core(core, output / f'ss-peer-{index}', inbound,
                                                               origin.server_address[1])))
                relay = links.serve(stack, Relay)
                relay.target = port
                ss_relays.append(relay)
                ss_nodes.append({'type': 'shadowsocks', 'tag': 'Node', 'server': '127.0.0.1',
                                 'server_port': relay.server_address[1], 'method': method, 'password': SS_PASSWORDS[index]})
            active_peers[:] = ss_relays * 2
            uses_origin[:] = [True] * 4
            markers[:] = [b'profile-loopback-origin'] * 4
            exercise_format('SIP008', sip008_documents, ss_nodes * 2,
                            [b'{"servers":[', b'{"servers":[]}',
                             b'{"servers":[{"server":"127.0.0.1","password":"' + SS_PASSWORDS[0].encode() + b'"}]}'],
                            [(0, ['password'], 'incorrect-account'), (3, ['password'], 'incorrect-account')])
            # Both SS peers return the same origin marker: the peer counter must still distinguish them.
            saved = expected[0]
            expected[0] = expected[1]
            try:
                try:
                    check(0)
                    raise RuntimeError('traffic oracle accepted another Shadowsocks peer')
                except AssertionError as error:
                    assert str(error) == 'connection bypassed the protocol peer'
            finally:
                expected[0] = saved
            check(0)
            for index in [0, 1]:
                runtime.choose(expected[index])
                before_peer, before_origin = active_peers[index].hits, origin.hits
                reply = links.request(runtime.port, trap.server_address[1])
                assert b'profile-loopback-origin' not in reply
                assert active_peers[index].hits == before_peer + 1 and origin.hits == before_origin, \
                    'Shadowsocks test peer allowed an unrelated target or bypassed the peer'
                check_side_effects()
            active_peers[:] = [plain, secure, ws_relay, reality_relay]
            uses_origin[:] = [False, False, True, True]
            markers[:] = [b'http-authenticated', b'https-authenticated', b'profile-loopback-origin', b'profile-loopback-origin']
            active_format = 'Xray'
            def xray_document(item):
                source = {'tag': 'Node', 'protocol': item['type']}
                if item['type'] == 'http':
                    source['settings'] = {'servers': [{'address': item['server'], 'port': item['server_port'],
                                                       'users': [{'user': item['username'], 'pass': item['password']}]}]}
                else:
                    source['settings'] = {'vnext': [{'address': item['server'], 'port': item['server_port'],
                                                     'users': [{'id': item['uuid'], 'encryption': 'none'}]}]}
                stream = {'network': 'tcp'}
                if item.get('transport'):
                    stream.update({'network': 'ws', 'wsSettings': copy.deepcopy(item['transport'])})
                    stream['wsSettings'].pop('type')
                if item.get('tls'):
                    tls_options = item['tls']
                    settings = {'serverName': tls_options['server_name'], 'allowInsecure': False}
                    reality = tls_options.get('reality')
                    if reality:
                        settings.update({'publicKey': reality['public_key'], 'shortId': reality['short_id'],
                                         'fingerprint': tls_options['utls']['fingerprint']})
                    stream.update({'security': 'reality' if reality else 'tls',
                                   'realitySettings' if reality else 'tlsSettings': settings})
                source['streamSettings'] = stream
                return {'remarks': 'Node', 'outbounds': [source],
                        'dns': {'servers': [{'address': '127.0.0.1', 'port': client_dns.server_address[1]}]},
                        'routing': {'rules': [{'type': 'field', 'port': '0-65535', 'outboundTag': 'client-only'}]},
                        'inbounds': [{'protocol': 'http', 'listen': '127.0.0.1', 'port': forbidden_ports[0]}],
                        'log': {'access': str(forbidden_files[0]), 'error': str(forbidden_files[1]), 'loglevel': 'debug'},
                        'api': {'listen': f'127.0.0.1:{forbidden_ports[1]}', 'services': ['HandlerService']},
                        'stats': {}, 'policy': {'system': {'statsOutboundUplink': True}}}

            for encoded in [False, True]:
                for path, values in [('/one', nodes[:2]), ('/two', nodes[2:])]:
                    body = json.dumps([xray_document(item) for item in values]).encode()
                    subscription.responses[path] = (base64.b64encode(body) if encoded else body, {}, 0)
                refresh('One')
                refresh('Two')
                expected[:] = ['main/One/Node', 'main/One/Node-1', 'main/Two/Node', 'main/Two/Node-1']
                assert set(runtime.group()['all']) == set(expected), 'Xray namespace lost duplicate display names'
                for index in range(4):
                    check(index)
                check_dns()
            # The oracle must reject a successful response from another authenticated connection.
            saved = expected[3]
            expected[3] = expected[0]
            try:
                try:
                    check(3)
                    raise RuntimeError('traffic oracle accepted another authenticated peer')
                except AssertionError as error:
                    assert str(error) == 'connection 3 did not reach its authenticated loopback peer'
            finally:
                expected[3] = saved
            own_dns.answer = '198.18.0.99'
            try:
                try:
                    check_dns()
                    raise RuntimeError('DNS oracle accepted another resolver answer')
                except AssertionError as error:
                    assert str(error) == 'DNS oracle detected another resolver answer'
            finally:
                own_dns.answer = '198.18.0.42'
            check(3)
            check_dns()
            processes.remove(process)
        before_hits = subscription.hits
        # No scheduled updates: the unchanged source must restore from the ordinary LoKi cache.
        with runtime.running() as process:
            processes.append(process)
            assert runtime.group()['now'] == expected[3], 'cached profile changed the selected subscription member'
            for index in range(4):
                check(index)
            assert subscription.hits == before_hits, 'cache restoration unexpectedly fetched a subscription'
            check_dns()
            processes.remove(process)
    # Only the consumer logs are product diagnostics. Synthetic inbound peers can log a rejected UUID.
    # Error logs and shared masked output have separate privacy checks.
    secrets = [links.USER, links.PASSWORD, links.AUTH, UUID, SHORT_ID, keys['publickey'], keys['privatekey'],
               'incorrect-account', '65f676b9-cb1f-45b4-a824-a0a5856cf009', 'client-api-key-must-not-apply',
               'synthetic-payload']
    secrets += SS_PASSWORDS + capacity_secrets
    for log in directory.glob('core-*.log'):
        content = log.read_text()
        for number, value in enumerate(secrets):
            assert value not in content, f'core log exposed synthetic credential {number}'
    source = output / 'profile-to-mask.json'
    private_json(source, {'outbounds': nodes + ss_nodes})
    program = output / 'mask.uc'
    program.write_text('let fs=require("fs");let m=require("diagnostics.mask");'
                       'let v=json(fs.readfile(getenv("PROFILE_SOURCE")));'
                       'print(sprintf("%J",{config:m.sing_box_config(v),text:m.text(sprintf("%J",v),[],[],m.credentials(v))}));')
    command = ['ucode', '-L', str(links.ROOT / 'tests/fakes'), '-L', str(links.ROOT / 'tests/lib'),
               '-L', str(links.ROOT / 'forkop/files/usr/lib'), str(program)]
    masked = subprocess.run(command, env={**os.environ, 'PROFILE_SOURCE': str(source)},
                            check=True, capture_output=True, timeout=10).stdout
    for number, value in enumerate(secrets[:5] + [keys['publickey']] + SS_PASSWORDS):
        assert value.encode() not in masked, f'masked output exposed synthetic credential {number}'
    (output / 'masked-profile.json').write_bytes(masked)
    (output / 'masked-profile.json').chmod(0o600)
    private_json(output / 'results.json', results)
    private_json(output / 'capacity-observations.json', capacity)
    if measure_sizes:
        private_json(output / 'size-observations.json', measurements)
    print(json.dumps({'connection_checks': len(results), 'oracle_controls': 3,
                      'peer_safety_controls': 4, 'size_observations': len(measurements),
                      'capacity_workloads': len(capacity),
                      'formats': sorted({result['format'] for result in results})}))


if __name__ == '__main__':
    if len(sys.argv) not in [3, 4] or len(sys.argv) == 4 and sys.argv[3] != '--measure-sizes':
        raise SystemExit('Usage: subscription_profiles.py CORE NEW_OUTPUT_DIR [--measure-sizes]')
    main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), len(sys.argv) == 4)
