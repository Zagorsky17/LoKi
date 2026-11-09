"""Observe bounded 4x25 subscription updates through authenticated loopback peers.

Results describe Linux processes and do not select production or router budgets.
"""
import base64
from concurrent.futures import ThreadPoolExecutor
import contextlib
import gzip
import hashlib
import json
import os
from pathlib import Path
import sys
import threading
import time
from urllib.error import HTTPError
from urllib.parse import quote

import plain_links as links
import subscription_profiles as profiles
import subscription_selection as selection

PROVIDERS = ('P1', 'P2', 'P3', 'P4')
NODES = 25


def memory(pid):
    values = {}
    for line in Path(f'/proc/{pid}/status').read_text().splitlines():
        if line.startswith(('VmRSS:', 'VmHWM:')):
            values[line.split(':', 1)[0].lower() + '_kib'] = int(line.split()[1])
    assert len(values) == 2, 'process memory counters unavailable'
    rollup = Path(f'/proc/{pid}/smaps_rollup')
    if rollup.exists():
        values['pss_kib'] = int(next(line.split()[1] for line in rollup.read_text().splitlines()
                                     if line.startswith('Pss:')))
    return values


class Samples:
    def __init__(self, pid):
        self.pid, self.rows, self.stop = pid, [], threading.Event()
        self.started = time.monotonic()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.error = None

    def run(self):
        while not self.stop.is_set():
            try:
                self.rows.append({'seconds': round(time.monotonic() - self.started, 4), **memory(self.pid)})
            except Exception as error:
                self.error = error
                return
            self.stop.wait(.01)

    def finish(self):
        self.stop.set()
        self.thread.join(timeout=2)
        assert not self.thread.is_alive() and self.rows, 'memory sampling did not finish'
        assert self.error is None, f'memory sampling failed: {self.error}'


class Feed(profiles.Subscription):
    def do_GET(self):
        state = self.server.gate
        if state['armed']:
            with state['condition']:
                state['arrived'].add(self.path)
                state['condition'].notify_all()
            if not state['release'].wait(10):
                self.send_error(503)
                return
        super().do_GET()


def document(nodes, size, forbidden):
    value = {'outbounds': nodes,
             'log': {'output': str(forbidden), 'level': 'trace'},
             'route': {'final': 'synthetic-client-route-must-not-apply'},
             'ignored_tree': [{'index': i, 'values': [i, i + 1, i + 2], 'label': 'A' * 32}
                              for i in range(size // 160)], 'ignored_padding': ''}
    body = json.dumps(value, separators=(',', ':')).encode()
    assert len(body) <= size, 'structured fixture exceeds its declared byte size'
    value['ignored_padding'] = 'A' * (size - len(body))
    body = json.dumps(value, separators=(',', ':')).encode()
    assert len(body) == size
    return body


def encode(body, encoding):
    transport = base64.b64encode(body) if 'base64' in encoding else body
    wire = gzip.compress(transport, mtime=0) if 'gzip' in encoding else transport
    return wire, {'Content-Encoding': 'gzip'} if 'gzip' in encoding else {}, len(transport)


def cache_bytes(directory):
    result = 0
    for path in directory.rglob('*'):
        if path.is_file() and path.relative_to(directory).parts[0].startswith('cache.db'):
            info = path.lstat()
            assert not path.is_symlink() and info.st_uid == os.getuid() and info.st_nlink == 1
            assert info.st_mode & 0o777 == 0o600, 'unsafe cache file mode'
            result += info.st_size
    return result


def main(core, output):
    if sys.platform != 'linux' or os.geteuid() == 0:
        raise SystemExit('Run this test as an unprivileged Linux user')
    cap = next(line.split()[1] for line in Path('/proc/self/status').read_text().splitlines()
               if line.startswith('CapEff:'))
    assert int(cap, 16) == 0, 'Linux capabilities must be absent'
    output.mkdir(mode=0o700, parents=True)
    certificate, tls = links.test_certificate(output, 'loopback')
    observations, oracle_controls = [], 0
    with contextlib.ExitStack() as stack:
        plain = links.serve(stack, selection.Proxy)
        plain.marker = 'unused-http-marker'
        secure = links.serve(stack, selection.Proxy, tls)
        secure.marker = 'unused-https-marker'
        trap = links.serve(stack, links.Trap)
        dns = profiles.dns_peer(stack, '198.18.0.42')
        feed = links.serve(stack, Feed)
        feed.responses = {}
        feed.gate = {'armed': False, 'arrived': set(), 'release': threading.Event(), 'condition': threading.Condition()}
        for encoding in ('raw', 'base64', 'gzip', 'gzip-base64'):
            for size in (262144, 1048576):
                directory = output / f'{encoding}-{size}'
                directory.mkdir(mode=0o700)
                plain.auth_markers, secure.auth_markers = {}, {}
                old, new, expected_old, expected_new = {}, {}, {}, {}
                secrets = []
                for name in PROVIDERS:
                    for version, documents, expected in ((0, old, expected_old), (1, new, expected_new)):
                        members = []
                        for index in range(NODES):
                            encrypted = index % 2 == 1
                            peer = secure if encrypted else plain
                            marker = f'{name}-{index:03d}-v{version}'
                            username, password = marker + '-user', marker + '-password'
                            auth = 'Basic ' + base64.b64encode(f'{username}:{password}'.encode()).decode()
                            secrets.extend((username, password, auth))
                            peer.auth_markers[auth] = marker
                            node = {'type': 'http', 'tag': f'node-{index:03d}', 'server': '127.0.0.1',
                                    'server_port': peer.server_address[1], 'username': username, 'password': password}
                            if encrypted:
                                node['tls'] = {'enabled': True, 'server_name': '127.0.0.1', 'certificate': certificate.read_text()}
                            members.append(node)
                            expected[f'main/{name}/{node["tag"]}'] = (peer, marker.encode(), auth)
                        documents[name] = members
                feed.responses = {'/' + name: (json.dumps({'outbounds': old[name]}).encode(), {}, 0) for name in PROVIDERS}
                fixture = {'settings': {'dns_server': [f'127.0.0.1:{dns.server_address[1]}'],
                            'bootstrap_dns_server': [f'127.0.0.1:{dns.server_address[1]}'], 'unified_delay': '0'},
                           'section': [{'.name': 'main', 'action': 'connection'}],
                           'subscription_url': [{'.name': name, 'section': 'main', 'tag': name,
                               'url': f'http://127.0.0.1:{feed.server_address[1]}/{name}',
                               'subscription_update_enabled': '0'} for name in PROVIDERS]}
                product = links.generate_fixture(fixture, directory)
                product['certificate'] = {'store': 'none', 'certificate_path': str(certificate)}
                runtime = selection.Runtime(core, product, directory, expected_members=100)
                profiles.private_json(runtime.path, json.loads(runtime.path.read_text()))
                forbidden = directory / 'client-log-must-not-exist'

                def check_cache(bodies):
                    cached = [path.read_bytes().split(b'\n', 1)[1]
                              for path in (directory / 'cache.db.subscriptions').iterdir() if path.is_file()]
                    for body in bodies:
                        assert cached.count(body) == 1, 'cache lost or changed a decoded provider body'

                def check(expected):
                    assert set(runtime.group()['all']) == set(expected), 'resource workload lost or merged a member'
                    for tag, (peer, marker, _auth) in expected.items():
                        runtime.choose(tag)
                        before = len(peer.records)
                        reply = links.request(runtime.port, trap.server_address[1])
                        assert reply.split(b'\r\n\r\n', 1)[-1] == marker, 'resource identity oracle detected another node'
                        assert len(peer.records) == before + 1, 'resource workload bypassed its authenticated peer'
                    assert not trap.hits and not forbidden.exists(), 'client globals or direct bypass affected the harness'
                    assert not plain.failures and not secure.failures

                with runtime.running() as process:
                    check(expected_old)
                    old_p4 = feed.responses['/P4'][0]
                    check_cache([old_p4])
                    if oracle_controls == 0:
                        tag = next(iter(expected_old))
                        peer, marker, auth = expected_old[tag]
                        peer.auth_markers[auth] = 'synthetic-wrong-identity'
                        try:
                            try:
                                check(expected_old)
                            except AssertionError as error:
                                assert str(error) == 'resource identity oracle detected another node'
                            else:
                                raise AssertionError('wrong-identity control escaped the traffic oracle')
                        finally:
                            peer.auth_markers[auth] = marker.decode()
                        oracle_controls += 1
                    bodies, wire_sizes, transport_sizes = {}, {}, {}
                    for name in PROVIDERS:
                        body = document(new[name], size, forbidden)
                        bodies[name] = body
                        bad = body[:-1] if name == 'P4' else body
                        wire, headers, transport = encode(bad, encoding)
                        feed.responses['/' + name] = (wire, headers, 0)
                        wire_sizes[name], transport_sizes[name] = len(wire), transport
                    state = feed.gate
                    state['arrived'].clear()
                    state['release'].clear()
                    state['armed'] = True

                    def refresh(name):
                        try:
                            selection.api(runtime.api_port, '/providers/proxies/' + quote('main/' + name, safe=''),
                                          'PUT', timeout=15)
                            return 0
                        except HTTPError as error:
                            return error.code

                    started = time.monotonic()
                    before = memory(process.pid)
                    before_cache = cache_bytes(directory)
                    sampler = Samples(process.pid)
                    sampler.thread.start()
                    try:
                        with ThreadPoolExecutor(max_workers=4) as pool:
                            futures = {name: pool.submit(refresh, name) for name in PROVIDERS}
                            try:
                                with state['condition']:
                                    arrived = state['condition'].wait_for(lambda: len(state['arrived']) == 4, timeout=5)
                                assert arrived, 'the four provider downloads did not overlap'
                            finally:
                                state['release'].set()
                            results = {name: future.result(timeout=20) for name, future in futures.items()}
                        assert results == {'P1': 0, 'P2': 0, 'P3': 0, 'P4': 503}, 'parallel update status changed'
                        mixed = {tag: value for tag, value in expected_new.items() if not tag.startswith('main/P4/')}
                        mixed.update({tag: value for tag, value in expected_old.items() if tag.startswith('main/P4/')})
                        check(mixed)
                        check_cache([bodies[name] for name in PROVIDERS if name != 'P4'] + [old_p4])
                        state['armed'] = False
                        wire, headers, _transport = encode(bodies['P4'], encoding)
                        feed.responses['/P4'] = (wire, headers, 0)
                        assert refresh('P4') == 0
                        check(expected_new)
                        check_cache(list(bodies.values()))
                    finally:
                        state['armed'] = False
                        state['release'].set()
                        sampler.finish()
                    after = memory(process.pid)
                    observations.append({'encoding': encoding, 'decoded_bytes_per_provider': size,
                        'provider_nodes': [25] * 4, 'total_nodes': 100, 'overlapping_downloads': len(state['arrived']),
                        'wire_bytes': wire_sizes, 'transport_decoded_bytes': transport_sizes,
                        'before': before, 'after': after, 'peak_sampled_rss_kib': max(row['vmrss_kib'] for row in sampler.rows),
                        'peak_hwm_kib': max(row['vmhwm_kib'] for row in sampler.rows),
                        'cache_bytes_before': before_cache, 'cache_bytes_after': cache_bytes(directory),
                        'failed_provider_retained': True, 'seconds': round(time.monotonic() - started, 3),
                        'samples': sampler.rows})
                logs = b''.join(path.read_bytes() for path in directory.glob('core-*.log'))
                assert all(secret.encode() not in logs for secret in secrets), 'consumer diagnostics exposed a credential'
    profiles.private_json(output / 'resource-observations.json', {'schema': 1, 'platform': sys.platform,
        'core_sha256': hashlib.sha256(core.read_bytes()).hexdigest(), 'oracle_controls': oracle_controls,
        'observations': observations})
    print(json.dumps({'resource_workloads': len(observations), 'oracle_controls': oracle_controls,
                      'nodes_per_workload': 100, 'production_limits_changed': False}))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: subscription_resources.py TRUSTED_CORE NEW_OUTPUT_DIRECTORY')
    main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
