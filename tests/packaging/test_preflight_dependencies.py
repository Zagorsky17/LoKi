"""The read-only requirement inventory must follow the package declarations."""
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RequirementContract(unittest.TestCase):
    def native_dependency(self, latest, constants):
        recipe = (ROOT / "loki/Makefile").read_text()
        prefix = re.search(r"\A.*?^define Package/loki\n.*?^endef\n", recipe, re.M | re.S)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sdk = root / "sdk"
            (sdk / "include").mkdir(parents=True)
            (sdk / "rules.mk").write_text("INCLUDE_DIR:=" + str(sdk / "include") + "\n")
            (sdk / "include/package.mk").touch()
            package = root / "project/loki"
            source = package / "files/usr/lib/core/constants.uc"
            source.parent.mkdir(parents=True)
            if constants is not None:
                source.write_text(constants)
            (root / "project/core").mkdir()
            (root / "project/core/upstream.env").write_text("CORE_VERSION=" + latest + "\n")
            (package / "Makefile").write_text(prefix + '\n$(eval $(Package/loki))\n'
                'dependency:\n\t@printf "%s\\n" "$(EXTRA_DEPENDS)"\n')
            return subprocess.run(["make", "-s", "--no-print-directory", "TOPDIR=" + str(sdk), "dependency"],
                                  cwd=package, capture_output=True, text=True, timeout=10)

    def test_native_minimum_is_independent_of_a_newer_core_build(self):
        constants = (ROOT / "loki/files/usr/lib/core/constants.uc").read_text()
        for latest in ["1.14.4-r10", "1.14.4-r11"]:
            with self.subTest(latest=latest):
                result = self.native_dependency(latest, constants)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "loki-core (>=1.14.4-r9)\n")

    def test_native_minimum_tracks_a_changed_backend_requirement(self):
        constants = (ROOT / "loki/files/usr/lib/core/constants.uc").read_text().replace(
            'SB_REQUIRED_VERSION: "1.14.4-r9"', 'SB_REQUIRED_VERSION: "1.14.4-r10"')
        result = self.native_dependency("1.14.4-r11", constants)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "loki-core (>=1.14.4-r10)\n")

    def test_native_minimum_refuses_missing_corrupt_or_ambiguous_constants(self):
        constants = (ROOT / "loki/files/usr/lib/core/constants.uc").read_text()
        for value in [None, constants.replace('SB_REQUIRED_VERSION: "1.14.4-r9"', 'SB_REQUIRED_VERSION: ""'),
                      constants.replace('SB_REQUIRED_VERSION: "1.14.4-r9"', 'SB_REQUIRED_VERSION: "synthetic-secret"'),
                      constants + '\n    SB_REQUIRED_VERSION: "1.14.4-r9"\n']:
            with self.subTest(missing=value is None):
                result = self.native_dependency("1.14.4-r10", value)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("synthetic-secret", result.stderr)

    def test_declared_shared_dependencies_match_preflight_without_owned_components(self):
        expected = {"libc"}
        owned = {"loki", "luci-app-loki", "loki-core", "luci-i18n-loki-ru"}
        for name in ["loki/Makefile", "luci-app-loki/Makefile"]:
            text = (ROOT / name).read_text()
            declarations = re.findall(r"^\s*(?:LUCI_)?DEPENDS:=(.+)$", text, re.M)
            self.assertTrue(declarations, name)
            for declaration in declarations:
                for token in declaration.split():
                    self.assertRegex(token, r"^\+?[a-z0-9][a-z0-9+_.-]*$", name)
                    expected.add(token.removeprefix("+"))
        module = (ROOT / "loki/files/usr/lib/service/preflight_dependencies.uc").read_text()
        required = json.loads(re.search(r"const REQUIRED = (\[.*?\]);", module, re.S)[1])
        self.assertEqual(len(required), len(set(required)))
        self.assertEqual(set(required), expected - owned)


if __name__ == "__main__":
    if sys.platform != "linux":
        raise SystemExit("Run these executable checks only on Linux")
    unittest.main()
