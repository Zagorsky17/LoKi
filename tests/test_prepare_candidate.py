#!/usr/bin/env python3
"""Check offline candidate snapshots without executing packages or their core."""

from contextlib import contextmanager
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import prepare_candidate as preparer
import test_preflight_manifest as fixtures


class CandidatePreparation(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.output = self.root / "prepared"
        self.ucode = shutil.which("ucode")
        self.assertIsNotNone(self.ucode, "native ucode is required")
        self.marker = self.root / "unexpected-execution"
        self.core_body = ("#!/bin/sh\ntouch " + str(self.marker) + "\n").encode()
        self.core = self.root / "loki-core"
        self.core.write_bytes(self.core_body)
        self.core.chmod(0o600)
        self.components = fixtures.ComponentPolicy().prepare(fixtures.ComponentPolicy().complete())
        self.selected = self.packages(self.components)

    def archive(self, rows):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w", format=tarfile.GNU_FORMAT) as archive:
            for name, mode, body in rows:
                entry = tarfile.TarInfo(name)
                entry.mode = mode
                entry.type = tarfile.DIRTYPE if body is None else tarfile.REGTYPE
                entry.size = 0 if body is None else len(body)
                archive.addfile(entry, None if body is None else io.BytesIO(body))
        return gzip.compress(stream.getvalue(), mtime=0)

    def packages(self, value):
        selected = {}
        for component in value["components"]:
            control = (f'Package: {component["package"]}\nVersion: {component["version"]}\n'
                       f'Architecture: {component["architecture"]}\n').encode()
            payload = [("." + item["path"], item["mode"], None if item["type"] == "directory" else
                        self.core_body if item["path"] == "/usr/bin/loki-core" else b"synthetic payload\n")
                       for item in component["files"]]
            data = self.archive([("debian-binary", 0o644, b"2.0\n"),
                                 ("control.tar.gz", 0o644, self.archive([("control", 0o644, control),
                                                                       ("postinst", 0o755, self.core_body)])),
                                 ("data.tar.gz", 0o644, self.archive(payload))])
            path = self.root / component["artifact"]["name"]
            path.write_bytes(data)
            path.chmod(0o600)
            selected[component["role"]] = path
        return selected

    def prepare(self, selected=None, core=None):
        return preparer.prepare(self.selected if selected is None else selected, self.core if core is None else core,
                                self.output, self.ucode)

    def command(self):
        command = [sys.executable, "-B", str(ROOT / "prepare_candidate.py"), "--output", str(self.output),
                   "--ucode-bin", self.ucode, "--core-binary", str(self.core)]
        for role, path in self.selected.items():
            command += ["--" + role, str(path)]
        return command

    def assert_snapshot(self, result, selected):
        self.assertEqual(json.loads((self.output / "candidate-prepared.json").read_bytes()), result)
        self.assertFalse(result["install_allowed"])
        self.assertFalse(result["origin_verified"])
        self.assertEqual(result["manifest_sha256"], hashlib.sha256((self.output / "candidate-manifest.json").read_bytes()).hexdigest())
        self.assertEqual((self.output / "candidate-core").read_bytes(), self.core_body)
        self.assertEqual(result["core"]["sha256"], hashlib.sha256(self.core_body).hexdigest())
        self.assertEqual(set(p.name for p in (self.output / "packages").iterdir()), {p.name for p in selected.values()})
        for original in selected.values():
            self.assertEqual((self.output / "packages" / original.name).read_bytes(), original.read_bytes())
        for path in [self.output, *self.output.rglob("*")]:
            self.assertEqual(path.stat().st_mode & 0o777,
                             0o700 if path.is_dir() or path.name == "candidate-core" else 0o600)
        self.assertFalse((self.output / ".candidate-prepared.tmp").exists())
        self.assertFalse(self.marker.exists(), "neither the packaged hook nor the candidate core may run")

    def test_complete_and_no_locale_sets_preserve_inputs_and_make_private_snapshots(self):
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_mode) for path in self.selected.values()}
        for locale in (True, False):
            selected = {role: path for role, path in self.selected.items() if locale or role != "locale"}
            result = self.prepare(selected)
            self.assert_snapshot(result, selected)
            shutil.rmtree(self.output)
        for path, values in before.items():
            self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_mode), values)

    def test_bundle_contains_the_readonly_entry_and_exact_runtime_sources(self):
        result = self.prepare()
        expected = ["LICENSE", "preflight.sh", "preflight.uc", "install.sh", "uninstall.sh", "component-update.sh", "component-update.uc", "loki/files/etc/config/loki"]
        expected += [str(p.relative_to(ROOT)) for p in (ROOT / "loki/files/usr/lib").rglob("*.uc")]
        rows = []
        for name in sorted(expected):
            body = (ROOT / name).read_bytes()
            self.assertEqual((self.output / name).read_bytes(), body)
            rows.append({"path": name, "sha256": hashlib.sha256(body).hexdigest(), "size": len(body)})
        self.assertEqual(result["source"], {"files": len(rows), "sha256": hashlib.sha256(
            (json.dumps(rows, sort_keys=True, separators=(",", ":")) + "\n").encode()).hexdigest()})
        self.assert_snapshot(result, self.selected)

    def test_explicit_manifest_checksum_binds_archives_without_executing_the_core(self):
        result = self.prepare()
        expression = ('let p=require("service.preflight");'
                      'print(sprintf("%J",p.collect("/",ARGV[0],null,null,null,ARGV[1])));')
        def report(digest):
            process = subprocess.run([self.ucode, '-L', str(ROOT/'loki/files/usr/lib'), '-e', expression,
                                      str(self.output/'candidate-manifest.json'), digest],
                                     capture_output=True, text=True, timeout=15)
            self.assertEqual(process.returncode, 0, process.stderr)
            value = json.loads(process.stdout)
            self.assertFalse(value['install_allowed'])
            return {row['reason'] for row in value['observations']}
        self.assertIn('candidate-archives-content-bound', report(result['manifest_sha256']))
        self.assertIn('candidate-content-or-checksum-unverified', report('0'*64))
        artifact = next((self.output/'packages').iterdir())
        artifact.write_bytes(artifact.read_bytes()+b'corrupt')
        self.assertIn('candidate-content-or-checksum-unverified', report(result['manifest_sha256']))
        self.assertFalse(self.marker.exists())

    def test_preflight_checks_bound_core_only_for_the_matching_target_profile(self):
        result = self.prepare()
        system = self.root/'system'
        (system/'etc/config').mkdir(parents=True)
        (system/'usr/lib/opkg').mkdir(parents=True)
        (system/'usr/lib/opkg/status').write_text('Package: base-files\nVersion: 1\nStatus: install ok installed\n\n')
        (system/'etc/config/dhcp').write_text("config dnsmasq 'dns'\n")
        (system/'etc/config/system').write_text("config timeserver 'ntp'\n")
        (system/'proc').mkdir()
        (system/'tmp').mkdir()
        memory = system/'proc/meminfo'
        memory.write_text('MemTotal: 262144 kB\nMemAvailable: 131072 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n')
        scratch = self.root/'check'
        scratch.mkdir(mode=0o700)
        expression = ('let p=require("service.preflight");'
                      'require("service.preflight_scope").snapshot=()=>({identities:{}});'
                      'let e=require("core.exec"),deadline=e.deadline;'
                      'e.deadline=(argv,seconds,limit)=>argv[4]=="/bin/df"?{status:0,output:'
                      '"Filesystem 1024-blocks Used Available Use% Mounted on\\nroot 262144 0 "+'
                      '(ARGV[6]=="low"?"0":"262144")+" 0% /\\ntmpfs 131072 0 131072 0% /tmp\\n"}:deadline(argv,seconds,limit);'
                      'print(sprintf("%J",p.collect(ARGV[0],ARGV[1],ARGV[2],ARGV[3],ARGV[4],ARGV[5])));')
        def report(architecture, low_storage=False):
            (system/'etc/openwrt_release').write_text("DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='24.10.6'\nDISTRIB_ARCH='"+architecture+"'\n")
            process = subprocess.run([self.ucode, '-L', str(ROOT/'loki/files/usr/lib'), '-e', expression,
                                      str(system), str(self.output/'candidate-manifest.json'),
                                      str(self.output/'loki/files/etc/config/loki'), str(scratch), str(self.output),
                                      result['manifest_sha256'], 'low' if low_storage else 'enough'], capture_output=True, text=True, timeout=15)
            self.assertEqual(process.returncode, 0, process.stderr)
            value = json.loads(process.stdout)
            self.assertFalse(value['install_allowed'])
            return {row['reason'] for row in value['observations']}
        self.assertIn('candidate-architecture-mismatch', report('aarch64_generic'))
        self.assertFalse(self.marker.exists())
        memory.write_text('MemTotal: 262144 kB\nMemAvailable: 20480 kB\nSwapTotal: 524288 kB\nSwapFree: 524288 kB\n')
        self.assertIn('resource-candidate-memory-insufficient', report('x86_64'))
        self.assertFalse(self.marker.exists(), 'a low-memory preflight cannot launch even a verified matching core')
        memory.write_text('MemTotal: 262144 kB\nMemAvailable: 131072 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n')
        native = subprocess.run([self.ucode, '-e', 'require("uci");'], capture_output=True, text=True, timeout=5)
        self.assertIn('resource-transaction-storage-insufficient' if native.returncode == 0 else 'uci-unavailable',
                      report('x86_64', low_storage=True))
        self.assertFalse(self.marker.exists(), 'insufficient persistent storage cannot launch a verified matching core')
        reasons = report('x86_64')
        if native.returncode == 0:
            self.assertIn('candidate-core-check-checked', reasons)
            self.assertTrue(self.marker.exists(), 'only the explicitly bound matching check may execute the candidate')
        else:
            self.assertIn('uci-unavailable', reasons)
            self.assertFalse(self.marker.exists())
        self.assertEqual(list(scratch.iterdir()), [])

    def test_source_copy_failure_cannot_publish_a_partial_bundle(self):
        original = preparer.copy_input
        def fail(source, destination, maximum):
            if Path(source) == ROOT / "preflight.sh":
                raise preparer.SourceError("synthetic source read failure")
            return original(source, destination, maximum)
        with mock.patch.object(preparer, "copy_input", side_effect=fail), self.assertRaises(preparer.SourceError):
            self.prepare()
        self.assertFalse(self.output.exists())
        self.assertFalse(self.marker.exists())

    def test_prepared_bundle_runs_the_real_readonly_entry_from_another_directory(self):
        self.prepare()
        launcher = self.output / "linux-preflight.sh"
        launcher.write_text((self.output / "preflight.sh").read_text().replace(
            "PATH=/usr/sbin:/usr/bin:/sbin:/bin\n",
            f"PATH={Path(self.ucode).parent}:/usr/sbin:/usr/bin:/sbin:/bin\n", 1))
        launcher.chmod(0o600)
        result = subprocess.run(["/bin/sh", str(launcher)], cwd="/", capture_output=True, text=True, timeout=20)
        self.assertIn(result.returncode, (1, 2), result.stderr)
        self.assertEqual(result.stderr, "")
        report = json.loads(result.stdout)
        self.assertFalse(report["install_allowed"])
        self.assertFalse(report["complete"])
        reasons = {item["reason"] for item in report["observations"]}
        native = subprocess.run([self.ucode, "-e", 'require("uci");'], capture_output=True, text=True, timeout=5)
        expected = os.environ.get("LOKI_TEST_NATIVE_UCI")
        if expected is not None:
            self.assertIn(expected, ("0", "1"))
            self.assertEqual(native.returncode == 0, expected == "1", native.stderr)
        checked = {"uci-syntax-checked", "uci-schema-checked", "uci-values-checked"}
        if native.returncode == 0:
            self.assertTrue(checked <= reasons)
        else:
            self.assertIn("uci-unavailable", reasons)
            self.assertFalse(checked & reasons)
        self.assertFalse(self.marker.exists(), "preflight cannot execute the packaged hook or candidate core")

    def factory(self):
        factory = self.root / "factory"
        shutil.copytree(ROOT / "loki/files/usr/lib", factory / "loki/files/usr/lib")
        (factory / "loki/files/etc/config").mkdir(parents=True)
        for name in ("LICENSE", "preflight.sh", "preflight.uc", "install.sh", "uninstall.sh", "component-update.sh", "component-update.uc", "loki/files/etc/config/loki"):
            shutil.copyfile(ROOT / name, factory / name)
        return factory

    def test_unsafe_source_file_refuses_the_entire_bundle(self):
        factory = self.factory()
        module = factory / "loki/files/usr/lib/core/constants.uc"
        original = module.read_bytes()
        foreign = self.root / "foreign-source"
        foreign.write_text("foreign-sentinel")
        for kind in ("symlink", "fifo", "writable", "oversized", "empty"):
            module.unlink()
            if kind == "symlink": module.symlink_to(foreign)
            elif kind == "fifo": os.mkfifo(module)
            else:
                module.write_bytes(b"" if kind == "empty" else original)
                if kind == "writable": module.chmod(0o666)
                elif kind == "oversized":
                    with module.open("wb") as stream: stream.truncate(4194305)
            with self.subTest(kind=kind), mock.patch.object(preparer, "ROOT", factory), self.assertRaises(
                    (preparer.SourceError, preparer.catalog.InvalidCatalog)):
                self.prepare()
            self.assertFalse(self.output.exists())
            self.assertFalse(self.marker.exists())
            self.assertEqual(foreign.read_text(), "foreign-sentinel")

    def test_source_count_and_aggregate_byte_boundaries(self):
        for count in (0, 125):
            with mock.patch.object(Path, "rglob", return_value=[ROOT / "loki/files/usr/lib/core/common.uc"] * count), \
                    self.assertRaisesRegex(preparer.catalog.InvalidCatalog, "candidate-source-file-limit"):
                self.prepare()
            self.assertFalse(self.output.exists())
        factory = self.factory()
        count = sum(p.is_file() for p in factory.rglob("*"))
        for number in range(127 - count):
            (factory / f"loki/files/usr/lib/budget{number}.uc").write_text("return {};\n")
        total = sum(p.stat().st_size for p in factory.rglob("*") if p.is_file())
        padding = factory / "loki/files/usr/lib/budget.uc"
        padding.write_bytes(b" " * (4194304 - total))
        with mock.patch.object(preparer, "ROOT", factory):
            self.prepare()
            shutil.rmtree(self.output)
            with padding.open("ab") as stream: stream.write(b" ")
            with self.assertRaises(preparer.SourceError): self.prepare()
            padding.write_text("return {};\n")
            (factory / "loki/files/usr/lib/excess.uc").write_text("return {};\n")
            with self.assertRaisesRegex(preparer.catalog.InvalidCatalog, "candidate-source-file-limit"):
                self.prepare()
        self.assertFalse(self.output.exists())
        self.assertFalse(self.marker.exists())

    def test_apk_solver_controls_abort_each_component_without_publishing_snapshot(self):
        selected = {role: self.root / (role + ".apk") for role in self.selected}
        for path in selected.values():
            path.write_bytes(b"synthetic-apk")
            path.chmod(0o600)
        for damaged in selected:
            for fields, reason in (({"install-if": ["libc"]}, "artifact-extra-dependency-metadata"),
                                   ({"recommends": ["synthetic-secret"]}, "artifact-extra-dependency-metadata"),
                                   ({"layer": 1}, "artifact-layer-metadata")):
                def dump(apk, arguments):
                    if arguments[0] == "verify":
                        return b""
                    role = Path(arguments[-1]).stem
                    data = fixtures.ArtifactCatalog().apk_fixture(**(fields if role == damaged else {}))
                    data["info"]["name"] = preparer.catalog.ROLES[role]
                    data["paths"][1]["files"][0]["name"] = role
                    return json.dumps(data).encode()

                with self.subTest(role=damaged, fields=fields), mock.patch.object(
                        preparer.catalog, "apk_command", side_effect=dump), self.assertRaisesRegex(
                        preparer.catalog.InvalidCatalog, reason):
                    preparer.prepare(selected, self.core, self.output, self.ucode, apk="/synthetic/apk")
                self.assertFalse(self.output.exists())
                self.assertFalse(self.marker.exists())
                self.assertTrue(all(p.read_bytes() == b"synthetic-apk" for p in selected.values()))

    def test_cli_success_and_competing_calls_publish_one_complete_snapshot(self):
        processes = [subprocess.Popen(self.command(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(2)]
        results = []
        for process in processes:
            stdout, stderr = process.communicate(timeout=20)
            results.append((process.returncode, stdout, stderr))
        self.assertEqual(sorted(row[0] for row in results), [0, 2], results)
        success = next(row for row in results if row[0] == 0)
        self.assertEqual(success[2], "")
        self.assert_snapshot(json.loads(success[1]), self.selected)
        failed = next(row for row in results if row[0] == 2)
        self.assertEqual(failed[1], "")
        self.assertNotIn(str(self.root), failed[2])

    def test_existing_file_directory_and_symlink_are_never_replaced(self):
        foreign = self.root / "foreign"; foreign.write_text("keep")
        for kind in ("file", "directory", "symlink"):
            if kind == "file": self.output.write_text("keep")
            elif kind == "directory": self.output.mkdir(); (self.output / "keep").write_text("keep")
            else: self.output.symlink_to(foreign)
            with self.assertRaises(preparer.SourceError): self.prepare()
            self.assertEqual(foreign.read_text(), "keep")
            if kind == "directory": shutil.rmtree(self.output)
            else: self.output.unlink()

    def test_unsafe_parent_or_symlinked_parent_refuses_without_creating_output(self):
        self.root.chmod(0o777)
        try:
            with self.assertRaises(preparer.SourceError): self.prepare()
            self.assertFalse(self.output.exists())
        finally: self.root.chmod(0o700)
        link = self.root / "link"; link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(preparer.SourceError):
            preparer.prepare(self.selected, self.core, link / "prepared", self.ucode)
        self.assertFalse(self.output.exists())

    def test_links_fifo_writable_and_empty_inputs_are_refused_and_cleaned(self):
        for kind in ("symlink", "hardlink", "fifo", "writable", "empty"):
            path = self.root / "unsafe.ipk"
            if kind == "symlink": path.symlink_to(self.selected["backend"])
            elif kind == "hardlink": os.link(self.selected["backend"], path)
            elif kind == "fifo": os.mkfifo(path)
            else: path.write_bytes(b"" if kind == "empty" else b"synthetic"); path.chmod(0o666 if kind == "writable" else 0o600)
            with self.subTest(kind=kind), self.assertRaises((preparer.SourceError, preparer.catalog.InvalidCatalog)):
                self.prepare(dict(self.selected, backend=path))
            self.assertFalse(self.output.exists())
            path.unlink()

    def test_changed_input_is_pinned_and_partial_output_is_removed(self):
        real = preparer.input_file
        changed = self.selected["backend"]

        @contextmanager
        def changing(path, maximum):
            with real(path, maximum) as opened:
                yield opened
                if path == changed:
                    with path.open("ab") as stream: stream.write(b"synthetic-secret")

        with mock.patch.object(preparer, "input_file", changing), self.assertRaises(preparer.SourceError): self.prepare()
        self.assertFalse(self.output.exists())
        self.assertFalse(self.marker.exists())

    def test_missing_roles_foreign_paths_and_mismatched_versions_never_publish(self):
        with self.assertRaises(preparer.catalog.InvalidCatalog): self.prepare({"backend": self.selected["backend"]})
        self.assertFalse(self.output.exists())
        for change in ("foreign-path", "version", "private-mode"):
            value = fixtures.ComponentPolicy().prepare(fixtures.ComponentPolicy().complete())
            if change == "foreign-path": value["components"][0]["files"][0]["path"] = "/etc/banner"
            elif change == "version": value["components"][1]["version"] = "2.0.1"
            else: value["components"][0]["files"][1]["mode"] = 0o644
            with self.subTest(change=change), self.assertRaises(preparer.catalog.InvalidCatalog): self.prepare(self.packages(value))
            self.assertFalse(self.output.exists())

    def test_wrong_core_bytes_empty_and_oversized_core_cannot_publish(self):
        for body in (b"synthetic-secret", b"", self.core_body + b"extra"):
            self.core.write_bytes(body)
            with self.subTest(size=len(body)), self.assertRaises((preparer.SourceError, preparer.catalog.InvalidCatalog)): self.prepare()
            self.assertFalse(self.output.exists())
            self.assertFalse(self.marker.exists())

    def test_oversized_package_refuses_before_copy_or_archive_parsing(self):
        path = self.root / "oversized.ipk"
        with path.open("wb") as stream: stream.truncate(preparer.catalog.LIMIT + 1)
        path.chmod(0o600)
        with self.assertRaises(preparer.SourceError): self.prepare(dict(self.selected, backend=path))
        self.assertFalse(self.output.exists())

    def test_policy_timeout_or_rejection_never_leaves_a_completion_marker(self):
        for outcome in (subprocess.CompletedProcess([], 2, b"synthetic-secret"),
                        subprocess.TimeoutExpired("synthetic-secret", 10)):
            context = mock.patch.object(preparer.subprocess, "run", side_effect=outcome) if isinstance(outcome, Exception) else \
                mock.patch.object(preparer.subprocess, "run", return_value=outcome)
            with context, self.assertRaises((preparer.catalog.InvalidCatalog, subprocess.TimeoutExpired)): self.prepare()
            self.assertFalse(self.output.exists())

    def test_sigkill_leaves_no_complete_marker_and_retry_preserves_partial_data(self):
        waiting = self.root / "policy-waiting"
        tool = self.root / "blocking-policy"
        tool.write_text("#!/usr/bin/python3\nfrom pathlib import Path\nimport time\n"
                        + "Path(" + repr(str(waiting)) + ").touch()\ntime.sleep(30)\n")
        tool.chmod(0o700)
        command = self.command()
        command[command.index("--ucode-bin") + 1] = str(tool)
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 8
            while not waiting.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(waiting.exists(), "the controlled interruption must occur after package staging")
        finally:
            if process.poll() is None: os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=5)
        self.assertEqual(process.returncode, -signal.SIGKILL)
        self.assertTrue((self.output / "candidate-manifest.json").exists())
        self.assertFalse((self.output / "candidate-prepared.json").exists())
        before = (self.output / "candidate-manifest.json").read_bytes()
        with self.assertRaises(preparer.SourceError): self.prepare()
        self.assertEqual((self.output / "candidate-manifest.json").read_bytes(), before)
        self.assertFalse(self.marker.exists())

    def test_io_or_policy_tool_failure_removes_owned_output_and_cli_hides_paths(self):
        with mock.patch.object(preparer, "write_private", side_effect=OSError("synthetic-secret")), self.assertRaises(OSError): self.prepare()
        self.assertFalse(self.output.exists())
        self.selected["backend"].write_bytes(b"synthetic-secret truncated archive")
        result = subprocess.run(self.command(), capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "candidate-prepare: preparation-failed\n")
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Run candidate preparation checks only on Linux")
    unittest.main()
