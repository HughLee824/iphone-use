import importlib.util
import io
import json
import plistlib
import re
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_artifact import PREVIEW, PREVIEW_FILES, preview_asset_files, RUNNER, VERSION_PATTERN, check_checksum, check_linked_libraries, inspect_archive, sha256

spec = importlib.util.spec_from_file_location("homebrew", Path(__file__).resolve().parents[1] / "generate-homebrew.py")
homebrew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(homebrew)


class ReleaseTests(unittest.TestCase):
    def test_linked_libraries_must_be_system_dependencies(self):
        libraries = ["/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation", "/usr/lib/swift/libswiftCore.dylib"]
        output = "package with spaces/bin/iphone-use:\n" + "".join(
            f"\t{library} (compatibility version 1.0.0, current version 1.0.0)\n" for library in libraries)
        self.assertEqual(check_linked_libraries(output), libraries)
        for library in ["/Users/developer/.build/libBridge.dylib", "/opt/homebrew/lib/tool.dylib",
                        "@rpath/libBridge.dylib", "/usr/lib/../../tmp/untrusted.dylib"]:
            with self.assertRaisesRegex(ValueError, "external dependency"):
                check_linked_libraries(output + f"\t{library} (compatibility version 1.0.0, current version 1.0.0)\n")
        with self.assertRaises(ValueError):
            check_linked_libraries("CLI:\n")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="iphone-use test ")
        self.addCleanup(self.temporary.cleanup)
        self.version = "0.1.0-rc.1"
        self.archive = Path(self.temporary.name) / f"iphone-use-{self.version}-macos-arm64.tar.gz"
        self.root = self.archive.name.removesuffix(".tar.gz")
        self.runner = {
            "IPhoneUseRunner.app/Info.plist": plistlib.dumps({"MinimumOSVersion": "17.0"}),
            "IPhoneUseRunner.app/IPhoneUseTests-Runner": b"runner binary",
            "IPhoneUseRunner.app/PlugIns/IPhoneUseTests.xctest/IPhoneUseTests": b"test binary",
            "Runner.xctestrun": plistlib.dumps({"IPhoneUseTests": {
                "TestHostPath": "__TESTROOT__/IPhoneUseRunner.app",
                "TestBundlePath": "__TESTHOST__/PlugIns/IPhoneUseTests.xctest",
                "UseUITargetAppProvidedByTests": True,
                "DependentProductPaths": ["__TESTROOT__/IPhoneUseRunner.app",
                    "__TESTROOT__/IPhoneUseRunner.app/PlugIns/IPhoneUseTests.xctest"],
            }}),
        }
        self.build = {"version": self.version, "architecture": "arm64", "license": "MIT",
                      "sourceCommit": "a" * 40, "sourceDirty": False}

    def write_archive(self, *, modify_files=None, modify_manifest=None, extra_members=()):
        inventory = {name: sha256(data) for name, data in self.runner.items()}
        manifest = {"formatVersion": 1, "releaseVersion": self.version,
                    "cliSHA256": sha256(b"CLI"), "minimumOSVersion": "17.0", "files": inventory,
                    "runnerVersion": sha256(json.dumps(inventory, sort_keys=True, separators=(",", ":")).encode())}
        if modify_manifest:
            modify_manifest(manifest)
        files = {"bin/iphone-use": b"CLI", "bin/agentsoma": b"CLI", "README.md": b"install", "LICENSE": b"MIT",
                 "licenses/SwiftArgumentParser.txt": b"dependency licence",
                 "build-info.json": json.dumps(self.build).encode(),
                 RUNNER + "manifest.json": json.dumps(manifest).encode(),
                 **{RUNNER + name: data for name, data in self.runner.items()}}
        if modify_files:
            modify_files(files)
        with tarfile.open(self.archive, "w:gz") as tar:
            for name, data in files.items():
                member = tarfile.TarInfo(f"{self.root}/{name}")
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
            for member in extra_members:
                tar.addfile(member, io.BytesIO(b""))
        Path(str(self.archive) + ".sha256").write_text(f"{sha256(self.archive.read_bytes())}  {self.archive.name}\n")

    def test_legacy_command_must_match_new_binary(self):
        self.write_archive(modify_files=lambda files: files.update({"bin/agentsoma": b"different CLI"}))
        with self.assertRaisesRegex(ValueError, "Legacy command"):
            inspect_archive(self.archive)

    def test_valid_release_and_checksum(self):
        self.write_archive()
        check_checksum(self.archive)
        release = inspect_archive(self.archive, require_clean=True)
        self.assertEqual(release["version"], self.version)
        self.assertEqual(release["build"]["sourceCommit"], "a" * 40)

    def test_preview_artwork_requires_complete_manifest_and_apple_license(self):
        profile = {"name":"iPhone 12 Pro", "file":"phone.png", "sha256":sha256(b"png"),
                   "canvasWidth":100, "canvasHeight":200, "screenX":5, "screenY":5,
                   "screenWidth":90, "screenHeight":190, "cornerRadius":5}
        catalog = json.dumps({"version":1,"models":{"iPhone13,3":profile}}).encode()
        artwork = {**{name:name.encode() for name in PREVIEW_FILES}, "catalog.json":catalog, "phone.png":b"png"}
        self.build["previewAssets"] = {name: sha256(data) for name, data in artwork.items()}
        self.write_archive(modify_files=lambda files: files.update({PREVIEW + name: data for name, data in artwork.items()}))
        inspect_archive(self.archive)
        for missing in artwork:
            self.write_archive(modify_files=lambda files: files.update({PREVIEW + name: data for name, data in artwork.items() if name != missing}))
            with self.assertRaisesRegex(ValueError, "Preview artwork"):
                inspect_archive(self.archive)
        self.write_archive(modify_files=lambda files: files.update({PREVIEW + name: (b"changed" if name=="phone.png" else data) for name,data in artwork.items()}))
        with self.assertRaisesRegex(ValueError, "Preview artwork"):
            inspect_archive(self.archive)

    def test_preview_catalog_rejects_path_escape_and_wrong_geometry(self):
        catalog_path = Path(__file__).resolve().parents[2] / "assets/preview/catalog.json"
        catalog = json.loads(catalog_path.read_text())
        expected = preview_asset_files(catalog_path.read_bytes())
        self.assertEqual(len(expected), len({p["file"] for p in catalog["models"].values()}) + len(PREVIEW_FILES))
        for patch in [{"file":"../outside.png"}, {"screenX":16384}, {"screenWidth":0}, {"sha256":"bad"}]:
            changed=json.loads(catalog_path.read_text())
            next(iter(changed["models"].values())).update(patch)
            with self.assertRaises(ValueError):
                preview_asset_files(json.dumps(changed).encode())

    def test_version_syntax(self):
        for version in ["0.1.0", "1.2.3-rc.1", "1.2.3-dev.0"]:
            self.assertIsNotNone(re.fullmatch(VERSION_PATTERN, version))
        for version in ["v0.1.0", "01.0.0", "1.2.3-01", "1.2.3-a..b", "1.2.3-", "1.2.3/x"]:
            self.assertIsNone(re.fullmatch(VERSION_PATTERN, version))

    def test_checksum_must_name_the_same_file_and_bytes(self):
        self.write_archive()
        checksum = Path(str(self.archive) + ".sha256")
        for text in [f'{sha256(self.archive.read_bytes())}  wrong.tar.gz', f'{"0" * 64}  {self.archive.name}']:
            checksum.write_text(text)
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                check_checksum(self.archive)

    def test_dirty_source_allowed_locally_but_not_publicly(self):
        self.build["sourceDirty"] = True
        self.write_archive()
        inspect_archive(self.archive)
        with self.assertRaisesRegex(ValueError, "clean checkout"):
            inspect_archive(self.archive, require_clean=True)

    def test_source_metadata_is_required(self):
        for key, value in [("sourceCommit", "main"), ("sourceDirty", "false"),
                           ("architecture", "x86_64"), ("license", "unknown"), ("version", "9.9.9")]:
            with self.subTest(key=key):
                saved = self.build[key]
                self.build[key] = value
                self.write_archive()
                with self.assertRaises(ValueError):
                    inspect_archive(self.archive)
                self.build[key] = saved

    def test_cli_and_runner_tampering_rejected(self):
        for name in ["bin/iphone-use", RUNNER + "IPhoneUseRunner.app/IPhoneUseTests-Runner"]:
            with self.subTest(name=name):
                self.write_archive(modify_files=lambda files: files.update({name: b"changed"}))
                with self.assertRaises(ValueError):
                    inspect_archive(self.archive)

    def test_missing_license_rejected(self):
        for name in ["LICENSE", "licenses/SwiftArgumentParser.txt"]:
            self.write_archive(modify_files=lambda files: files.pop(name))
            with self.assertRaisesRegex(ValueError, "missing"):
                inspect_archive(self.archive)

    def test_incomplete_but_consistently_hashed_runner_rejected(self):
        self.runner.pop("IPhoneUseRunner.app/IPhoneUseTests-Runner")
        self.write_archive()
        with self.assertRaisesRegex(ValueError, "incomplete"):
            inspect_archive(self.archive)

    def test_manifest_versions_and_content_id_must_match(self):
        for key, value in [("formatVersion", 2), ("releaseVersion", "9.9.9"),
                           ("runnerVersion", "0" * 64), ("minimumOSVersion", "next")]:
            self.write_archive(modify_manifest=lambda manifest: manifest.update({key: value}))
            with self.assertRaises(ValueError):
                inspect_archive(self.archive)

    def test_signing_profiles_frameworks_and_source_rejected_even_with_matching_hashes(self):
        for name in ["IPhoneUseRunner.app/embedded.mobileprovision", "IPhoneUseRunner.app/Frameworks/XCTest.framework/XCTest",
                     "source.swift", "Runner.dSYM/Contents/Resources/DWARF/Runner"]:
            self.runner[name] = b"must not ship"
            self.write_archive()
            with self.assertRaisesRegex(ValueError, "signing profiles"):
                inspect_archive(self.archive)
            self.runner.pop(name)

    def test_external_test_manifest_path_rejected(self):
        plan = plistlib.loads(self.runner["Runner.xctestrun"])
        plan["IPhoneUseTests"]["TestHostPath"] = "/private/local/Runner.app"
        self.runner["Runner.xctestrun"] = plistlib.dumps(plan)
        self.write_archive()
        with self.assertRaisesRegex(ValueError, "packaged app"):
            inspect_archive(self.archive)

    def test_unsafe_tar_members_rejected_before_extraction(self):
        for name in ["/tmp/escape", f"{self.root}/../escape", f"{self.root}/./extra",
                     f"{self.root}//extra", "", "another-root/file", f"{self.root}/bin/iphone-use"]:
            with self.subTest(name=name):
                self.write_archive(extra_members=[tarfile.TarInfo(name)])
                with self.assertRaises(ValueError):
                    inspect_archive(self.archive)
        for kind in [tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE, tarfile.CHRTYPE]:
            member = tarfile.TarInfo(f"{self.root}/link")
            member.type, member.linkname = kind, "/tmp/escape"
            self.write_archive(extra_members=[member])
            with self.assertRaisesRegex(ValueError, "link, special file"):
                inspect_archive(self.archive)

    def test_unexpected_payload_outside_runner_rejected(self):
        self.write_archive(modify_files=lambda files: files.update({"private.mobileprovision": b"private"}))
        with self.assertRaisesRegex(ValueError, "unexpected file"):
            inspect_archive(self.archive)

    def test_formula_uses_immutable_version_url_and_preserves_resource_layout(self):
        self.write_archive()
        output = Path(self.temporary.name) / "Formula/iphone-use.rb"
        subprocess.run([sys.executable, str(Path(homebrew.__file__)), str(self.archive), "--output", str(output)],
                       check=True, capture_output=True)
        formula = output.read_text()
        self.assertIn(f"/releases/download/v{self.version}/{self.archive.name}", formula)
        self.assertIn(sha256(self.archive.read_bytes()), formula)
        self.assertIn('libexec.install "bin", "libexec"', formula)
        self.assertIn('bin.install_symlink libexec/"bin/iphone-use"', formula)
        self.assertNotIn("latest/download", formula)

    def test_public_formula_rejects_dirty_candidate_but_local_test_can_install_it(self):
        self.build["sourceDirty"] = True
        self.write_archive()
        output = Path(self.temporary.name) / "iphone-use.rb"
        command = [sys.executable, str(Path(homebrew.__file__)), str(self.archive), "--output", str(output)]
        self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
        self.assertFalse(output.exists())
        subprocess.run([*command, "--local"], check=True, capture_output=True)
        self.assertIn("file://", output.read_text())

    def test_formula_rejects_untested_architecture_and_ruby_interpolation(self):
        self.write_archive()
        release = inspect_archive(self.archive)
        for url in ["file:///tmp/#{danger}.tar.gz", "file:///tmp/#@danger.tar.gz", "file:///tmp/#$danger.tar.gz"]:
            with self.assertRaises(ValueError):
                homebrew.formula_for(release, url)
        release["architecture"] = "x86_64"
        with self.assertRaisesRegex(ValueError, "Apple Silicon"):
            homebrew.formula_for(release, "https://example.com/release.tar.gz")


if __name__ == "__main__":
    unittest.main()
