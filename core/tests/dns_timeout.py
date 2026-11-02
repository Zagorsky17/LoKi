"""Measure generated DNS deadlines using only loopback peers.

Usage: python3 core/tests/dns_timeout.py CORE OUTPUT_DIR
CORE must be a trusted, previously verified pinned binary. OUTPUT_DIR must be new.
TCP keepalive queries prevent the inbound's independent 10s idle deadline from
masking the DNS client deadline; a 12s/11s control proves that on capable cores.
"""
import contextlib
import copy
import json
from pathlib import Path
import re
import select
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time

from compatibility import REFERENCE_VERSION, SCHEMA_BOUNDARIES
from plain_links import free_port, generate_fixture


def query(name, identifier):
    return (struct.pack('!HHHHHH', identifier, 0x100, 1, 0, 0, 0)
            + b''.join(bytes([len(label)]) + label.encode() for label in name.split('.'))
            + b'\0' + struct.pack('!HH', 1, 1))


def response(packet):
    return packet[:2] + struct.pack('!HHHHH', 0x8183, 1, 0, 0, 0) + packet[12:]


class DNS(socketserver.BaseRequestHandler):
    def handle(self):
        packet, sock = self.request
        self.server.queries.append(packet)
        if packet[12:] == query('silent.test', 0)[12:]:
            return
        if packet[12:] == query('late.test', 0)[12:]:
            if self.server.stop.wait(self.server.delay):
                return
        sock.sendto(response(packet), self.client_address)


def version(binary):
    result = subprocess.run([str(binary), 'version'], check=True, capture_output=True, text=True, timeout=10)
    value = result.stdout.splitlines()[0].removeprefix('sing-box version ')
    assert value in (REFERENCE_VERSION, *SCHEMA_BOUNDARIES), f'Uncharacterized core: {value}'
    return value


def assert_check(value, duration, status, message):
    if duration and value in ('1.12.22', '1.13.21'):
        assert status == 1 and 'unknown field "timeout"' in message, (status, message)
        return False
    assert status == 0, (status, message)
    return True


def assert_outcome(outcome, elapsed, expected, lower, upper, log, core_version=REFERENCE_VERSION):
    assert outcome == expected, (outcome, expected, elapsed)
    assert lower <= elapsed <= upper, (elapsed, lower, upper)
    if outcome == 'deadline':
        diagnostic = any(('silent.test' in line or 'late.test' in line)
                         and 'context deadline exceeded' in line for line in log.splitlines())
        # Stock 1.14.4 closes async DNS streams without logging the exchange error.
        if core_version == '1.14.4' and not diagnostic:
            assert not re.search(r'\b(ERROR|FATAL|PANIC)\b', log), 'unexpected core error'
        else:
            assert diagnostic, 'missing target DNS deadline error'


def exchange(port, name, process):
    target, keepalive = query(name, 1234), query('keepalive.test', 5678)
    with socket.create_connection(('127.0.0.1', port), timeout=2) as client:
        client.settimeout(1)
        start = time.monotonic()
        deadline, next_keepalive = start + 14, start
        client.sendall(struct.pack('!H', len(target)) + target)
        pending = b''
        while True:
            now = time.monotonic()
            assert process.poll() is None, 'core exited during the query'
            if now >= deadline:
                raise AssertionError('absolute query deadline exceeded despite keepalive traffic')
            if now >= next_keepalive:
                try:
                    client.sendall(struct.pack('!H', len(keepalive)) + keepalive)
                except (BrokenPipeError, ConnectionResetError):
                    return 'deadline', time.monotonic() - start
                next_keepalive = now + .4
            if not select.select([client], [], [], min(.1, deadline - now))[0]:
                continue
            try:
                data = client.recv(65535)
            except ConnectionResetError:
                data = b''
            if not data:
                return 'deadline', time.monotonic() - start
            pending += data
            while len(pending) >= 2:
                size = int.from_bytes(pending[:2], 'big')
                assert size >= 12, 'malformed DNS response frame'
                if len(pending) < size + 2:
                    break
                packet, pending = pending[2:size + 2], pending[size + 2:]
                identifier = int.from_bytes(packet[:2], 'big')
                assert identifier in (1234, 5678), 'unexpected DNS response ID'
                if identifier == 1234:
                    if packet == response(target):
                        return 'answer', time.monotonic() - start
                    assert packet[3] & 15 == 2, 'unexpected target DNS response'
                    return 'deadline', time.monotonic() - start
                assert packet == response(keepalive), 'unexpected keepalive response'


def run(binary, output, core_version, case, setting, explicit, name, delay, expected, lower, upper):
    directory = output / case
    directory.mkdir(mode=0o700)
    with contextlib.ExitStack() as stack:
        peer = socketserver.ThreadingUDPServer(('127.0.0.1', 0), DNS)
        peer.daemon_threads = True
        peer.delay, peer.queries, peer.stop = delay, [], threading.Event()
        threading.Thread(target=peer.serve_forever, kwargs={'poll_interval': .02}, daemon=True).start()
        stack.callback(peer.server_close)
        stack.callback(peer.shutdown)
        stack.callback(peer.stop.set)
        settings = {'dns_server': [f'127.0.0.1:{peer.server_address[1]}'],
                    'bootstrap_dns_server': ['127.0.0.1'], 'unified_delay': '0'}
        if setting:
            settings['dns_timeout'] = setting
        generated = generate_fixture({'settings': settings, 'section': [
            {'.name': 'main', 'action': 'bypass', 'destinations': 'example.test'}]}, directory)
        assert generated['dns'].get('timeout') == (None if setting in (None, '10s') else setting)
        (directory / 'generated.json').write_text(json.dumps(generated, indent=2))
        dns = copy.deepcopy(generated['dns'])
        dns['servers'] = [item for item in dns['servers'] if item['tag'] == 'dns-server']
        dns.update(rules=[], disable_cache=True)
        if explicit:
            dns['timeout'] = explicit
        port = free_port()
        config = {'log': {'level': 'debug'}, 'dns': dns,
                  'inbounds': [{'type': 'direct', 'tag': 'probe', 'listen': '127.0.0.1',
                                'listen_port': port, 'network': 'tcp'}],
                  'outbounds': [{'type': 'direct', 'tag': 'direct'}],
                  'route': {'rules': [{'action': 'hijack-dns'}], 'final': 'direct'}}
        path = directory / 'runtime.json'
        path.write_text(json.dumps(config, indent=2))
        checked = subprocess.run([str(binary), 'check', '-c', str(path)], capture_output=True, text=True, timeout=10)
        (directory / 'check.log').write_text(checked.stdout + checked.stderr)
        if not assert_check(core_version, dns.get('timeout'), checked.returncode, checked.stdout + checked.stderr):
            return {'case': case, 'schema_refusal': 'unknown field "timeout"'}
        log_path = directory / 'core.log'
        with log_path.open('w') as log:
            process = subprocess.Popen([str(binary), 'run', '-c', str(path)], stdout=log, stderr=log)
            try:
                ready = time.monotonic() + 5
                while True:
                    assert process.poll() is None, log_path.read_text()
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1):
                            break
                    except OSError:
                        assert time.monotonic() < ready, 'core did not become ready'
                        time.sleep(.02)
                outcome, elapsed = exchange(port, name, process)
                assert process.poll() is None, 'core exited after the query'
                assert any(packet[12:] == query(name, 0)[12:] for packet in peer.queries), 'target never reached the DNS peer'
                assert_outcome(outcome, elapsed, expected, lower, upper, log_path.read_text(), core_version)
                if outcome == 'deadline':
                    recovery, recovery_elapsed = exchange(port, 'healthy.test', process)
                    assert (recovery == 'answer' and recovery_elapsed < 1), 'DNS did not recover after the deadline'
                return {'case': case, 'outcome': outcome, 'seconds': round(elapsed, 3), 'upstream_queries': len(peer.queries)}
            finally:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)


def main(binary, output):
    core_version = version(binary)
    output.mkdir(mode=0o700, parents=True)
    cases = [
        ('healthy-default', None, None, 'healthy.test', 0, 'answer', 0, 1),
        ('omitted-default-silent', None, None, 'silent.test', 0, 'deadline', 9.4, 12),
        ('explicit-setting-default-late9', '10s', None, 'late.test', 9, 'answer', 8.7, 10.5),
        ('omitted-default-late11', None, None, 'late.test', 11, 'deadline', 9.4, 10.8),
        ('explicit-core-default-silent', '10s', '10s', 'silent.test', 0, 'deadline', 9.4, 12),
        ('custom-short-silent', '400ms', None, 'silent.test', 0, 'deadline', .25, 1.5),
        ('custom-long-late11', '12s', None, 'late.test', 11, 'answer', 10.7, 13.4),
    ]
    rows = []
    for case in cases:
        row = run(binary, output, core_version, *case)
        rows.append(row)
        print(json.dumps(row), flush=True)
    (output / 'results.json').write_text(json.dumps(rows, indent=2))
    print(f'{len(rows)} DNS deadline checks passed for {core_version}; loopback only')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(*(Path(value).resolve() for value in sys.argv[1:]))
