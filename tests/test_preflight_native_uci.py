#!/usr/bin/env python3
"""Exercise the staged configuration reader with real libuci, without host writes."""

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


def limits():
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

    def check(self, data):
        self.input.write_bytes(data.encode())
        self.input.chmod(0o600)
        expression = '''
            let fs = require("fs");
            global.system = () => die("unexpected external command");
            fs.popen = () => die("unexpected external command");
            let uci = require("uci");
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
            let result = require("service.preflight_config").check(fs.readfile(ARGV[0]), ARGV[1]);
            print(sprintf("%J\\n", { result, calls }));
        '''
        process = subprocess.run([self.binary, "-L", str(LIBRARY), "-e", expression,
                                  str(self.input), str(self.scratch)],
                                 capture_output=True, text=True, timeout=15, preexec_fn=limits)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stderr, "", "native parser diagnostics must not disclose input")
        self.assertEqual(self.input.read_bytes(), data.encode())
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
                                      ("incomplete", "candidate-core-unverified")})

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


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Run these executable checks only on the Linux test server")
    unittest.main()
