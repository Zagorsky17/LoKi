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
import signal
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
    def test_candidate_format_must_match_the_safely_read_package_database(self):
        for installed in ("ipk", "apk"):
            opkg = self.root / "usr/lib/opkg/status"
            apk = self.root / "lib/apk/db/installed"
            opkg.unlink(missing_ok=True)
            apk.unlink(missing_ok=True)
            if installed == "ipk":
                self.opkg(["/etc/banner"])
            else:
                self.write(apk, "P:base-files\nV:1.0-r1\nA:noarch\nS:1\nI:1\n\n")
            for requested in ("ipk", "apk"):
                value = candidate()
                value["components"][0]["format"] = requested
                value["components"][0]["artifact"]["name"] = "synthetic-secret." + requested
                report = self.invoke(canonical(value), collect=True)
                reason = "artifact-format-unverified" if installed == requested else "candidate-package-format-mismatch"
                self.assertIn(reason, {item["reason"] for item in report["observations"]})
                self.assertEqual(report["result"], "incomplete" if installed == requested else "conflict")
                self.assertFalse(report["install_allowed"])
                self.assertNotIn("synthetic-secret", json.dumps(report))

    def test_unavailable_unsafe_or_ambiguous_database_cannot_establish_package_format(self):
        value = candidate()
        value["components"][0]["format"] = "apk"
        value["components"][0]["artifact"]["name"] = "synthetic.apk"
        status = self.root / "usr/lib/opkg/status"
        for state in ("absent", "malformed", "writable", "symlink", "both"):
            status.unlink(missing_ok=True)
            if state == "malformed":
                self.write(status, "synthetic-secret\n")
            elif state in ("writable", "symlink", "both"):
                self.opkg(["/etc/banner"])
                if state == "writable":
                    status.chmod(0o666)
                elif state == "symlink":
                    status.rename(status.with_suffix(".keep"))
                    status.symlink_to(status.with_suffix(".keep"))
                else:
                    self.write(self.root / "lib/apk/db/installed", "P:base-files\nV:1\nA:noarch\n\n")
            report = self.invoke(canonical(value), collect=True)
            self.assertIn("package-format-unverified", {item["reason"] for item in report["observations"]}, state)
            self.assertNotIn("candidate-package-format-mismatch", {item["reason"] for item in report["observations"]}, state)
            self.assertFalse(report["install_allowed"])
            self.assertNotIn("synthetic-secret", json.dumps(report))

    def test_changed_database_cannot_establish_a_package_format_conflict(self):
        expression = '''let fs=require("fs"); let p=require("service.preflight");
let open=fs.open; let calls=0; let path=ARGV[2];
fs.open=(name, mode)=>{ if(name==path && ++calls==2) fs.writefile(path,"synthetic-secret\\n"); return open(name,mode); };
print(sprintf("%J",p.collect(ARGV[0],ARGV[1])));'''
        for installed in ("ipk", "apk"):
            opkg = self.root / "usr/lib/opkg/status"
            apk = self.root / "lib/apk/db/installed"
            opkg.unlink(missing_ok=True)
            apk.unlink(missing_ok=True)
            if installed == "ipk":
                self.opkg(["/etc/banner"])
            else:
                self.write(apk, "P:base-files\nV:1\nA:noarch\n\n")
            value = candidate()
            requested = "apk" if installed == "ipk" else "ipk"
            value["components"][0]["format"] = requested
            value["components"][0]["artifact"]["name"] = "synthetic." + requested
            self.write(self.manifest, canonical(value))
            result = subprocess.run([self.binary, "-L", str(ROOT / "loki/files/usr/lib"), "-e", expression,
                                     str(self.root), str(self.manifest), str(opkg if installed == "ipk" else apk)],
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertIn("package-format-unverified", {item["reason"] for item in report["observations"]})
            self.assertNotIn("candidate-package-format-mismatch", {item["reason"] for item in report["observations"]})
            self.assertFalse(report["install_allowed"])
            self.assertNotIn("synthetic-secret", json.dumps(report))

    def test_candidate_architecture_claims_refuse_mismatch_without_exposing_values(self):
        self.write(self.root / "etc/openwrt_release",
                   "DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='25.12.6'\nDISTRIB_ARCH='x86_64'\n")
        value = candidate()
        core = copy.deepcopy(value["components"][0])
        core.update(role="core", package="loki-core", architecture="x86_64")
        core["artifact"]["name"] = "loki-core_1.0.0_x86_64.ipk"
        core["files"][1]["path"] = "/synthetic-core"
        value["components"].append(core)
        matched = self.invoke(canonical(value), collect=True)
        self.assertIn("artifact-architecture-unverified", [item["reason"] for item in matched["observations"]])
        self.assertFalse(matched["install_allowed"])

        value["components"][1]["architecture"] = "mips_24kc"
        mismatch = self.invoke(canonical(value), collect=True)
        self.assertEqual(mismatch["result"], "conflict")
        self.assertIn("candidate-architecture-mismatch", [item["reason"] for item in mismatch["observations"]])
        self.assertNotIn("mips_24kc", json.dumps(mismatch))
        self.assertFalse(mismatch["install_allowed"])

        value["components"][1]["architecture"] = "all"
        self.assertIn("candidate-architecture-mismatch", [item["reason"] for item in
                          self.invoke(canonical(value), collect=True)["observations"]])

        self.write(self.root / "etc/openwrt_release",
                   "DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='25.12.6'\n")
        self.assertIn("openwrt-architecture-unverified", [item["reason"] for item in
                          self.invoke(canonical(value), collect=True)["observations"]])

        self.write(self.root / "etc/openwrt_release",
                   "DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='25.12.6'\nDISTRIB_ARCH='x86_64'\n")
        value["components"][0].update(architecture="noarch", format="apk")
        value["components"][0]["artifact"]["name"] = "loki_1.0.0_noarch.apk"
        value["components"][1].update(architecture="x86_64", format="apk")
        value["components"][1]["artifact"]["name"] = "loki-core_1.0.0_x86_64.apk"
        self.assertIn("artifact-architecture-unverified", [item["reason"] for item in
                          self.invoke(canonical(value), collect=True)["observations"]])
        value["components"][0]["architecture"] = "all"
        self.assertIn("candidate-architecture-mismatch", [item["reason"] for item in
                          self.invoke(canonical(value), collect=True)["observations"]])

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
        value["components"][0]["format"] = "apk"
        value["components"][0]["artifact"]["name"] = "synthetic.apk"
        paths = [f"/candidate-{i}" for i in range(300)]
        value["components"][0]["files"] = [entry("/", True)] + [entry(path) for path in paths]
        self.opkg(paths)
        result = self.invoke(canonical(value), collect=True)
        self.assertEqual(result["result"], "conflict")
        self.assertEqual(len(result["observations"]), 256)
        self.assertEqual(result["observations"][-1]["reason"], "observation-count-limit")
        self.assertIn("candidate-package-format-mismatch", {item["reason"] for item in result["observations"]})
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

    def package(self, members=None, package="loki", name="synthetic.ipk", outer_extra=None, control_extra=""):
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
        control = archive([("./control", (f"Package: {package}\nVersion: 1.0.0\nArchitecture: all\n" + control_extra).encode(), tarfile.REGTYPE),
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

    def apk_fixture(self, **fields):
        acl = {"mode": 493, "user": "root", "group": "root"}
        return {"info": dict(name="loki", version="1.0.0", arch="noarch", **fields),
                "paths": [{"acl": acl}, {"name": "etc", "acl": acl, "files": [
                    {"name": "synthetic", "acl": dict(acl, mode=420), "size": 1, "hash": "a" * 64}]}]}

    def test_ipk_replacement_metadata_and_folded_values_refuse(self):
        for name in ("Provides", "Conflicts", "Replaces"):
            for field in (name, name.lower(), name.upper()):
                for value in (" synthetic-secret\n", "\n synthetic-secret\n"):
                    with self.subTest(field=field, folded=value.startswith("\n")):
                        package = self.package(control_extra=field + ":" + value)
                        before = package.read_bytes()
                        with self.assertRaisesRegex(BUILDER.InvalidCatalog, "artifact-replacement-metadata"):
                            BUILDER.build({"backend": package})
                        self.assertEqual(package.read_bytes(), before)
                        self.assertFalse((self.root / "synthetic-hook-marker").exists())

    def test_ipk_ambiguous_control_fields_and_control_bytes_refuse(self):
        for data in ("package: base-files\n", "aRchitecture: foreign\n", "Bad key: synthetic-secret\n",
                     "Provides\0: synthetic-secret\n", "Description: synthetic-secret\x01\n",
                     "X-Field: first\nx-field: second\n"):
            with self.subTest(control=data):
                with self.assertRaises(BUILDER.InvalidCatalog):
                    BUILDER.build({"backend": self.package(control_extra=data)})

    def test_ipk_empty_replacement_fields_and_multiline_description_are_data(self):
        package = self.package(control_extra="Provides: \n \t\nConflicts:\nReplaces:\n"
                                            "Alternatives:\nPre-Depends:\nRecommends:\nSuggests:\n"
                                            "Depends: libc,\n ca-bundle\nDescription: sample\n Replaces: ordinary text\n")
        data = BUILDER.build({"backend": package})
        self.assertEqual(json.loads(data)["components"][0]["package"], "loki")
        self.assertFalse((self.root / "synthetic-hook-marker").exists())

    def test_ipk_alternatives_and_extra_dependency_requests_refuse(self):
        for field in ("Alternatives", "Pre-Depends", "Recommends", "Suggests"):
            body = "100:/usr/bin/synthetic-foreign:/usr/bin/loki" if field == "Alternatives" else "synthetic-secret"
            for value in (" " + body + "\n", "\n " + body + "\n"):
                with self.subTest(field=field, folded=value.startswith("\n")):
                    with self.assertRaises(BUILDER.InvalidCatalog):
                        BUILDER.build({"backend": self.package(control_extra=field + ":" + value)})

    def test_ipk_sensitive_field_prefix_lookalikes_refuse_even_when_empty(self):
        for field in ("Package", "Version", "Architecture", "Depends", "Provides", "Conflicts", "Replaces",
                      "Alternatives", "Pre-Depends", "Recommends", "Suggests"):
            for value in ("", " synthetic-secret"):
                with self.subTest(field=field, empty=not value):
                    with self.assertRaises(BUILDER.InvalidCatalog):
                        BUILDER.build({"backend": self.package(control_extra=field + "Extra:" + value + "\n")})

    def test_apk_replacement_priority_and_negative_dependencies_refuse(self):
        for fields in ({"provides": ["sing-box=1"]}, {"replaces": ["synthetic-secret"]},
                       {"provider-priority": 1}, {"provider-priority": -1},
                       {"depends": ["!dnsmasq"]}, {"depends": [" !dnsmasq"]},
                       {"depends": ["libc !synthetic-secret"]}):
            with self.subTest(fields=fields):
                with self.assertRaises(BUILDER.InvalidCatalog):
                    BUILDER.apk_entries(self.apk_fixture(**fields))

    def test_apk_control_types_and_dependency_bounds_refuse(self):
        cases = [{key: value} for key in ("provides", "replaces") for value in (False, 0, "", "synthetic-secret", {})]
        cases += [{"provider-priority": value} for value in (False, "0", [], {})]
        cases += [{"depends": value} for value in (None, "libc", {}, [None], [False], [""],
                  ["libc\0synthetic-secret"], ["libc\n"], ["库"], ["库" * 8192], ["x" * 8193], ["libc"] * 129)]
        for fields in cases:
            with self.subTest(fields=fields):
                with self.assertRaises(BUILDER.InvalidCatalog):
                    BUILDER.apk_entries(self.apk_fixture(**fields))

    def test_apk_empty_nonreplacing_controls_keep_existing_identity_and_payload(self):
        expected = BUILDER.apk_entries(self.apk_fixture())
        for fields in ({"provides": [], "replaces": [], "provider-priority": 0},
                       {"provides": None, "replaces": None, "depends": []},
                       {"depends": ["libc", "loki-core>=1.14.4-r8", "so:libc.so"]}):
            self.assertEqual(BUILDER.apk_entries(self.apk_fixture(**fields)), expected)

    def test_apk_own_generic_sdk_alias_is_exact_and_does_not_bypass_other_guards(self):
        for name in ("loki", "luci-app-loki", "luci-i18n-loki-ru"):
            data = self.apk_fixture()
            data["info"].update(name=name, provides=[name + "-any"])
            identity, entries = BUILDER.apk_entries(data)
            self.assertEqual(identity, {"package": name, "version": "1.0.0", "architecture": "noarch"})
            self.assertEqual(entries, BUILDER.apk_entries(self.apk_fixture())[1])
        for name, arch, provides in (("loki", "noarch", ["loki-any", "sing-box"]),
                                     ("loki", "noarch", ["loki-any", "loki-any"]),
                                     ("loki", "noarch", ["loki-any=1.0.0"]),
                                     ("loki", "noarch", ["luci-app-loki-any"]),
                                     ("loki", "noarch", ["loki-any-extra"]),
                                     ("loki", "x86_64", ["loki-any"]),
                                     ("loki-core", "noarch", ["loki-core-any"]),
                                     ("synthetic-secret", "noarch", ["synthetic-secret-any"])):
            data = self.apk_fixture(); data["info"].update(name=name, arch=arch, provides=provides)
            with self.subTest(name=name, arch=arch, provides=provides), self.assertRaises(BUILDER.InvalidCatalog):
                BUILDER.apk_entries(data)
        for fields in ({"provider-priority": 1}, {"replaces": ["dnsmasq"]}, {"depends": ["!dnsmasq"]}):
            with self.subTest(fields=fields), self.assertRaises(BUILDER.InvalidCatalog):
                BUILDER.apk_entries(self.apk_fixture(provides=["loki-any"], **fields))

    def test_cli_replacement_refusal_preserves_output_and_masks_input(self):
        package = self.package(control_extra="Conflicts:\n synthetic-secret\n")
        output = self.root / "candidate-manifest.json"; output.write_text("existing-catalog\n")
        done = self.bounded_child([sys.executable, "-B", str(ROOT / "build_candidate_manifest.py"),
                                   "--backend", str(package), "--output", str(output)])
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertEqual(done.stderr, "candidate-manifest: artifact-replacement-metadata\n")
        self.assertEqual(done.stdout, "")
        self.assertEqual(output.read_text(), "existing-catalog\n")
        self.assertFalse((self.root / "synthetic-hook-marker").exists())

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


class ComponentPolicy(ManifestHarness, unittest.TestCase):
    def complete(self, kind="ipk", locale=True):
        required = {
            "backend": {"/usr/bin/loki": 0o755, "/etc/config/loki": 0o600,
                        "/etc/init.d/loki": 0o755, "/etc/init.d/loki-state": 0o755,
                        "/usr/share/loki/default-config": 0o644, "/usr/share/loki/install.sh": 0o644,
                        "/lib/upgrade/keep.d/loki": 0o644, "/usr/libexec/loki-gateway": 0o755,
                        "/usr/share/nftables.d/chain-pre/input/loki.nft": 0o644},
            "luci": {"/www/luci-static/resources/view/loki/main.js": 0o644,
                     "/www/luci-static/resources/view/loki/loki.js": 0o644,
                     "/usr/share/rpcd/acl.d/luci-app-loki.json": 0o644,
                     "/usr/share/luci/menu.d/luci-app-loki.json": 0o644,
                     "/usr/share/loki/yacd/index.html": 0o644},
            "core": {"/usr/bin/loki-core": 0o755, "/etc/config/loki-core": 0o600,
                     "/etc/init.d/loki-core": 0o755, "/etc/loki-core/config.json": 0o600,
                     "/lib/upgrade/keep.d/loki-core": 0o644,
                     "/usr/share/loki-core/version": 0o644, "/usr/share/loki-core/variant": 0o644,
                     "/usr/share/licenses/loki-core/build-info.json": 0o644,
                     "/usr/share/licenses/loki-core/THIRD_PARTY_NOTICES": 0o644},
            "locale": {"/usr/lib/lua/luci/i18n/loki.ru.lmo": 0o644},
        }
        result = {"schema": 1, "components": []}
        for role, files in required.items():
            if role == "locale" and not locale:
                continue
            name = {"backend": "loki", "luci": "luci-app-loki", "core": "loki-core",
                    "locale": "luci-i18n-loki-ru"}[role]
            files["/usr/share/licenses/" + name + "/LICENSE"] = 0o644
            if kind == "apk":
                files["/lib/apk/packages/" + name + ".list"] = 0o644
            values = []
            for path, mode in files.items():
                item = entry(path); item["mode"] = mode; values.append(item)
            component = dict(role=role, package=name, version="1.14.4-r8" if role == "core" else "2.0.0",
                             architecture="x86_64" if role == "core" else "all" if kind == "ipk" else "noarch",
                             format=kind, artifact=dict(name=name + "." + kind, size=1, sha256="b" * 64), files=values)
            result["components"].append(component)
        return result

    def prepare(self, value):
        value = copy.deepcopy(value)
        for component in value["components"]:
            files = component["files"]
            parents = {str(parent) for item in files for parent in Path(item["path"]).parents}
            present = {item["path"] for item in files}
            files.extend(entry(path, True) for path in sorted(parents - present))
        return value

    def policy(self, value):
        value = self.prepare(value)
        result = self.invoke(canonical(value))
        self.assertNotIn("error", result)
        self.assertIn("component_policy", result)
        return result["component_policy"], value

    def test_complete_owned_sets_and_optional_locale_are_metadata_only(self):
        for kind in ("ipk", "apk"):
            for locale in (False, True):
                policy, _ = self.policy(self.complete(kind, locale))
                self.assertEqual(policy, {"kind": "candidate-manifest", "object": "component-set",
                                          "state": "checked", "reason": "candidate-component-metadata-checked"})

    def test_missing_required_roles_cannot_be_a_complete_set(self):
        for role in ("backend", "luci", "core"):
            value = self.complete()
            value["components"] = [item for item in value["components"] if item["role"] != role]
            policy, _ = self.policy(value)
            self.assertEqual(policy["reason"], "candidate-component-required-missing")
            self.assertEqual(policy["state"], "incomplete")

    def test_version_mismatches_and_unreviewed_or_old_core_refuse(self):
        for role, version in (("luci", "2.0.1"), ("locale", "2.0.1"), ("core", "1.14.4-r7"),
                              ("core", "1.14.4"), ("core", "synthetic-secret"), ("core", "1.14.4-r8+evil")):
            value = self.complete()
            next(item for item in value["components"] if item["role"] == role)["version"] = version
            policy, _ = self.policy(value)
            self.assertEqual(policy["state"], "incomplete")
            self.assertNotIn("synthetic-secret", json.dumps(policy))
        value = self.complete()
        next(item for item in value["components"] if item["role"] == "core")["version"] = "1.14.4-r9"
        policy, _ = self.policy(value)
        self.assertEqual(policy["state"], "checked")

    def test_foreign_lookalike_and_cross_role_payloads_refuse(self):
        for role, path in (("backend", "/etc/config/dhcp"), ("backend", "/usr/lib/loki-foreign/synthetic-secret"),
                           ("backend", "/usr/share/loki/yacd/synthetic-secret"), ("luci", "/usr/bin/opkg"),
                           ("core", "/usr/bin/sing-box"), ("locale", "/usr/lib/lua/luci/i18n/base.ru.lmo")):
            value = self.complete()
            next(item for item in value["components"] if item["role"] == role)["files"].append(entry(path))
            policy, _ = self.policy(value)
            self.assertEqual(policy["reason"], "candidate-component-path-unverified")
            self.assertNotIn("synthetic-secret", json.dumps(policy))

    def test_required_files_modes_and_unrelated_directories_refuse(self):
        for role, path in (("backend", "/usr/bin/loki"), ("luci", "/usr/share/loki/yacd/index.html"),
                           ("backend", "/etc/config/loki"),
                           ("backend", "/usr/share/licenses/loki/LICENSE"), ("core", "/etc/config/loki-core"),
                           ("core", "/usr/share/licenses/loki-core/THIRD_PARTY_NOTICES"),
                           ("locale", "/usr/lib/lua/luci/i18n/loki.ru.lmo")):
            for missing in (False, True):
                value = self.complete()
                component = next(item for item in value["components"] if item["role"] == role)
                if missing:
                    component["files"] = [item for item in component["files"] if item["path"] != path]
                else:
                    next(item for item in component["files"] if item["path"] == path)["mode"] = (
                        0o644 if path in ("/etc/config/loki", "/etc/config/loki-core") else 0o640)
                policy, _ = self.policy(value)
                self.assertEqual(policy["state"], "incomplete")
        value = self.complete()
        value["components"][0]["files"].append(entry("/etc/synthetic-secret", True))
        policy, _ = self.policy(value)
        self.assertEqual(policy["reason"], "candidate-component-directory-unverified")
        value = self.prepare(self.complete())
        for component in value["components"]:
            for item in component["files"]:
                if item["path"] == "/":
                    item["mode"] = 0o700
        policy, _ = self.policy(value)
        self.assertEqual(policy["reason"], "candidate-component-directory-unverified")

    def test_apk_file_lists_are_required_and_cannot_claim_another_package(self):
        for suffix in (".conffiles", ".conffiles_static"):
            for name, mode, allowed in (("loki", 0o644, True), ("loki", 0o600, False),
                                        ("loki-foreign", 0o644, False), ("base-files", 0o644, False)):
                value = self.complete("apk")
                item = entry("/lib/apk/packages/" + name + suffix); item["mode"] = mode
                value["components"][0]["files"].append(item)
                policy, _ = self.policy(value)
                self.assertEqual(policy["state"] == "checked", allowed)
            value = self.complete("ipk")
            value["components"][0]["files"].append(entry("/lib/apk/packages/loki" + suffix))
            policy, _ = self.policy(value)
            self.assertEqual(policy["reason"], "candidate-component-path-unverified")
        value = self.complete("apk")
        component = value["components"][0]
        component["files"] = [item for item in component["files"] if item["path"] != "/lib/apk/packages/loki.list"]
        policy, _ = self.policy(value)
        self.assertEqual(policy["state"], "incomplete")
        component["files"].append(entry("/lib/apk/packages/base-files.list"))
        policy, _ = self.policy(value)
        self.assertEqual(policy["reason"], "candidate-component-path-unverified")

    def test_collector_retains_other_required_gates_and_masks_policy_inputs(self):
        policy, value = self.policy(self.complete())
        result = self.invoke(canonical(value), collect=True)
        self.assertIn(policy, result["observations"])
        self.assertFalse(result["complete"])
        self.assertFalse(result["install_allowed"])
        self.assertIn("artifact-provenance-unverified", {item["reason"] for item in result["observations"]})
        self.assertIn("artifact-content-unverified", {item["reason"] for item in result["observations"]})

    def test_tokens_and_hashes_keep_exact_byte_boundaries(self):
        for field in ("version", "architecture"):
            for size in (128, 129):
                value = candidate(); value["components"][0][field] = "a" * size
                self.assertEqual("error" not in self.invoke(canonical(value)), size == 128)
        for size in (128, 129):
            value = candidate(); value["components"][0]["artifact"]["name"] = "a" * (size - 4) + ".ipk"
            self.assertEqual("error" not in self.invoke(canonical(value)), size == 128)
        for ending in ("", "a", "\n", "\0synthetic-secret"):
            value = candidate(); value["components"][0]["artifact"]["sha256"] = "a" * 64 + ending
            self.assertEqual("error" not in self.invoke(canonical(value)), ending == "")
        for ending in ("\n", "\t", "\0synthetic-secret"):
            value = candidate(); value["components"][0]["version"] += ending
            self.assertIn("error", self.invoke(canonical(value)))

    def test_complete_catalog_fits_the_preflight_resource_budget(self):
        value = self.complete()
        value["components"][0]["files"].extend(entry("/usr/lib/loki/module-" + str(i) + ".uc") for i in range(200))
        data = canonical(self.prepare(value))
        self.write(self.manifest, data)

        def limits():
            resource.setrlimit(resource.RLIMIT_AS, (64 * 1024 * 1024, 64 * 1024 * 1024))
            resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

        expression = '''let fs=require("fs");let p=require("service.preflight_manifest");
            let r=p.parse(fs.readfile(ARGV[0]));assert(r.error==null&&r.component_policy.state=="checked");print("budget-ok");'''
        process = subprocess.Popen([self.binary, "-L", str(ROOT / "loki/files/usr/lib"), "-e", expression, str(self.manifest)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   preexec_fn=limits, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL); process.communicate(timeout=5)
            self.fail("valid component catalog exceeded the five-second deadline")
        self.assertEqual(process.returncode, 0, "catalog resource/check failure: " + stderr)
        self.assertEqual((stdout, stderr), ("budget-ok", ""))
        self.assertEqual(self.manifest.read_text(), data)


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Run these executable checks only on the Linux test server")
    unittest.main()
