"""Exercise Foundation's actual bundle lookup through Homebrew-style entry links."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS Foundation and Xcode")
class PreviewLaunchTests(unittest.TestCase):
    def test_installed_preview_resources_and_build_configuration_through_symlinks(self):
        source = Path(__file__).resolve().parents[2] / "Sources/IPhoneUseCore/Media/Preview/NativePreviewPage.swift"
        with tempfile.TemporaryDirectory(prefix="iphone-use preview launch ") as temporary:
            root = Path(temporary)
            main = root / "main.swift"
            main.write_text('''import Foundation
let result: [String: Any] = [
    "directory": NativePreviewPage.assetDirectory()?.path as Any? ?? NSNull(),
    "comparison": NativePreviewPage.appearanceComparisonEnabled,
    "htmlConfigured": NativePreviewPage.html.contains("const appearanceComparisonEnabled=\\(NativePreviewPage.appearanceComparisonEnabled ? "true" : "false");")
]
print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
''')
            for configuration, flags, comparison in [("release", ["-O"], False), ("debug", ["-DDEBUG"], True)]:
                with self.subTest(configuration=configuration):
                    prefix = root / configuration
                    keg = prefix / "Cellar/iphone-use/0.3.1"
                    binary = keg / "libexec/bin/iphone-use"
                    assets = keg / "libexec/libexec/iphone-use/preview"
                    for path in [binary.parent, assets, keg / "bin", prefix / "bin"]:
                        path.mkdir(parents=True, exist_ok=True)
                    (assets / "catalog.json").write_text("{}")
                    subprocess.run(["xcrun", "swiftc", *flags, str(source), *map(str, sorted(source.parent.glob("NativePreviewPage+*.swift"))), str(main), "-o", str(binary)],
                                   check=True, capture_output=True, text=True, timeout=120)
                    (keg / "bin/iphone-use").symlink_to("../libexec/bin/iphone-use")
                    (prefix / "bin/iphone-use").symlink_to("../Cellar/iphone-use/0.3.1/bin/iphone-use")
                    for entry in [binary, keg / "bin/iphone-use", prefix / "bin/iphone-use"]:
                        with self.subTest(entry=entry.relative_to(prefix)):
                            result = json.loads(subprocess.check_output([str(entry)], cwd=root, text=True, timeout=10))
                            self.assertEqual(Path(result["directory"]).resolve(), assets.resolve())
                            self.assertEqual(result["comparison"], comparison)
                            self.assertTrue(result["htmlConfigured"])
                    (assets / "catalog.json").unlink()
                    result = json.loads(subprocess.check_output([str(prefix / "bin/iphone-use")], cwd=root, text=True, timeout=10))
                    self.assertIsNone(result["directory"])


if __name__ == "__main__":
    unittest.main()
