"""Read native procfs and create empty child namespaces; never change host mounts or routes."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOUNTS = "1 1 0:1 / / rw - overlay overlay rw\n2 1 0:2 / /proc rw - proc proc rw\n"


class NativeScope(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.geteuid() != 0:
            raise AssertionError("Run as root for read-only PID1 access and empty unshare children")
        cls.binary = shutil.which("ucode")
        if cls.binary is None:
            raise AssertionError("ucode is required; do not skip the native check")

    def run_ucode(self, program, *args, namespace=None):
        command = [self.binary, "-L", str(ROOT / "loki/files/usr/lib"), "-e",
                   'let fs=require("fs");let p=require("service.preflight_scope");' + program, *map(str, args)]
        if namespace:
            command = ["unshare", "--" + namespace, "--", *command]
        done = subprocess.run(command, capture_output=True, text=True, timeout=10)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stderr, "")
        return json.loads(done.stdout)

    def test_native_procfs_mountinfo_and_pid1_relative_scope(self):
        self.assertEqual(self.run_ucode('print(sprintf("%J",p.parse_mountinfo(fs.readfile("/proc/self/mountinfo"))));'), {})
        result = self.run_ucode('print(sprintf("%J",p.check(p.snapshot())));')
        self.assertEqual(result, dict(kind="environment", object="namespace-layout", state="checked",
                                      reason="environment-pid1-relative-scope-checked"))
        for private in ("net:[", "mnt:[", "inode", "overlay", "/proc/1/root"):
            self.assertNotIn(private, json.dumps(result))

    def test_unrelated_missing_path_does_not_poison_the_mountinfo_stream(self):
        result = self.run_ucode('''fs.lstat("/proc/self/loki-scope-missing-private");
            print(sprintf("%J",p.check(p.snapshot())));''')
        self.assertEqual(result["state"], "checked")
        self.assertEqual(result["reason"], "environment-pid1-relative-scope-checked")

    def test_actual_network_and_mount_namespace_mismatch_does_not_change_the_parent(self):
        before = {kind: os.readlink("/proc/self/ns/" + kind) for kind in ("mnt", "net")}
        mounts = Path("/proc/self/mountinfo").read_bytes()
        for namespace in ("net", "mount"):
            result = self.run_ucode('print(sprintf("%J",p.check(p.snapshot())));', namespace=namespace)
            self.assertEqual(result["state"], "incomplete")
            self.assertEqual(result["reason"], "environment-namespace-differs-from-pid1")
            self.assertNotIn(":[", json.dumps(result))
        self.assertEqual(before, {kind: os.readlink("/proc/self/ns/" + kind) for kind in before})
        self.assertEqual(mounts, Path("/proc/self/mountinfo").read_bytes())

    def test_native_file_read_accepts_exact_budget_and_rejects_the_lookahead_byte(self):
        prefix = MOUNTS.replace("overlay overlay", "overlay " + "x" * (262144 - len(MOUNTS) + len("overlay")), 1)
        self.assertEqual(len(prefix), 262144)
        with tempfile.TemporaryDirectory(prefix="loki-scope-read-") as directory:
            path = Path(directory) / "synthetic-private-mountinfo"
            for suffix, expected in (("", None), ("x", "environment-mountinfo-limit")):
                path.write_text(prefix + suffix)
                path.chmod(0o600)
                result = self.run_ucode('''let open=fs.open;let stat=fs.lstat;
                    fs.lstat=(path)=>stat(path=="/proc/self/mountinfo"?ARGV[0]:path);
                    fs.open=(path,mode)=>open(path=="/proc/self/mountinfo"?ARGV[0]:path,mode);
                    let result=p.snapshot();print(sprintf("%J",{error:result.error}));''', path)
                self.assertEqual(result["error"], expected)


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Run these executable checks only on Linux")
    unittest.main()
