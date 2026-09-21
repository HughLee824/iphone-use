"""Mode CLI tests use isolated user homes and never connect to a device."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CLI = Path(__file__).resolve().parents[2] / ".build/debug/iphone-use"


@unittest.skipUnless(CLI.is_file(), "Build the CLI first")
class ModeCLITests(unittest.TestCase):
    def call(self, args, home):
        result = subprocess.run([str(CLI), *args],
                                env={**os.environ, "CFFIXED_USER_HOME": str(home)},
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        self.assertTrue(result.stdout, result.stderr.decode())
        return result.returncode, json.loads(result.stdout)

    def test_get_set_round_trip_in_isolated_home(self):
        with tempfile.TemporaryDirectory(prefix="as-mode-", dir="/private/tmp") as temporary:
            home = Path(temporary)
            path = home / ".iphone-use/config.json"
            code, reply = self.call(["config", "get", "mode"], home)
            self.assertEqual(code, 0)
            # Verify Foundation home isolation BEFORE permitting any write command.
            self.assertEqual(Path(reply["result"]["configPath"]).resolve(), path.resolve())
            self.assertEqual(reply["result"]["mode"], "standard")
            self.assertFalse(path.exists())
            for mode, backend in [("runner", "xctest"), ("standard", "apple-native")]:
                code, reply = self.call(["config", "set", "mode", mode], home)
                self.assertEqual(code, 0)
                self.assertEqual(reply["result"]["appliesTo"], "new_sessions")
                self.assertEqual(json.loads(path.read_text()), {"version": 1, "mode": mode})
                code, reply = self.call(["config", "get", "mode"], home)
                self.assertEqual(code, 0)
                self.assertEqual(reply["result"]["mode"], mode)
                self.assertEqual(reply["result"]["backend"], backend)
                self.assertEqual(reply["result"]["modeSource"], "configuration")

    def test_invalid_options_fail_before_host_or_device_access(self):
        cases = [
            (["--mode", "standard", "--backend", "xctest"], "mode_conflict"),
            (["--mode", "runner", "--backend", "apple-native"], "mode_conflict"),
            (["--mode", "standard", "--xctestrun", "/unused"], "mode_conflict"),
            (["--mode", "runner", "--native-endpoint-inventory", "/unused"], "mode_conflict"),
            (["--mode", "auto"], "invalid_mode"),
            (["--idle-timeout", "invalid"], "invalid_idle_timeout"),
            (["--backend", "auto"], "unsupported_backend"),
        ]
        with tempfile.TemporaryDirectory(prefix="as-mode-", dir="/private/tmp") as temporary:
            for options, error in cases:
                code, reply = self.call(["connect", "--device", "not-a-real-device", *options], temporary)
                self.assertNotEqual(code, 0)
                self.assertEqual(reply["error"]["code"], error)
            self.assertFalse((Path(temporary) / ".iphone-use/config.json").exists())

    def test_runner_source_option_still_validates_path_without_starting_host(self):
        with tempfile.TemporaryDirectory(prefix="as-mode-", dir="/private/tmp") as temporary:
            for options in [[], ["--mode", "runner"], ["--backend", "xctest"],
                            ["--mode", "runner", "--backend", "xctest"]]:
                code, reply = self.call(["connect", "--device", "not-a-real-device",
                                         "--xctestrun", "/missing/Runner.xctestrun", *options], temporary)
                self.assertNotEqual(code, 0)
                self.assertEqual(reply["error"]["code"], "runner_not_built")
            self.assertFalse((Path(temporary) / ".iphone-use/config.json").exists())

    def test_old_command_reads_new_config_and_old_preference_is_visible(self):
        with tempfile.TemporaryDirectory(prefix="ip-use-", dir="/private/tmp") as temporary:
            home = Path(temporary)
            code, reply = self.call(["config", "get", "mode"], home)
            self.assertEqual(code, 0)
            self.assertEqual(Path(reply["result"]["configPath"]).resolve(), (home / ".iphone-use/config.json").resolve())
            old = home / ".agentsoma/config.json"
            old.parent.mkdir(mode=0o700)
            old.write_text('{"version":1,"mode":"runner"}')
            code, reply = self.call(["config", "get", "mode"], home)
            self.assertEqual(code, 0)
            self.assertEqual(reply["result"]["modeSource"], "legacy_configuration_migration")
            self.assertFalse((home / ".iphone-use/config.json").exists())
            code, _ = self.call(["config", "set", "mode", "standard"], home)
            self.assertEqual(code, 0)
            result = subprocess.run([str(CLI.with_name("agentsoma")), "config", "get", "mode"],
                                    env={**os.environ, "CFFIXED_USER_HOME": str(home)}, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["result"]["mode"], "standard")
            self.assertEqual(json.loads(old.read_text())["mode"], "runner")

    def test_old_runner_preparation_never_silently_selects_standard(self):
        with tempfile.TemporaryDirectory(prefix="ip-use-", dir="/private/tmp") as temporary:
            home = Path(temporary)
            _, reply = self.call(["config", "get", "mode"], home)
            self.assertEqual(Path(reply["result"]["configPath"]).resolve(), (home / ".iphone-use/config.json").resolve())
            old = home / "Library/Application Support/AgentSoma/devices"
            old.mkdir(parents=True)
            (old / "old-device.json").write_text('{}')
            for empty_new_directory in [False, True]:
                if empty_new_directory:
                    (home / "Library/Application Support/iphone-use/devices").mkdir(parents=True)
                code, reply = self.call(["config", "get", "mode"], home)
                self.assertNotEqual(code, 0)
                self.assertEqual(reply["error"]["code"], "mode_selection_required")
            code, _ = self.call(["config", "set", "mode", "runner"], home)
            self.assertEqual(code, 0)
            code, reply = self.call(["config", "get", "mode"], home)
            self.assertEqual(code, 0)
            self.assertEqual(reply["result"]["mode"], "runner")

    def test_bad_config_and_keys_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix="as-mode-", dir="/private/tmp") as temporary:
            root = Path(temporary)
            _, reply = self.call(["config", "get", "mode"], root)
            path = root / ".iphone-use/config.json"
            self.assertEqual(Path(reply["result"]["configPath"]).resolve(), path.resolve())
            for args in [["config", "get", "unknown"], ["config", "set", "mode", "auto"]]:
                code, _ = self.call(args, root)
                self.assertNotEqual(code, 0)
            path.parent.mkdir(mode=0o700)
            path.write_text('{"version":2,"mode":"runner"}')
            code, reply = self.call(["connect", "--device", "not-a-real-device"], root)
            self.assertNotEqual(code, 0)
            self.assertEqual(reply["error"]["code"], "invalid_configuration")
            self.assertEqual(json.loads(path.read_text())["version"], 2)


if __name__ == "__main__":
    unittest.main()
