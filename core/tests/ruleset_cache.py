"""Exercise persistent SRS through authenticated traffic over loopback peers.

Usage: python3 core/tests/ruleset_cache.py CORE NEW_OUTPUT_DIR [--r5-core CORE]
Use trusted LoKi binaries. No host routes, router services or external endpoints change.
"""
import argparse
import contextlib
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import sys
import time
from urllib.error import HTTPError

import plain_links as links
import subscription_selection as selection


class Rules(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.requests.append((self.path, self.headers.get("If-None-Match")))
        if self.server.mode == "unavailable":
            status, body = 503, b"synthetic unavailable"
        elif self.server.mode == "invalid":
            status, body = 200, b"synthetic invalid SRS"
        elif self.headers.get("If-None-Match") == self.server.etag:
            status, body = 304, b""
        else:
            status, body = 200, self.server.payload
        self.send_response(status)
        self.send_header("ETag", self.server.etag)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def marker(port, domain):
    with socket.create_connection(("127.0.0.1", port), timeout=3) as connection:
        connection.sendall(f"CONNECT {domain}:443 HTTP/1.1\r\nHost: {domain}:443\r\n\r\n".encode())
        headers = b""
        while not headers.endswith(b"\r\n\r\n") and len(headers) < 8192:
            part = connection.recv(1)
            assert part, "core closed the synthetic CONNECT"
            headers += part
        assert headers.startswith(b"HTTP/1.1 200 "), "synthetic CONNECT was refused"
        connection.sendall(f"GET /test HTTP/1.1\r\nHost: {domain}\r\nConnection: close\r\n\r\n".encode())
        reply = b""
        while len(reply) < 16384:
            part = connection.recv(4096)
            if not part:
                break
            reply += part
        assert reply.startswith(b"HTTP/1.1 200 "), "synthetic peer did not answer"
        return reply.split(b"\r\n\r\n", 1)[1]


def snapshot(directory):
    result = {}
    for path in sorted([directory, *directory.rglob("*")]):
        info = path.lstat()
        assert not path.is_symlink(), "private cache contains a symlink"
        expected = 0o700 if path.is_dir() else 0o600
        assert stat.S_IMODE(info.st_mode) == expected, "private cache permissions changed"
        assert info.st_uid == os.getuid(), "private cache owner changed"
        if path.is_file():
            assert info.st_nlink == 1, "private cache file is hardlinked"
        result[str(path.relative_to(directory))] = {
            "mode": stat.S_IMODE(info.st_mode), "inode": info.st_ino,
            "mtime": info.st_mtime_ns, "ctime": info.st_ctime_ns,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None,
        }
    return result


@contextlib.contextmanager
def running(core, config, directory, label, api_port):
    path = directory / (label + ".json")
    path.write_text(json.dumps(config))
    with (directory / (label + ".log")).open("wb") as log:
        process = subprocess.Popen([str(core), "run", "-c", str(path)], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 8
            while True:
                assert process.poll() is None, "core exited before provider API readiness"
                try:
                    selection.api(api_port, "/providers/rules/Rules")
                    break
                except (OSError, ValueError, KeyError):
                    assert time.monotonic() < deadline, "provider API startup timed out"
                    time.sleep(.02)
            yield process
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
                raise AssertionError("core did not stop after SIGTERM")


def main(core, output, old_core=None):
    os.umask(0o077)
    output.mkdir(mode=0o700, parents=True)
    cache = output / "cache"
    cache.mkdir(mode=0o700)
    compiled = {}
    for name, domain in [("A", "target.test"), ("B", "targat.test")]:
        source, binary = output / (name + ".json"), output / (name + ".srs")
        source.write_text(json.dumps({"version": 3, "rules": [{"domain": [domain]}]}))
        with (output / ("compile-" + name + ".log")).open("wb") as log:
            subprocess.run([str(core), "rule-set", "compile", "--output", str(binary), str(source)],
                           stdout=log, stderr=log, check=True, timeout=15)
        compiled[name] = binary.read_bytes()
    assert len(compiled["A"]) == len(compiled["B"]), "SRS corruption control must preserve body size"
    cases = []
    observations = []
    with contextlib.ExitStack() as stack:
        peers = {name: links.serve(stack, selection.Proxy) for name in ("A", "B")}
        for name, peer in peers.items():
            peer.marker = name
        server = links.serve(stack, Rules)
        server.payload, server.etag, server.mode, server.requests = compiled["A"], '"fixture-A"', "valid", []
        port, api_port = links.free_port(), links.free_port()
        while port == api_port:
            api_port = links.free_port()
        url = f"http://127.0.0.1:{server.server_address[1]}/rules.srs"
        config = {
            "log": {"disabled": True},
            "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": port}],
            "outbounds": [{"type": "http", "tag": name, "server": "127.0.0.1",
                           "server_port": peer.server_address[1], "username": links.USER,
                           "password": links.PASSWORD} for name, peer in peers.items()] +
                         [{"type": "direct", "tag": "download"}],
            "route": {
                "rule_set": [{"type": "remote", "tag": "Rules", "format": "binary",
                              "url": url, "download_detour": "download", "update_interval": "24h"}],
                "rules": [{"rule_set": ["Rules"], "action": "route", "outbound": "A"}],
                "final": "B",
            },
            "experimental": {
                "cache_file": {"enabled": True, "path": str(cache / "cache.db"), "cache_id": "srs-fixture"},
                "clash_api": {"external_controller": f"127.0.0.1:{api_port}", "secret": selection.API_SECRET},
            },
            "certificate": {"store": "none"},
        }
        def expect(name, expected, domain="target.test"):
            assert marker(port, domain) == expected.encode(), name + ": route reached the wrong peer"
            cases.append(name)

        def refresh():
            return selection.api(api_port, "/providers/rules/Rules", "PUT")

        if old_core:
            with running(old_core, config, output, "r5-origin", api_port):
                expect("r5-owned-cache-source", "A")
            snapshot(cache)
            server.mode = "unavailable"
            count = len(server.requests)
            with running(core, config, output, "r5-migrated", api_port):
                expect("r5-cache-first-r6-open", "A")
            assert len(server.requests) == count, "r6 did not reuse the owned r5 cache offline"
            server.mode = "valid"

        with running(core, config, output, "online", api_port) as process:
            expect("initial-binary", "A")
            refresh()
            assert server.requests[-1][1] == '"fixture-A"', "conditional request lost its cached ETag"
            expect("not-modified", "A")
            bodies = list((cache / "cache.db.rule-sets").iterdir())
            before = {path.name: path.read_bytes() for path in bodies if path.is_file()}
            assert before, "the real SRS did not reach the file-backed cache"
            server.mode = "invalid"
            try:
                refresh()
                raise AssertionError("invalid SRS update succeeded")
            except HTTPError as error:
                assert error.code == 503
            expect("invalid-retains-route", "A")
            assert {path.name: path.read_bytes() for path in (cache / "cache.db.rule-sets").iterdir()
                    if path.is_file()} == before
            server.mode, server.payload, server.etag = "valid", compiled["B"], '"fixture-B"'
            refresh()
            expect("updated-route", "B")
            expect("updated-rule-match", "A", "targat.test")
            server.payload, server.etag = compiled["A"], '"fixture-A"'
            refresh()
            expect("repeat-update", "A")
            status = Path(f"/proc/{process.pid}/status").read_text().splitlines()
            observations.append({line.split(":")[0]: line.split(":")[1].strip() for line in status
                                 if line.startswith(("VmRSS:", "VmHWM:"))})
        snapshot(cache)
        server.mode = "unavailable"
        count = len(server.requests)
        for index in range(2):
            with running(core, config, output, f"cached-{index}", api_port):
                expect("offline-cache-" + str(index), "A")
        assert len(server.requests) == count, "fresh cached startup unnecessarily fetched SRS"
        old_probe = "not-requested"
        if old_core:
            before = snapshot(cache)
            path = output / "old-core.json"
            path.write_text(json.dumps(config))
            old = subprocess.run([str(old_core), "run", "-c", str(path)], capture_output=True, timeout=8)
            assert old.returncode != 0 and b"private loki cache storage" in (old.stdout + old.stderr).lower(), \
                "old r5 did not refuse the schema2 cache for the expected reason"
            assert snapshot(cache) == before, "old r5 modified the upgraded cache"
            old_probe = "refused-unchanged"
        config["route"]["rule_set"][0]["url"] = url.replace("/rules.srs", "/another.srs")
        with running(core, config, output, "different-url", api_port):
            expect("URL-hash-refuses-old-body", "B")
        assert any(path == "/another.srs" for path, _ in server.requests), "new URL was not attempted"
        config["route"]["rule_set"][0]["url"] = url
        with running(core, config, output, "original-url", api_port):
            expect("URL-miss-preserves-original-cache", "A")
        bodies = {path: path.read_bytes() for path in (cache / "cache.db.rule-sets").iterdir()
                  if path.is_file() and path.read_bytes() == compiled["A"]}
        assert bodies, "expected cached binary representation is missing"
        try:
            for path, body in bodies.items():
                path.write_bytes(compiled["B"])
            with running(core, config, output, "corrupt-body", api_port):
                expect("same-size-corruption-refused", "B")
                expect("same-size-valid-SRS-refused", "B", "targat.test")
        finally:
            for path, body in bodies.items():
                path.write_bytes(body)
        with running(core, config, output, "restored-body", api_port):
            expect("restored-binary-cache", "A")
        snapshot(cache)
        for peer in peers.values():
            assert not peer.failures and not peer.rejected, "synthetic proxy authentication failed"
    result = {"cases": cases, "r5_downgrade": old_probe, "resources": observations,
              "resource_scope": "Linux process observations, not a router budget"}
    (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"{len(cases)} native SRS/cache routing checks passed; r5 probe: {old_probe}")


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Run these executable checks only on the Linux test server")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("core", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--r5-core", type=Path)
    args = parser.parse_args()
    main(args.core.resolve(), args.output.resolve(), args.r5_core.resolve() if args.r5_core else None)
