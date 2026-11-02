"""Exercise generated selectors and detours through loopback proxy cascades.

Usage: python3 core/tests/cascade_links.py CORE NEW_OUTPUT_DIR [REFERENCE_R3]
Binaries must be trusted and verified; official CORE needs a parser reference.
Only local synthetic peers are contacted. Production configuration is not applied.
"""
import contextlib
import copy
import json
from pathlib import Path
import select
import socket
import ssl
import subprocess
import sys
import time
from urllib.parse import quote
import plain_links as links


class Hop(links.Proxy):
    def handle(self):
        self.connection.settimeout(3)
        try:
            line = self.rfile.readline(8193).decode().strip()
            headers = self.headers()
            if self.server.reject_auth or headers.get('proxy-authorization') != links.AUTH:
                self.server.rejected += 1
                self.wfile.write(b'HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                return
            # Never let a test peer become a general purpose forwarding proxy.
            wanted = f'CONNECT 127.0.0.1:{self.server.target[1]} HTTP/1.1'
            if line != wanted:
                self.server.denied += 1
                self.wfile.write(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                return
            self.server.records.append(line)
            if self.server.cut:
                self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n')
                self.wfile.flush()
                links.exact(self.rfile, 1)
                self.server.cut_count += 1
                return
            try:
                upstream = socket.create_connection(self.server.target, timeout=3)
            except OSError:
                self.server.upstream_refused += 1
                self.wfile.write(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
                return
            with upstream:
                self.wfile.write(b'HTTP/1.1 200 Connection established\r\n\r\n')
                self.wfile.flush()
                deadline = time.monotonic() + 6
                transferred = 0
                while transferred < 65536:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError('local relay exceeded its deadline')
                    ready, _, _ = select.select([self.connection, upstream], [], [], remaining)
                    if not ready:
                        raise TimeoutError('local relay timed out')
                    for source in ready:
                        data = source.recv(16384)
                        if not data:
                            return
                        transferred += len(data)
                        (upstream if source is self.connection else self.connection).sendall(data)
                raise AssertionError('local relay exceeded its byte limit')
        except (EOFError, OSError):
            pass
        except Exception as error:
            self.server.failures.append(str(error))


def hop(stack, target, tls=None, port=0):
    server = links.serve(stack, Hop, tls, port)
    server.target = ('127.0.0.1', target)
    server.cut, server.cut_count = False, 0
    server.denied, server.upstream_refused = 0, 0
    return server


def generate(uri, relay, hop_tls, output):
    hop_node = {'type': 'http', 'tag': 'Entry', 'server': '127.0.0.1', 'server_port': relay.server_address[1],
                'username': links.USER, 'password': links.PASSWORD}
    if hop_tls:
        hop_node['tls'] = {'enabled': True}
    fixture = {'settings': {'dns_server': ['127.0.0.1'], 'bootstrap_dns_server': ['127.0.0.1'], 'unified_delay': '0'},
               'section': [{'.name': 'hop', 'label': 'Hop', 'action': 'connection', 'outbound_jsons': [json.dumps(hop_node)]},
                           {'.name': 'main', 'label': 'Main', 'action': 'connection'}],
               'connection_link': [{'.name': 'link', 'section': 'main', 'name': 'Node', 'uri': uri, 'detour_section': 'hop'}]}
    product = links.generate_fixture(fixture, output)
    node = next(item for item in product['outbounds'] if item['tag'] == 'Main/Node')
    assert node['type'] != 'parser' and node['detour'] == 'Hop'
    return product


def counts(relay, peer):
    return len(relay.records), len(peer.records)


def reached(relay, peer, before):
    assert len(relay.records) == before[0] + 1, 'request bypassed the configured hop'
    assert len(peer.records) == before[1] + 1, 'request did not reach the selected exit exactly once'


def guard(relay, certificate):
    before = relay.denied
    with socket.create_connection(relay.server_address, timeout=3) as sock:
        if relay.tls:
            context = ssl.create_default_context(cafile=str(certificate))
            sock = context.wrap_socket(sock, server_hostname='127.0.0.1')
        with sock:
            sock.sendall(f'CONNECT 192.0.2.1:443 HTTP/1.1\r\nProxy-Authorization: {links.AUTH}\r\n\r\n'.encode())
            assert b'403 Forbidden' in sock.recv(4096)
    assert relay.denied == before + 1, 'relay target allowlist was not reached'


def main(core, output, reference):
    output.mkdir(mode=0o700, parents=True)
    certificate, trusted = links.test_certificate(output, 'trusted')
    _, untrusted = links.test_certificate(output, 'untrusted')
    results = []
    with contextlib.ExitStack() as stack:
        trap = links.serve(stack, links.Trap)
        for secure_hop in (False, True):
            for scheme in ('http', 'https', 'socks5'):
                peer_tls = trusted if scheme == 'https' else None
                peer = links.serve(stack, links.Proxy, peer_tls)
                peer_port = peer.server_address[1]
                relay = hop(stack, peer_port, trusted if secure_hop else None)
                relay_port = relay.server_address[1]
                guard(relay, certificate)
                auth = quote(links.USER, safe='') + ':' + quote(links.PASSWORD, safe='')
                uri = f'{scheme}://{auth}@127.0.0.1:{peer_port}#Node'
                label = ('tls-hop-' if secure_hop else 'plain-hop-') + scheme
                product = generate(uri, relay, secure_hop, output)
                path = output / f'{label}-generated.json'
                path.write_text(json.dumps(product))
                subprocess.run([str(core), 'check', '-c', str(path)], check=True, capture_output=True, timeout=10)
                native = copy.deepcopy(product['outbounds'])
                for index, item in enumerate(native):
                    if item['tag'] == 'Main/Node':
                        native[index] = {'type': 'parser', 'tag': item['tag'], 'detour': item['detour'], 'link': uri}
                # A successful response alone must not make a bypass look correct.
                mutant = copy.deepcopy(product['outbounds'])
                next(item for item in mutant if item['tag'] == 'Main/Node').pop('detour')
                before = counts(relay, peer)
                with links.running(core, mutant, 'Main', output / f'{label}-mutant', certificate) as (port, _):
                    assert links.request(port, trap.server_address[1]).endswith(links.MARKER)
                assert len(peer.records) == before[1] + 1
                try:
                    reached(relay, peer, before)
                except AssertionError as error:
                    assert str(error) == 'request bypassed the configured hop'
                else:
                    raise AssertionError('the oracle accepted a removed detour')
                results.append({'case': label, 'variant': 'mutant', 'state': 'bypass-detected'})
                for variant, binary, outbounds in [('parser', reference, native),
                                                  ('converted-reference', reference, product['outbounds']),
                                                  ('converted-target', core, product['outbounds'])]:
                    work = output / f'{label}-{variant}'
                    with links.running(binary, outbounds, 'Main', work, certificate) as (port, process):
                        def check(state, success, counter=None):
                            assert process.poll() is None, 'a peer fault terminated the core'
                            before = counts(relay, peer)
                            refused = counter() if counter else 0
                            reply = links.request(port, trap.server_address[1])
                            assert process.poll() is None, 'a peer fault terminated the core'
                            if success:
                                assert reply.endswith(links.MARKER), f'{label}/{variant}/{state}: recovery failed'
                                reached(relay, peer, before)
                            else:
                                assert links.MARKER not in reply and len(peer.records) == before[1]
                                if counter:
                                    # The client can finish before the server consumes its TLS alert.
                                    deadline = time.monotonic() + 3.5
                                    while counter() <= refused and time.monotonic() < deadline:
                                        time.sleep(.01)
                                    assert counter() > refused, f'{label}/{variant}/{state}: the intended peer fault was not reached'
                            assert trap.hits == 0, 'traffic bypassed the selected proxy cascade'
                            assert not relay.failures and not peer.failures, (relay.failures, peer.failures)
                            results.append({'case': label, 'variant': variant, 'state': state, 'accepted': success})
                        check('initial', True)
                        relay.reject_auth = True
                        check('hop-auth', False, lambda: relay.rejected)
                        relay.reject_auth = False
                        check('hop-auth-restored', True)
                        peer.reject_auth = True
                        check('exit-auth', False, lambda: peer.rejected)
                        peer.reject_auth = False
                        check('exit-auth-restored', True)
                        relay.cut = True
                        check('hop-cut', False, lambda: relay.cut_count)
                        relay.cut = False
                        check('hop-cut-restored', True)
                        if secure_hop:
                            relay.tls = untrusted
                            check('hop-tls', False, lambda: relay.tls_rejected)
                            relay.tls = trusted
                            check('hop-tls-restored', True)
                        if peer_tls:
                            peer.tls = untrusted
                            check('exit-tls', False, lambda: peer.tls_rejected)
                            peer.tls = trusted
                            check('exit-tls-restored', True)
                        relay.shutdown()
                        relay.server_close()
                        check('hop-offline', False)
                        relay = hop(stack, peer_port, trusted if secure_hop else None, relay_port)
                        check('hop-restarted', True)
                        peer.shutdown()
                        peer.server_close()
                        check('exit-offline', False, lambda: relay.upstream_refused)
                        peer = links.serve(stack, links.Proxy, peer_tls, peer_port)
                        check('exit-restarted', True)
                    with links.running(binary, outbounds, 'Main', output / f'{label}-{variant}-restart', certificate) as (port, _):
                        before = counts(relay, peer)
                        assert links.request(port, trap.server_address[1]).endswith(links.MARKER)
                        reached(relay, peer, before)
                        assert trap.hits == 0
                    results.append({'case': label, 'variant': variant, 'state': 'core-restarted', 'accepted': True})
                relay.shutdown()
                relay.server_close()
                peer.shutdown()
                peer.server_close()
    (output / 'results.json').write_text(json.dumps(results, indent=2))
    print(f'{len(results)} loopback cascade checks passed; bypass control, peer faults and recovery verified')


if __name__ == '__main__':
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    core, output = (Path(value).resolve() for value in sys.argv[1:3])
    reference = Path(sys.argv[3]).resolve() if len(sys.argv) == 4 else core
    main(core, output, reference)
