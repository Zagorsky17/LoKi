#!/usr/bin/env python3
"""Verify repeated connection errors and shutdown summaries using loopback only."""
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import time

if len(sys.argv) != 3:
    raise SystemExit(f'Usage: {sys.argv[0]} CORE-BINARY OUTPUT-DIRECTORY')
core, work = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
work.mkdir(parents=True, exist_ok=True, mode=0o700)

def free_port():
    with socket.socket() as peer:
        peer.bind(('127.0.0.1', 0))
        return peer.getsockname()[1]

def exact(peer, size):
    data = b''
    while len(data) < size:
        part = peer.recv(size - len(data))
        if not part:
            raise AssertionError('SOCKS peer closed early')
        data += part
    return data

# Keep the destination bound without listening: TCP must fail locally without contacting a service.
with socket.socket() as refused:
    refused.bind(('127.0.0.1', 0))
    destination = refused.getsockname()[1]
    inbound = free_port()
    config = {'log': {'level': 'warn', 'disabled': False},
              'inbounds': [{'type': 'socks', 'tag': 'local', 'listen': '127.0.0.1', 'listen_port': inbound}],
              'outbounds': [{'type': 'direct', 'tag': 'direct'}]}
    path, log = work / 'config.json', work / 'core.log'
    path.write_text(json.dumps(config))
    with log.open('wb') as output:
        process = subprocess.Popen([str(core), 'run', '-c', str(path)], stdout=output, stderr=output)
        try:
            deadline = time.monotonic() + 5
            while True:
                assert process.poll() is None, log.read_text()
                try:
                    with socket.create_connection(('127.0.0.1', inbound), timeout=.1):
                        break
                except OSError:
                    assert time.monotonic() < deadline, 'core did not open its local SOCKS port'
                    time.sleep(.01)

            def fail_connection():
                with socket.create_connection(('127.0.0.1', inbound), timeout=2) as peer:
                    peer.sendall(b'\x05\x01\x00')
                    assert exact(peer, 2) == b'\x05\x00'
                    peer.sendall(b'\x05\x01\x00\x01\x7f\x00\x00\x01' + struct.pack('!H', destination))
                    reply = exact(peer, 4)
                    assert reply[0] == 5 and reply[1] != 0, 'connection unexpectedly succeeded'

            started = time.monotonic()
            for _ in range(100):
                fail_connection()
            assert time.monotonic() - started < 5, 'burst exceeded its test window'
            needle = f'open connection to 127.0.0.1:{destination}'
            time.sleep(.05)
            assert log.read_text().count(needle) == 1, log.read_text()
            time.sleep(max(0, started + 10.1 - time.monotonic()))
            fail_connection()
            for _ in range(10):
                fail_connection()
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
                raise AssertionError('core did not stop normally')
    text = log.read_text()
    assert process.returncode == 0, text
    assert text.count(needle) == 2, text
    assert text.count('99 repeated error messages suppressed') == 1, text
    assert text.count('10 repeated error messages suppressed') == 1, text
    errors = [line for line in text.splitlines() if 'ERROR' in line]
    assert len(errors) == 4, text
    result = {'failed_connections': 111, 'error_lines': len(errors),
              'log_bytes': log.stat().st_size, 'interval_summary': 99, 'shutdown_summary': 10}
    (work / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
