"""Mode CLI tests use isolated user homes and never connect to a device."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CLI = Path(os.environ.get("IPHONE_USE_TEST_CLI", Path(__file__).resolve().parents[2] / ".build/debug/iphone-use"))


@unittest.skipUnless(CLI.is_file(), "Build the CLI first")
class ModeCLITests(unittest.TestCase):
    def call(self, args, home):
        environment = {key: value for key, value in os.environ.items() if key != "IPHONE_USE_CONFIG_DIR"}
        result = subprocess.run([str(CLI), *args],
                                env={**environment, "CFFIXED_USER_HOME": str(home)},
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        self.assertTrue(result.stdout, result.stderr.decode())
        return result.returncode, json.loads(result.stdout)

    def test_config_directory_override_ignores_existing_preferences_and_preparation(self):
        with tempfile.TemporaryDirectory(prefix="ip-isolated-", dir="/private/tmp") as temporary:
            root = Path(temporary)
            # Malformed current preferences and Runner records must not affect the isolated store.
            existing = [root / ".iphone-use/config.json", root / ".agentsoma/config.json",
                        root / "Library/Application Support/iphone-use/devices/fixture.json"]
            for path in existing:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("not valid JSON")
            isolated = root / "isolated preferences"
            environment = {**os.environ, "CFFIXED_USER_HOME": str(root), "IPHONE_USE_CONFIG_DIR": str(isolated)}
            def call(*arguments):
                result = subprocess.run([str(CLI), "config", *arguments], env=environment,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                return json.loads(result.stdout)["result"]
            fresh = call("get", "mode")
            self.assertEqual(Path(fresh["configPath"]).resolve(), (isolated / "config.json").resolve())
            self.assertEqual(fresh["modeSource"], "default")
            self.assertEqual(fresh["mode"], "standard")
            self.assertFalse(isolated.exists())
            call("set", "mode", "runner")
            self.assertEqual(call("get", "mode")["mode"], "runner")
            for path in existing:
                self.assertEqual(path.read_text(), "not valid JSON")

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

    def test_missing_xcode_reports_fix_without_creating_configuration_or_session(self):
        with tempfile.TemporaryDirectory(prefix="ip-first-use-", dir="/private/tmp") as temporary:
            root = Path(temporary)
            config = root / "preferences"
            state = root / "sessions"
            environment = {**os.environ, "IPHONE_USE_CONFIG_DIR": str(config),
                           "IPHONE_USE_STATE_DIR": str(state),
                           "DEVELOPER_DIR": str(root / "missing Xcode")}
            result = subprocess.run([str(CLI), "devices"], env=environment,
                                    capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            error = json.loads(result.stdout)["error"]
            self.assertEqual(error["code"], "xcode_unavailable")
            self.assertIn("DEVELOPER_DIR", error["message"])
            self.assertIn("Original error: xcrun:", error["message"])
            self.assertIn("does not require Runner setup", error["message"])
            self.assertFalse(config.exists())
            self.assertFalse(state.exists())

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

    def test_old_preferences_are_ignored_and_preserved(self):
        for contents in ['{"version":1,"mode":"runner"}', 'invalid JSON']:
            with self.subTest(contents=contents), tempfile.TemporaryDirectory(prefix="ip-use-", dir="/private/tmp") as temporary:
                home = Path(temporary)
                old = home / ".agentsoma/config.json"
                old.parent.mkdir(mode=0o700)
                old.write_text(contents)
                code, reply = self.call(["config", "get", "mode"], home)
                self.assertEqual(code, 0)
                current = home / ".iphone-use/config.json"
                self.assertEqual(Path(reply["result"]["configPath"]).resolve(), current.resolve())
                self.assertEqual(reply["result"]["mode"], "standard")
                self.assertEqual(reply["result"]["modeSource"], "default")
                self.assertFalse(current.exists())
                code, _ = self.call(["config", "set", "mode", "runner"], home)
                self.assertEqual(code, 0)
                code, reply = self.call(["config", "get", "mode"], home)
                self.assertEqual(code, 0)
                self.assertEqual(reply["result"]["mode"], "runner")
                self.assertEqual(reply["result"]["modeSource"], "configuration")
                self.assertEqual(old.read_text(), contents)

    def test_old_runner_preparation_is_ignored_and_preserved(self):
        with tempfile.TemporaryDirectory(prefix="ip-use-", dir="/private/tmp") as temporary:
            home = Path(temporary)
            old = home / "Library/Application Support/AgentSoma/devices"
            old.mkdir(parents=True)
            record = old / "old-device.json"
            record.write_text('{}')
            for empty_new_directory in [False, True]:
                if empty_new_directory:
                    (home / "Library/Application Support/iphone-use/devices").mkdir(parents=True)
                code, reply = self.call(["config", "get", "mode"], home)
                self.assertEqual(code, 0)
                self.assertEqual(Path(reply["result"]["configPath"]).resolve(), (home / ".iphone-use/config.json").resolve())
                self.assertEqual(reply["result"]["mode"], "standard")
                self.assertEqual(reply["result"]["modeSource"], "default")
                self.assertFalse((home / ".iphone-use/config.json").exists())
            self.assertEqual(record.read_text(), '{}')

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
