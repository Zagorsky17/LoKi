#!/usr/bin/env python3
"""Exercise the staged configuration reader with real libuci, without host writes."""

import hashlib
import json
from pathlib import Path
import resource
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / "loki/files/usr/lib"
DEFAULT = (ROOT / "loki/files/etc/config/loki").read_text()
PLATFORM = {
    "dhcp": "config dnsmasq 'dns'\n option domain 'prepared.lan'\n",
    "system": "config timeserver 'ntp'\n list server 'time.prepared.example'\n",
}


def limits():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_AS, (65536 * 1024, 65536 * 1024))
    resource.setrlimit(resource.RLIMIT_CPU, (10, 10))


class NativeUCI(unittest.TestCase):
    def setUp(self):
        self.binary = shutil.which("ucode")
        self.assertIsNotNone(self.binary, "ucode with the native UCI module is required")
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.scratch = self.root / "scratch"
        self.scratch.mkdir(mode=0o700)
        self.input = self.root / "input"

    def check(self, data, platform=PLATFORM, firewall=False, own_files=None):
        self.input.write_bytes(data.encode())
        self.input.chmod(0o600)
        platform_path = self.root / "platform"
        platform_data = json.dumps(platform).encode()
        platform_path.write_bytes(platform_data)
        platform_path.chmod(0o600)
        expression = '''
            let fs = require("fs");
            global.system = () => die("unexpected external command");
            let popen = fs.popen;
            fs.popen = () => die("unexpected external command");
            let own_files = json(ARGV[4]);
            if (own_files != null) {
                let exec = require("core.exec"), capture = exec.capture;
                fs.popen = popen;
                exec.capture = (argv, ...args) => {
                    assert(length(argv) == 3 && argv[0] == "/bin/busybox" && argv[1] == "sha256sum");
                    assert(match(argv[2], /^\\/proc\\/[0-9]+\\/fd\\/[0-9]+$/));
                    return capture(argv, ...args);
                };
            }
            let uci = require("uci");
            require("service.gateway_secret").load = () => die("persistent controller state accessed");
            let original = uci.cursor;
            let calls = 0;
            uci.cursor = (config, delta, overlay) => {
                assert(config == ARGV[1] + "/config");
                assert(delta == ARGV[1] + "/delta");
                assert(overlay === "");
                assert((fs.lstat(config).mode & 0777) == 0700);
                assert((fs.lstat(delta).mode & 0777) == 0700);
                assert((fs.lstat(config + "/loki").mode & 0777) == 0600);
                calls++;
                return original(config, delta, overlay);
            };
            let platform = json(fs.readfile(ARGV[2]));
            let result = require("service.preflight_config").check(fs.readfile(ARGV[0]), ARGV[1], platform, null,
                ARGV[3] == "" ? null : ARGV[3], own_files == null ? null : { own_files });
            print(sprintf("%J\\n", { result, calls }));
        '''
        process = subprocess.run([self.binary, "-L", str(LIBRARY), "-e", expression,
                                  str(self.input), str(self.scratch), str(platform_path), str(self.root) if firewall else "",
                                  json.dumps(own_files)],
                                 capture_output=True, text=True, timeout=15, preexec_fn=limits)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stderr, "", "native parser diagnostics must not disclose input")
        self.assertEqual(self.input.read_bytes(), data.encode())
        self.assertEqual(platform_path.read_bytes(), platform_data)
        self.assertEqual(list(self.scratch.iterdir()), [], "staged secrets must be removed")
        report = json.loads(process.stdout)
        self.assertNotIn("synthetic-secret", process.stdout)
        return {(item["state"], item["reason"]) for item in report["result"]}, report["calls"]

    def test_default_and_repeated_real_parse(self):
        for _ in range(2):
            result, calls = self.check(DEFAULT)
            self.assertEqual(calls, 1)
            self.assertEqual(result, {("checked", "uci-syntax-checked"),
                                      ("checked", "uci-schema-checked"),
                                      ("checked", "uci-values-checked"),
                                      ("checked", "uci-generation-empty"),
                                      ("incomplete", "candidate-core-unverified"),
                                      ("checked", "dns-uci-policy-checked")})

    def test_quoted_values_lists_and_comments_are_native_uci_data(self):
        data = DEFAULT + '''
# synthetic-secret comment
config section 'example'
    option action 'bypass'
    option label 'synthetic-secret label'
    list domains 'one.example'
    list domains 'two.example'
'''
        result, calls = self.check(data)
        self.assertEqual(calls, 1)
        self.assertIn(("checked", "uci-schema-checked"), result)
        self.assertIn(("checked", "uci-values-checked"), result)
        self.assertIn(("checked", "uci-generation-checked"), result)
        self.assertIn(("incomplete", "candidate-core-unverified"), result)

    def test_foreign_newer_missing_and_unsupported_schemas(self):
        for data, reason in (
            (DEFAULT.replace("config_format 'loki'", "config_format 'forkop'"), "foreign"),
            (DEFAULT.replace("config_version '2.0.0'", "config_version '999.0.0'"), "newer"),
            ("config settings 'settings'\n option config_format 'loki'\n"
             " option label 'synthetic-secret'\n", "missing"),
            (DEFAULT + "\nconfig unknown 'example'\n option label 'synthetic-secret'\n", "schema"),
        ):
            with self.subTest(reason=reason):
                result, calls = self.check(data)
                self.assertEqual(calls, 1)
                self.assertIn(("checked", "uci-syntax-checked"), result)
                self.assertIn(("incomplete", "candidate-schema-" + reason), result)
                self.assertNotIn(("checked", "uci-schema-checked"), result)

    def test_malformed_native_input_is_private_and_cleans_up(self):
        for data in ("synthetic-secret invalid\n", "config settings 'synthetic-secret\n",
                     DEFAULT + "\noption synthetic-secret 'unterminated\n"):
            with self.subTest(data=data[:20]):
                result, calls = self.check(data)
                self.assertEqual(calls, 1)
                self.assertEqual(result, {("incomplete", "uci-load-failed")})

    def test_bounds_reject_before_loading_native_uci(self):
        for data, reason in (("synthetic-secret\0", "candidate-config-invalid"),
                             ("x" * 1048577, "candidate-config-size-limit")):
            result, calls = self.check(data)
            self.assertEqual(calls, 0)
            self.assertEqual(result, {("incomplete", reason)})

    def test_bad_values_cannot_pass_a_valid_native_schema(self):
        for data in (
            DEFAULT.replace("dns_timeout '10s'", "dns_timeout 'synthetic-secret'"),
            DEFAULT.replace("bootstrap_dns_server '77.88.8.8'", "bootstrap_dns_server 'https://synthetic-secret/dns-query'"),
            DEFAULT + "\nconfig section 'example'\n option action 'synthetic-secret'\n",
        ):
            result, calls = self.check(data)
            self.assertEqual(calls, 1)
            self.assertIn(("checked", "uci-schema-checked"), result)
            self.assertIn(("incomplete", "candidate-config-values-invalid"), result)
            self.assertNotIn(("checked", "uci-values-checked"), result)
            self.assertNotIn(("incomplete", "candidate-core-unverified"), result)

    def test_missing_malformed_and_oversized_platform_data_cannot_generate(self):
        data = DEFAULT + "\nconfig section 'example'\n option action 'bypass'\n option destinations 'prepared.example'\n"
        for platform, reason in (
            (None, "candidate-platform-config-unavailable"),
            ({"dhcp": PLATFORM["dhcp"]}, "candidate-platform-config-unavailable"),
            ({**PLATFORM, "system": "synthetic-secret invalid\n"}, "candidate-platform-parse-failed"),
            ({**PLATFORM, "dhcp": "synthetic-secret\0"}, "candidate-platform-config-invalid"),
            ({**PLATFORM, "dhcp": "x" * 1048577}, "candidate-platform-config-invalid"),
        ):
            result, calls = self.check(data, platform)
            self.assertEqual(calls, 1)
            self.assertIn(("checked", "uci-values-checked"), result)
            self.assertIn(("incomplete", reason), result)
            self.assertIn(("incomplete", "candidate-core-unverified"), result)
            self.assertNotIn(("checked", "uci-generation-checked"), result)

    def test_firewall_snapshot_uses_the_same_private_native_cursor_and_never_runs_includes(self):
        (self.root / "etc/nftables.d").mkdir(parents=True)
        script = self.root / "etc/firewall.user"
        script.write_text("echo synthetic-secret\n")
        for data, state in (
            ("config defaults\n", "checked"),
            ("config include\n option path '/etc/firewall.user'\n", "checked"),
            ("config include\n option path '/etc/firewall.user'\n option fw4_compatible '1'\n", "incomplete"),
            ("config include\n option path '/etc/firewall.user'\n option fw4_compatible '1'\n option enabled '0'\n", "checked"),
            ("synthetic-secret malformed\n", "incomplete"),
            ("x" * 1048577, "incomplete"),
        ):
            result, calls = self.check(DEFAULT, {**PLATFORM, "firewall": data}, firewall=True)
            self.assertEqual(calls, 1)
            if state == "checked":
                self.assertIn((state, "nft-persisted-inert-includes-checked"), result)
            else:
                self.assertTrue(any(status == state and reason.startswith("nft-persisted-")
                                    for status, reason in result))
            self.assertEqual(script.read_text(), "echo synthetic-secret\n")

    def test_verified_own_nft_proof_reaches_the_native_firewall_check(self):
        target = "/usr/share/nftables.d/chain-pre/input/loki.nft"
        body = (ROOT / "loki/files" / target.lstrip("/")).read_bytes()
        path = self.root / target.lstrip("/")
        path.parent.mkdir(parents=True)
        path.write_bytes(body)
        proof = {target: {"path": target, "type": "file", "mode": 0o644, "size": len(body),
                          "sha256": hashlib.sha256(body).hexdigest(), "package": "loki", "version": "2"}}
        for changed in (False, True):
            if changed:
                path.write_bytes(body.replace(b"counter accept", b"counter drop  "))
            result, calls = self.check(DEFAULT, {**PLATFORM, "firewall": "config defaults\n"},
                                       firewall=True, own_files=proof)
            self.assertEqual(calls, 1)
            if changed:
                self.assertIn(("incomplete", "nft-persisted-active-include-unverified"), result)
            else:
                self.assertIn(("checked", "nft-persisted-own-and-inert-includes-checked"), result)


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Run these executable checks only on the Linux test server")
    unittest.main()
