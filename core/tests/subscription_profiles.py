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
from urllib.parse import quote
import plain_links as links
import subscription_selection as selection

UUID = '8e2948ac-2437-49b3-80d8-421628bd16cd'
SHORT_ID = '13a25b36'


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
    results, measurements = [], []
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
            peer = [plain, secure, ws_relay, reality_relay][index]
            before, before_origin = peer.hits if index >= 2 else len(peer.records), origin.hits
            reply = links.request(runtime.port, trap.server_address[1] if index < 2 else origin.server_address[1])
            body = reply.split(b'\r\n\r\n', 1)[-1]
            expected_body = [b'http-authenticated', b'https-authenticated', b'profile-loopback-origin', b'profile-loopback-origin'][index]
            if successful:
                assert body == expected_body, f'connection {index} did not reach its authenticated loopback peer'
                assert (peer.hits if index >= 2 else len(peer.records)) == before + 1, 'connection bypassed the protocol peer'
                if index >= 2:
                    assert origin.hits == before_origin + 1
            else:
                assert body != expected_body, 'invalid connection parameters still reached the marker'
                assert origin.hits == before_origin, 'invalid connection reached the origin'
                if index < 2:
                    assert len(peer.records) == before
                else:
                    assert peer.hits > before, 'negative control did not reach its protocol peer'
            check_side_effects()
            results.append({'connection': index, 'result': 'authenticated-loopback' if successful else 'refused'})

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
                cached = [path.read_bytes() for path in (directory / 'cache.db.rule-sets').iterdir() if path.is_file()]
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
               'incorrect-account', '65f676b9-cb1f-45b4-a824-a0a5856cf009', 'client-api-key-must-not-apply']
    for log in directory.glob('core-*.log'):
        content = log.read_text()
        for number, value in enumerate(secrets):
            assert value not in content, f'core log exposed synthetic credential {number}'
    source = output / 'profile-to-mask.json'
    private_json(source, {'outbounds': nodes})
    program = output / 'mask.uc'
    program.write_text('let fs=require("fs");let m=require("diagnostics.mask");'
                       'let v=json(fs.readfile(getenv("PROFILE_SOURCE")));'
                       'print(sprintf("%J",{config:m.sing_box_config(v),text:m.text(sprintf("%J",v),[],[],m.credentials(v))}));')
    command = ['ucode', '-L', str(links.ROOT / 'tests/fakes'), '-L', str(links.ROOT / 'tests/lib'),
               '-L', str(links.ROOT / 'forkop/files/usr/lib'), str(program)]
    masked = subprocess.run(command, env={**os.environ, 'PROFILE_SOURCE': str(source)},
                            check=True, capture_output=True, timeout=10).stdout
    for number, value in enumerate(secrets[:5] + [keys['publickey']]):
        assert value.encode() not in masked, f'masked output exposed synthetic credential {number}'
    (output / 'masked-profile.json').write_bytes(masked)
    (output / 'masked-profile.json').chmod(0o600)
    private_json(output / 'results.json', results)
    if measure_sizes:
        private_json(output / 'size-observations.json', measurements)
    print(json.dumps({'connection_checks': len(results), 'oracle_controls': 2,
                      'peer_safety_controls': 2, 'size_observations': len(measurements)}))


if __name__ == '__main__':
    if len(sys.argv) not in [3, 4] or len(sys.argv) == 4 and sys.argv[3] != '--measure-sizes':
        raise SystemExit('Usage: subscription_profiles.py CORE NEW_OUTPUT_DIR [--measure-sizes]')
    main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), len(sys.argv) == 4)
