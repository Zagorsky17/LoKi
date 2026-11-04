#!/usr/bin/env python3
"""Native manifest and read-only collector boundaries; run only on Linux."""

import copy
import hashlib
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
LIMIT = 536870912
SPEC = importlib.util.spec_from_file_location("candidate_builder", ROOT / "build_candidate_manifest.py")
BUILDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n"


def entry(path, directory=False):
    return {"path": path, "type": "directory" if directory else "file", "mode": 493 if directory else 420,
            "uid": 0, "gid": 0, "size": 0 if directory else 1, "sha256": None if directory else "a" * 64}


def candidate():
    return {"schema": 1, "components": [{"role": "backend", "package": "loki", "version": "1.0.0",
            "architecture": "all", "format": "ipk", "artifact": {"name": "loki_1.0.0_all.ipk",
            "size": 1, "sha256": "b" * 64}, "files": [entry("/", True), entry("/synthetic-candidate")]}]}


class ManifestHarness:
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.root.chmod(0o755)
        self.manifest = self.root / "candidate-manifest.json"
        self.binary = shutil.which("ucode")
        self.assertIsNotNone(self.binary, "ucode is required; do not skip this native check")

    def write(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        parent = path.parent
        while parent != self.root:
            parent.chmod(0o755)
            parent = parent.parent
        path.write_text(data)
        path.chmod(0o644)

    def invoke(self, data, collect=False):
        self.write(self.manifest, data)
        expression = ('let p=require("service.preflight"); print(sprintf("%J",p.collect(ARGV[0],ARGV[1])));'
                      if collect else 'let p=require("service.preflight_manifest"); let fs=require("fs"); '
                      'print(sprintf("%J",p.parse(fs.readfile(ARGV[1]))));')
        result = subprocess.run([self.binary, "-L", str(ROOT / "loki/files/usr/lib"), "-e", expression,
                                 str(self.root), str(self.manifest)], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)


class ManifestBoundary(ManifestHarness, unittest.TestCase):
    def test_canonical_ascii_and_integer_boundaries(self):
        value = candidate()
        component = value["components"][0]
        component["version"] = "V0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+._~-"
        path = "/ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.+@-"
        component["files"][1]["path"] = path
        for size in (0, 1, LIMIT):
            component["artifact"]["size"] = max(1, size)
            component["files"][1]["size"] = size
            result = self.invoke(canonical(value))
            self.assertNotIn("error", result)
            self.assertIn(path, result["paths"])

    def test_duplicate_keys_at_every_level_are_not_lost(self):
        data = canonical(candidate())
        for key, value in (("schema", "1"), ("role", '"backend"'), ("size", "1"), ("uid", "0")):
            for replacement in (f'"{key}":{value},"{key}":{value}',
                                f'"{key}":null,"{key}":{value}'):
                altered = data.replace(f'"{key}":{value}', replacement, 1)
                self.assertEqual(self.invoke(altered).get("error"), "manifest-noncanonical")
        self.assertEqual(self.invoke(data.replace('"uid":0', '"\\u0075id":0,"uid":0', 1)).get("error"),
                         "manifest-noncanonical")

    def test_noncanonical_unknown_and_wrong_numeric_types_fail(self):
        data = canonical(candidate())
        for numeric in ("0.0", "0e0", "-0", "true", "null", "-1", "18446744073709551616"):
            self.assertIn("error", self.invoke(data.replace('"uid":0', '"uid":' + numeric, 1)))
        self.assertEqual(self.invoke(json.dumps(candidate()) + "\n")["error"], "manifest-noncanonical")
        value = candidate()
        value["extra"] = "synthetic-secret"
        self.assertEqual(self.invoke(canonical(value))["error"], "manifest-schema-invalid")
        value = candidate()
        value["components"][0]["files"][1]["extra"] = 1
        self.assertEqual(self.invoke(canonical(value))["error"], "manifest-file-invalid")

    def test_paths_types_and_permissions_refuse_without_normalizing(self):
        for path in ("relative", "//file", "/x/../file", "/./file", "/x/", "/a\\b", "/a\nsecret", "/a\u0000b", "/é"):
            value = candidate()
            value["components"][0]["files"][1]["path"] = path
            self.assertIn("error", self.invoke(canonical(value)))
        for key, val in (("type", "symlink"), ("type", "fifo"), ("uid", 1), ("gid", 1), ("mode", 0o775),
                         ("mode", 0o4755), ("size", LIMIT + 1), ("sha256", "x" * 64)):
            value = candidate()
            value["components"][0]["files"][1][key] = val
            self.assertIn("error", self.invoke(canonical(value)))

        # POSIX regex matching stops at embedded NUL; validate decoded strings explicitly.
        for field in ("role", "package", "version", "architecture", "format"):
            value = candidate()
            value["components"][0][field] += "\u0000synthetic-secret"
            self.assertIn("error", self.invoke(canonical(value)))
        for group, field in (("artifact", "name"), ("artifact", "sha256"), ("file", "type"), ("file", "sha256")):
            value = candidate()
            item = value["components"][0]["artifact"] if group == "artifact" else value["components"][0]["files"][1]
            item[field] += "\u0000synthetic-secret"
            self.assertIn("error", self.invoke(canonical(value)))

    def test_duplicate_owners_and_missing_parents_refuse(self):
        value = candidate()
        value["components"][0]["files"].append(copy.deepcopy(value["components"][0]["files"][1]))
        self.assertEqual(self.invoke(canonical(value))["error"], "manifest-path-duplicate")
        value = candidate()
        value["components"][0]["files"][1]["path"] = "/missing/file"
        self.assertEqual(self.invoke(canonical(value))["error"], "manifest-parent-missing-or-not-directory")
        value = candidate()
        second = copy.deepcopy(value["components"][0])
        second.update(role="luci", package="luci-app-loki")
        second["artifact"]["name"] = "luci.ipk"
        value["components"].append(second)
        self.assertEqual(self.invoke(canonical(value))["error"], "manifest-owner-ambiguous")
        second["files"][1]["path"] = "/other-file"
        self.assertNotIn("error", self.invoke(canonical(value)), "identical parent directories may be shared")
        second["files"][0]["mode"] = 0o700
        self.assertEqual(self.invoke(canonical(value))["error"], "manifest-owner-ambiguous")

    def test_limits_and_component_set_are_explicit(self):
        self.assertEqual(self.invoke(" " * 2097153)["error"], "manifest-byte-limit")
        value = candidate()
        value["components"][0]["files"] = [entry("/", True)] + [entry(f"/file-{i}") for i in range(4096)]
        self.assertEqual(self.invoke(canonical(value))["error"], "manifest-entry-limit")
        value = candidate()
        value["components"][0]["package"] = "base-files"
        self.assertEqual(self.invoke(canonical(value))["error"], "manifest-component-invalid")

    def opkg(self, paths):
        self.write(self.root / "usr/lib/opkg/status", "Package: foreign\nStatus: install ok installed\n\n")
        self.write(self.root / "usr/lib/opkg/info/foreign.list", "".join(path + "\n" for path in paths))

    def test_consumer_adds_targets_without_hiding_constants_or_disclosing_paths(self):
        self.opkg(["/synthetic-candidate", "/usr/bin/loki-core"])
        data = canonical(candidate())
        result = self.invoke(data, collect=True)
        self.assertFalse(result["install_allowed"])
        self.assertEqual(result["result"], "conflict")
        self.assertNotIn("synthetic-candidate", json.dumps(result))
        self.assertTrue(any(item["object"] == "/usr/bin/loki-core" and item["state"] == "conflict"
                            for item in result["observations"]))
        self.assertTrue(any(item["object"].startswith("candidate-file-") and item["state"] == "conflict"
                            for item in result["observations"]))
        self.assertIn("artifact-provenance-unverified", {item["reason"] for item in result["observations"]})
        self.assertEqual(self.manifest.read_text(), data)

    def test_invalid_sidecar_keeps_original_conflict_and_masks_input(self):
        self.opkg(["/usr/bin/loki-core"])
        result = self.invoke('{"synthetic-secret":true}', collect=True)
        self.assertEqual(result["result"], "conflict")
        self.assertNotIn("synthetic-secret", json.dumps(result))
        self.assertFalse(result["install_allowed"])

    def test_observation_count_is_bounded_without_losing_conflict_result(self):
        value = candidate()
        paths = [f"/candidate-{i}" for i in range(300)]
        value["components"][0]["files"] = [entry("/", True)] + [entry(path) for path in paths]
        self.opkg(paths)
        result = self.invoke(canonical(value), collect=True)
        self.assertEqual(result["result"], "conflict")
        self.assertEqual(len(result["observations"]), 256)
        self.assertEqual(result["observations"][-1]["reason"], "observation-count-limit")
        self.assertTrue(any(item["kind"] == "configuration" and item["state"] == "incomplete"
                            for item in result["observations"]))
        self.assertFalse(result["install_allowed"])


    def test_shared_candidate_directories_are_checked_without_foreign_ownership_conflicts(self):
        value = candidate()
        value['components'][0]['files'] = [entry('/', True), entry('/synthetic-shared', True),
                                            entry('/synthetic-shared/file')]
        self.write(self.root / 'synthetic-shared/file', 'synthetic-secret-body')
        result = self.invoke(canonical(value), collect=True)
        self.assertFalse(result['install_allowed'])
        self.assertTrue(any(item['kind'] == 'files' and item['object'].startswith('candidate-directory-')
                            and item['reason'] == 'candidate-directory-safe' for item in result['observations']))
        self.assertTrue(any(item['kind'] == 'files' and item['object'].startswith('candidate-file-')
                            and item['reason'] == 'candidate-existing-file-origin-unverified' for item in result['observations']))
        self.assertNotIn('synthetic-shared', json.dumps(result))
        self.assertNotIn('synthetic-secret-body', json.dumps(result))

    def test_catalog_cannot_relabel_a_critical_file_as_a_shared_directory(self):
        value = candidate()
        value['components'][0]['files'] = [entry('/', True), entry('/usr', True), entry('/usr/bin', True),
                                            entry('/usr/bin/loki', True)]
        path = self.root / 'usr/bin/loki'
        path.mkdir(parents=True)
        for parent in (path, path.parent, path.parent.parent):
            parent.chmod(0o755)
        result = self.invoke(canonical(value), collect=True)
        self.assertEqual(result['result'], 'conflict')
        self.assertTrue(any(item['reason'] == 'critical-file-target-type-mismatch' for item in result['observations']))
        self.assertTrue(any(item['reason'] == 'candidate-target-type-conflict' for item in result['observations']))
        self.assertFalse(result['install_allowed'])


class ArtifactCatalog(ManifestHarness, unittest.TestCase):
    @staticmethod
    def outer_limits():
        # Keep the RED run safe even when the production process guard is removed.
        resource.setrlimit(resource.RLIMIT_AS, (402653184, 402653184))
        resource.setrlimit(resource.RLIMIT_CPU, (12, 13))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

    def bounded_child(self, command):
        return subprocess.run(command, capture_output=True, text=True, cwd=self.root,
                              timeout=20, preexec_fn=self.outer_limits)

    def package(self, members=None, package="loki", name="synthetic.ipk", outer_extra=None):
        def archive(items):
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode="w:gz", format=tarfile.GNU_FORMAT) as target:
                for path, data, kind in items:
                    info = tarfile.TarInfo(path)
                    info.uid = info.gid = 0
                    info.mode = 0o755 if kind == tarfile.DIRTYPE else 0o644
                    info.type = kind
                    info.size = len(data) if kind == tarfile.REGTYPE else 0
                    info.linkname = "/synthetic-link-target" if kind == tarfile.SYMTYPE else ""
                    target.addfile(info, io.BytesIO(data) if kind == tarfile.REGTYPE else None)
            return stream.getvalue()
        control = archive([("./control", f"Package: {package}\nVersion: 1.0.0\nArchitecture: all\n".encode(), tarfile.REGTYPE),
                           ("./postinst", b"#!/bin/sh\ntouch synthetic-hook-marker\n", tarfile.REGTYPE)])
        payload = archive(members if members is not None else [("./", b"", tarfile.DIRTYPE),
                          ("./synthetic-candidate", b"payload", tarfile.REGTYPE)])
        items = [("./debian-binary", b"2.0\n", tarfile.REGTYPE), ("./control.tar.gz", control, tarfile.REGTYPE),
                 ("./data.tar.gz", payload, tarfile.REGTYPE)]
        if outer_extra is not None:
            items.append(outer_extra)
        path = self.root / name
        path.write_bytes(archive(items))
        return path

    def test_ipk_artifact_to_runtime_roundtrip_hashes_and_no_hook_execution(self):
        package = self.package()
        before = package.read_bytes()
        data = BUILDER.build({"backend": package})
        result = self.invoke(data)
        self.assertNotIn("error", result)
        self.assertEqual(result["paths"]["/synthetic-candidate"]["sha256"], hashlib.sha256(b"payload").hexdigest())
        artifact = json.loads(data)["components"][0]["artifact"]
        self.assertEqual(artifact["sha256"], hashlib.sha256(before).hexdigest())
        self.assertEqual(artifact["size"], len(before))
        self.assertEqual(package.read_bytes(), before)
        self.assertFalse((self.root / "synthetic-hook-marker").exists())
        self.assertEqual(len(json.loads(data)["components"]), 1, "backend-only catalog is supported")

    def test_ipk_rejects_aliases_duplicates_links_and_specials(self):
        for members in [[("../escape", b"x", tarfile.REGTYPE)], [("/absolute", b"x", tarfile.REGTYPE)],
                        [("x", b"1", tarfile.REGTYPE), ("./x", b"2", tarfile.REGTYPE)],
                        [("x", b"", tarfile.SYMTYPE)], [("x", b"", tarfile.LNKTYPE)],
                        [("x", b"", tarfile.FIFOTYPE)], [("x", b"a", tarfile.REGTYPE),
                         ("x/y", b"b", tarfile.REGTYPE)]]:
            with self.assertRaises(BUILDER.InvalidCatalog):
                BUILDER.build({"backend": self.package(members)})
        with self.assertRaises(BUILDER.InvalidCatalog):
            BUILDER.build({"backend": self.package(outer_extra=("./debian-binary", b"2.0\n", tarfile.REGTYPE))})

    def test_ipk_changed_identity_and_truncation_refuse(self):
        with self.assertRaises(BUILDER.InvalidCatalog):
            BUILDER.build({"backend": self.package(package="base-files")})
        package = self.package()
        reader = BUILDER.read_ipk
        def changed(path):
            result = reader(path)
            path.write_bytes(path.read_bytes() + b"changed")
            return result
        with mock.patch.object(BUILDER, "read_ipk", changed), self.assertRaisesRegex(BUILDER.InvalidCatalog, "artifact-changed"):
            BUILDER.build({"backend": package})
        package = self.package()
        package.write_bytes(gzip.compress(gzip.decompress(package.read_bytes()) + b"synthetic-hidden-tail"))
        with self.assertRaisesRegex(BUILDER.InvalidCatalog, "archive-trailing-content"):
            BUILDER.build({"backend": package})
        package = self.package()
        package.write_bytes(package.read_bytes()[:30])
        with self.assertRaises((BUILDER.InvalidCatalog, tarfile.TarError, EOFError)):
            BUILDER.build({"backend": package})

    def test_apk_dump_members_reject_ambiguous_or_unrepresented_metadata(self):
        acl = {"mode": 493, "user": "root", "group": "root"}
        data = {"info": {"name": "loki", "version": "1.0-r0", "arch": "noarch"},
                "paths": [{"acl": acl}, {"name": "etc", "acl": acl, "files": [
                    {"name": "synthetic", "acl": dict(acl, mode=420), "size": 1, "hash": "a" * 64}]}]}
        identity, entries = BUILDER.apk_entries(data)
        self.assertEqual(identity["package"], "loki")
        self.assertEqual([e["path"] for e in entries], ["/", "/etc", "/etc/synthetic"])
        for field, value in (("target", "a000"), ("hash", "bad"), ("size", -1), ("unknown", True)):
            changed = copy.deepcopy(data)
            changed["paths"][1]["files"][0][field] = value
            with self.assertRaises(BUILDER.InvalidCatalog):
                BUILDER.apk_entries(changed)
        for name in ("./etc", "/etc", "etc/", "etc//config", ".."):
            changed = copy.deepcopy(data)
            changed["paths"][1]["name"] = name
            with self.assertRaises(BUILDER.InvalidCatalog):
                BUILDER.apk_entries(changed)
        changed = copy.deepcopy(data)
        changed["paths"][1]["files"].append(copy.deepcopy(changed["paths"][1]["files"][0]))
        with self.assertRaises(BUILDER.InvalidCatalog):
            BUILDER.apk_entries(changed)
        with self.assertRaises(BUILDER.InvalidCatalog):
            json.loads('{"paths":[],"paths":[]}', object_pairs_hook=BUILDER.unique_object)

    def test_builder_cli_repeated_roles_cannot_replace_selected_artifacts(self):
        package = self.package()
        result = subprocess.run([sys.executable, "-B", str(ROOT / "build_candidate_manifest.py"),
                                 "--backend", str(package), "--backend", str(package)],
                                capture_output=True, text=True, cwd=self.root, timeout=20)
        self.assertEqual(result.returncode, 2)
        self.assertIn("component option repeated", result.stderr)
        self.assertFalse((self.root / "candidate-manifest.json").exists())

    def test_cli_bounds_compressed_gnu_and_pax_metadata_before_tarinfo(self):
        output = self.root / "candidate-manifest.json"
        output.write_text("existing-catalog\n")
        chunk = b"\0" * 1048576
        for kind in (tarfile.GNUTYPE_LONGNAME, tarfile.XHDTYPE):
            package = self.root / "metadata.ipk"
            header = tarfile.TarInfo("synthetic-secret-metadata")
            header.type = kind
            header.size = 335544320
            with gzip.open(package, "wb") as stream:
                stream.write(header.tobuf(format=tarfile.GNU_FORMAT))
                for _ in range(header.size // len(chunk)):
                    stream.write(chunk)
                stream.write(b"\0" * 1024)
            self.assertLess(package.stat().st_size, 1048576, "fixture must exercise compressed expansion")
            result = self.bounded_child([sys.executable, "-B", str(ROOT / "build_candidate_manifest.py"),
                                         "--backend", str(package), "--output", str(output)])
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(result.stderr, "candidate-manifest: artifact-resource-limit\n")
            self.assertEqual(result.stdout, "")
            self.assertEqual(output.read_text(), "existing-catalog\n")
            self.assertFalse((self.root / "synthetic-hook-marker").exists())
            self.assertFalse(list(self.root.glob(".candidate-manifest-*")))

    def test_cli_memory_and_cpu_failures_are_fixed_and_limits_are_installed(self):
        output = self.root / "candidate-manifest.json"
        output.write_text("existing-catalog\n")
        script = '''import importlib.util, os, resource, signal, sys
spec = importlib.util.spec_from_file_location("builder", sys.argv[1])
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
mode, output = sys.argv[2:]
def probe(selected, apk):
    assert 0 < resource.getrlimit(resource.RLIMIT_AS)[1] <= 268435456
    soft, hard = resource.getrlimit(resource.RLIMIT_CPU)
    assert 0 < soft <= hard <= 31
    assert resource.getrlimit(resource.RLIMIT_CORE) == (0, 0)
    if mode == "memory":
        raise MemoryError("synthetic-secret")
    os.kill(os.getpid(), signal.SIGXCPU)
    raise AssertionError("CPU signal was not handled")
builder.build = probe
sys.argv = ["builder", "--backend", "synthetic.ipk", "--output", output]
raise SystemExit(builder.main())
'''
        for mode in ("memory", "cpu"):
            result = self.bounded_child([sys.executable, "-B", "-c", script,
                                         str(ROOT / "build_candidate_manifest.py"), mode, str(output)])
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(result.stderr, "candidate-manifest: artifact-resource-limit\n")
            self.assertEqual(result.stdout, "")
            self.assertEqual(output.read_text(), "existing-catalog\n")

    def test_cli_benign_oversized_artifact_has_fixed_error_and_preserves_output(self):
        package = self.root / "oversized.ipk"
        with package.open("wb") as stream:
            stream.truncate(LIMIT + 1)
        output = self.root / "candidate-manifest.json"
        output.write_text("existing-catalog\n")
        result = self.bounded_child([sys.executable, "-B", str(ROOT / "build_candidate_manifest.py"),
                                     "--backend", str(package), "--output", str(output)])
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(result.stderr, "candidate-manifest: artifact-size-limit\n")
        self.assertEqual(result.stdout, "")
        self.assertEqual(output.read_text(), "existing-catalog\n")


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Run these executable checks only on the Linux test server")
    unittest.main()
