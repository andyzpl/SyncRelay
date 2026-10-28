"""One version number, written by hand, checked here.

The package identity a device can inspect must match the source that produced
it: `Core/SRVersion.h`, `control` and the published build step must not drift.
CI generates only `Core/SRBuildRevision.h` (commit/run); it must never rewrite
the product version behind the reviewer's back.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def header_version():
    match = re.search(r'#define SR_PLUGIN_VERSION @"([^"]+)"', read("Core/SRVersion.h"))
    return match.group(1) if match else None


def control_version():
    match = re.search(r"(?m)^Version:\s*(\S+)\s*$", read("control"))
    return match.group(1) if match else None


class VersionConsistency(unittest.TestCase):
    def test_header_and_control_agree(self):
        header, control = header_version(), control_version()
        self.assertIsNotNone(header, "SRVersion.h must define SR_PLUGIN_VERSION")
        self.assertIsNotNone(control, "control must carry a Version field")
        self.assertEqual(header, control,
                         "SR_PLUGIN_VERSION and control Version must be the same release")

    def test_version_is_semver(self):
        for name, value in (("SRVersion.h", header_version()), ("control", control_version())):
            self.assertRegex(value or "", SEMVER, name)

    def test_control_declares_the_expected_package(self):
        control = read("control")
        self.assertIn("Package: andyz.syncrelay", control)
        self.assertIn("Architecture: iphoneos-arm", control)

    def test_ci_never_rewrites_the_product_version(self):
        workflow = read(".github/workflows/build.yml")
        self.assertIn("Core/SRBuildRevision.h", workflow)
        # The generated revision header is the only source file CI writes.
        for forbidden in ("> Core/SRVersion.h", "> control", "SRVersion.h\n", "sed -i"):
            self.assertNotIn(forbidden, workflow)
        writes = re.findall(r">\s*(Core/[A-Za-z]+\.h)", workflow)
        self.assertEqual(sorted(set(writes)), ["Core/SRBuildRevision.h"],
                         "CI may only generate the revision header")

    def test_manifest_filters_the_wechat_bundle(self):
        plist = read("SyncRelay.plist")
        self.assertIn("<key>Filter</key>", plist)
        self.assertIn("<key>Bundles</key>", plist)
        self.assertIn("com.tencent.xin", plist)


if __name__ == "__main__":
    unittest.main()
