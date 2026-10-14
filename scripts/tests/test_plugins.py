import hashlib
import importlib.util
import json
import os
import re
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "plugins/iphone-use"
spec = importlib.util.spec_from_file_location("sync_plugin", ROOT / "scripts/sync-plugin.py")
sync_plugin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync_plugin)


class PluginPackageTests(unittest.TestCase):
    def test_marketplaces_resolve_the_same_self_contained_plugin(self):
        codex = json.loads((ROOT / ".agents/plugins/marketplace.json").read_text())
        claude = json.loads((ROOT / ".claude-plugin/marketplace.json").read_text())
        self.assertEqual(codex["name"], "iphone-use")
        self.assertEqual(codex["name"], claude["name"])
        self.assertEqual(codex["plugins"][0]["source"]["path"], "./plugins/iphone-use")
        self.assertEqual(claude["plugins"][0]["source"], "./plugins/iphone-use")
        policy = codex["plugins"][0]["policy"]
        self.assertEqual(policy, {"installation": "AVAILABLE", "authentication": "ON_INSTALL"})
        manifests = [json.loads((PLUGIN / directory / "plugin.json").read_text())
                     for directory in (".codex-plugin", ".claude-plugin")]
        self.assertEqual(manifests[0]["version"], manifests[1]["version"])
        for manifest in manifests:
            self.assertEqual(manifest["name"], PLUGIN.name)
            self.assertEqual(manifest["skills"], "./skills/")
            self.assertNotIn("mcpServers", manifest)
            self.assertNotIn("hooks", manifest)
        self.assertIn(f'Workflow version: **{manifests[0]["version"]}**',
                      (PLUGIN / "skills/iphone-use/SKILL.md").read_text())
        sync_plugin.sync(check=True)

    def test_archive_is_reproducible_and_usable_after_relocation(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            sync_plugin.archive(output)
            archive = next(output.glob("*.zip"))
            first = archive.read_bytes()
            sync_plugin.archive(output)
            self.assertEqual(first, archive.read_bytes())
            self.assertEqual(archive.with_suffix(".zip.sha256").read_text().split()[0],
                             hashlib.sha256(first).hexdigest())
            with zipfile.ZipFile(archive) as bundle:
                self.assertIsNone(bundle.testzip())
                for entry in bundle.infolist():
                    self.assertNotIn("..", Path(entry.filename).parts)
                    self.assertTrue(entry.filename.startswith("iphone-use/"))
                    self.assertNotEqual((entry.external_attr >> 16) & 0o170000, 0o120000)
                bundle.extractall(output / "relocated")
            relocated = (output / "relocated/iphone-use").resolve()
            self.assertTrue((relocated / "LICENSE").is_file())
            self.assertTrue((relocated / "skills/iphone-use/scripts/preflight.sh").is_file())
            interface = json.loads((relocated / ".codex-plugin/plugin.json").read_text())["interface"]
            for field in ("logo", "logoDark", "composerIcon", "composerIconDark"):
                icon = (relocated / interface[field]).resolve()
                self.assertTrue(icon.is_relative_to(relocated))
                self.assertEqual(icon.read_bytes(), (ROOT / "assets/brand" / icon.name).read_bytes())
            skill = relocated / "skills/iphone-use"
            metadata = (skill / "agents/openai.yaml").read_text()
            icons = re.findall(r'^\s+icon_(?:small|large): "([^"]+)"$', metadata, re.MULTILINE)
            self.assertEqual(len(icons), 2)
            for reference in icons:
                icon = (skill / reference).resolve()
                self.assertTrue(icon.is_relative_to(skill))
                self.assertEqual(icon.read_bytes(), (ROOT / "assets/brand" / icon.name).read_bytes())
            for document in relocated.rglob("*.md"):
                for link in re.findall(r"\[[^\]]+\]\(([^)]+)\)", document.read_text()):
                    if link.startswith(("https://", "#")):
                        continue
                    path = (document.parent / link.split("#")[0]).resolve()
                    self.assertTrue(path.is_relative_to(relocated), f"External checkout reference: {link}")
                    self.assertTrue(path.is_file(), f"Missing packaged reference: {link}")

    def test_check_rejects_missing_and_changed_bundle_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            original = sync_plugin.PLUGIN
            try:
                sync_plugin.PLUGIN = Path(temporary) / "iphone-use"
                with self.assertRaisesRegex(ValueError, "stale"):
                    sync_plugin.sync(check=True)
                sync_plugin.sync()
                sync_plugin.sync(check=True)
                target = sync_plugin.PLUGIN / "skills/iphone-use/references/claude-code.md"
                target.write_text("Old cached instructions")
                with self.assertRaisesRegex(ValueError, "stale"):
                    sync_plugin.sync(check=True)
            finally:
                sync_plugin.PLUGIN = original


class PluginPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.xcode = self.root / "Xcode.app/Contents/Developer"
        (self.xcode / "Platforms/iPhoneOS.platform").mkdir(parents=True)
        self.write_command("uname", "printf 'Darwin\\n'")
        self.write_command("xcode-select", f"printf '%s\\n' '{self.xcode}'")
        self.write_cli("0.1.0")

    def write_command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def write_cli(self, version, observe=True):
        help_text = "--observe --agent-output" if observe else "tap REF"
        self.write_command("iphone-use", f"case \"$1\" in --version) printf '%s\\n' '{version}';; tap) printf '%s\\n' '{help_text}';; connect) printf '%s\\n' '--mode';; *) exit 99;; esac")

    def run_check(self, *args):
        return subprocess.run(["/bin/sh", str(ROOT / "skills/iphone-use/scripts/preflight.sh"), *args],
                              env={**os.environ, "PATH": f"{self.bin}:/usr/bin:/bin"},
                              text=True, capture_output=True)

    def test_valid_package_and_optional_observe_capability(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Action --observe: available", result.stdout)
        self.assertIn("Live preview: unavailable", result.stdout)
        self.write_cli("1.0.0", observe=False)
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Use separate action", result.stdout)

    def test_explicit_candidate_path_with_spaces_and_capabilities(self):
        self.write_cli("0.1.0-dev.firstuse.6")
        candidate = self.root / "candidate with spaces"
        (self.bin / "iphone-use").rename(candidate)
        env = {**os.environ, "PATH": f"{self.bin}:/usr/bin:/bin", "IPHONE_USE_CLI": str(candidate)}
        command = ["/bin/sh", str(ROOT / "skills/iphone-use/scripts/preflight.sh")]
        rejected = subprocess.run(command, env=env, text=True, capture_output=True)
        self.assertNotEqual(rejected.returncode, 0)
        result = subprocess.run(command + ["--candidate"], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(candidate), result.stdout)
        self.assertIn("Agent output: available", result.stdout)
        self.assertIn("Control modes: available", result.stdout)

    def test_preview_capability_is_optional_and_help_only(self):
        log = self.root / "calls"
        original = (self.bin / "iphone-use").read_text().split("\n", 1)[1]
        for help_text, success, available in [
            ("--no-open --stop", True, True),
            ("--no-open", True, False),
            ("--stop", True, False),
            ("--no-open --stop", False, False),
        ]:
            with self.subTest(help=help_text, success=success):
                log.write_text("")
                self.write_command("iphone-use", f"""
if [ "$1" = preview ]; then
  printf '%s\\n' "$*" >> '{log}'
  [ "$#" -eq 2 ] && [ "$2" = --help ] || exit 98
  printf '%s\\n' '{help_text}'
  exit {0 if success else 1}
fi
{original}
""")
                result = self.run_check()
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = "available" if available else "unavailable"
                self.assertIn(f"Live preview: {expected}.", result.stdout)
                self.assertEqual(log.read_text(), "preview --help\n")

    def test_missing_cli_and_unsupported_versions_fail_with_next_step(self):
        (self.bin / "iphone-use").unlink()
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("brew install", result.stderr)
        for version in ("0.0.9", "0.1.0-rc.1", "bad", "0.1", "1.0.0\nmalformed"):
            self.write_cli(version)
            result = self.run_check()
            self.assertNotEqual(result.returncode, 0, version)
            self.assertIn("Unsupported CLI version", result.stderr)

    def test_command_line_tools_and_non_mac_are_not_ready(self):
        (self.xcode / "Platforms/iPhoneOS.platform").rmdir()
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Select full Xcode", result.stderr)
        self.write_command("uname", "printf 'Linux\\n'")
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires a Mac", result.stderr)

    def test_development_cli_requires_an_explicit_source_workflow(self):
        self.write_cli("development")
        self.assertNotEqual(self.run_check().returncode, 0)
        result = self.run_check("--source")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("standard needs no Runner", result.stdout)
        self.assertNotEqual(self.run_check("--unknown").returncode, 0)


if __name__ == "__main__":
    unittest.main()
