"""Dependency and package metadata scans must fit the preflight child's resource budget."""
import json
from pathlib import Path
import resource
import shutil
import signal
import subprocess
import os
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def child_limits():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_AS, (64 * 1024 * 1024, 64 * 1024 * 1024))
    resource.setrlimit(resource.RLIMIT_CPU, (1, 1))


class DependencyBudget(unittest.TestCase):
    def test_exact_constraints_fit_without_changing_byte_limits(self):
        binary = shutil.which("ucode")
        self.assertIsNotNone(binary, "ucode is required; do not skip the resource check")
        required = ["libc", "ca-bundle", "ucode", "ucode-mod-fs", "ucode-mod-resolv", "ucode-mod-socket",
                    "ucode-mod-ubus", "ucode-mod-uloop", "ucode-mod-uci", "uclient-fetch", "kmod-nft-tproxy",
                    "nftables", "kmod-nft-nat", "ip", "luci-base"]
        name, version = "l" + "x" * 127, "1" + "0" * 127
        program = '''let p=require("service.preflight_dependencies");let rows=p.check(json(ARGV[0]),ARGV[1]);
            assert(length(rows)==15&&length(filter(rows,row=>row.state=="checked"))==15);print("budget-ok");'''
        for kind in ["ipk", "apk"]:
            with self.subTest(format=kind):
                packages = [dict(name=item, version="1", depends="", provides="") for item in required]
                requirement = name + (" (= " + version + ")" if kind == "ipk" else "=" + version)
                packages[2]["depends"] = (", " if kind == "ipk" else " ").join([requirement] * 24)
                self.assertLessEqual(len(packages[2]["depends"]), 8192)
                packages.append(dict(name=name, version=version, depends="", provides=""))
                command = [binary, "-L", str(ROOT / "loki/files/usr/lib"), "-e", program, json.dumps(packages), kind]
                process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                           preexec_fn=child_limits, start_new_session=True)
                try:
                    stdout, stderr = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=5)
                    self.fail("valid exact dependency check exceeded the five-second deadline")
                self.assertEqual(process.returncode, 0, "child resource/check failure: " + stderr)
                self.assertEqual((stdout, stderr), ("budget-ok", ""))


    def test_apk_package_scan_fits_without_changing_record_limits(self):
        binary = shutil.which("ucode")
        self.assertIsNotNone(binary, "ucode is required; do not skip the APK resource check")
        program = '''let fs=require("fs"),apk=require("service.preflight_apk");
            let result=apk.parse(fs.readfile(ARGV[0]));
            if (ARGV[1]=="valid") assert(result.error==null&&length(result.packages)==4096);
            else assert(result.error=="apk-package-limit");
            print("apk-budget-ok");'''
        for count, expected in [(4096, "valid"), (4097, "limit")]:
            with self.subTest(packages=count), tempfile.NamedTemporaryFile(mode="w") as fixture:
                fixture.write("".join("P:p" + str(i) + "\nV:1.0-r1\nA:all\nS:100\nI:100\n\n" for i in range(count)))
                fixture.flush()
                command = [binary, "-L", str(ROOT / "loki/files/usr/lib"), "-e", program, fixture.name, expected]
                process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                           preexec_fn=child_limits, start_new_session=True)
                try:
                    stdout, stderr = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate(timeout=5)
                    self.fail("APK metadata scan exceeded the five-second deadline")
                self.assertEqual(process.returncode, 0, "APK child resource/check failure: " + stderr)
                self.assertEqual((stdout, stderr), ("apk-budget-ok", ""))


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Run these executable checks only on Linux")
    unittest.main()
