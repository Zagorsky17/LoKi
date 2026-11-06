"""The read-only requirement inventory must follow the package declarations."""
import json
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RequirementContract(unittest.TestCase):
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
