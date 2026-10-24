"""Exercise the real Mach-O relocation fix without an iPhone or signing identity."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
SPEC = importlib.util.spec_from_file_location("build_release", Path(__file__).resolve().parents[1] / "build-release.py")
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


@unittest.skipUnless(sys.platform == "darwin", "Requires macOS Mach-O tools")
class RunnerPackageLinkageTests(unittest.TestCase):
    def test_only_build_owned_package_runpath_is_removed(self):
        with tempfile.TemporaryDirectory(prefix="iphone-use linkage ") as directory:
            root = Path(directory)
            source = root / "main.c"
            source.write_text("int main(void) { return 0; }\n")
            binary = root / "test"
            build_path = str(root / "PackageFrameworks")
            unrelated_path = str(root / "OtherFrameworks")
            subprocess.run(["xcrun", "clang", str(source), "-o", str(binary),
                            "-Xlinker", "-rpath", "-Xlinker", build_path,
                            "-Xlinker", "-rpath", "-Xlinker", unrelated_path,
                            "-Xlinker", "-rpath", "-Xlinker", "@loader_path/Frameworks"],
                           check=True, capture_output=True, timeout=60)
            subprocess.run(["/usr/bin/codesign", "--remove-signature", str(binary)], check=True)
            before = subprocess.check_output(["/usr/bin/otool", "-l", str(binary)], text=True)
            self.assertIn(f"path {build_path} (offset", before)
            BUILD.remove_package_build_runpath(binary, root)
            after = subprocess.check_output(["/usr/bin/otool", "-l", str(binary)], text=True)
            self.assertNotIn(f"path {build_path} (offset", after)
            self.assertIn(f"path {unrelated_path} (offset", after)
            self.assertIn("path @loader_path/Frameworks (offset", after)
            first = binary.read_bytes()
            self.assertNotIn(build_path.encode(), first)
            BUILD.remove_package_build_runpath(binary, root)
            self.assertEqual(binary.read_bytes(), first, "No matching path must leave the binary unchanged")
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(binary)],
                           check=True, capture_output=True)
            subprocess.run([str(binary)], check=True, timeout=10)
