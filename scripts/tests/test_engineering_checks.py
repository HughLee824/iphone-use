"""The full check entry point must not silently skip CLI integration tests."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("engineering_checks", Path(__file__).resolve().parents[1] / "check.py")
CHECKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKS)


class EngineeringChecksTests(unittest.TestCase):
    def test_missing_or_nonexecutable_cli_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            cli = Path(directory) / "iphone-use"
            with self.assertRaisesRegex(RuntimeError, "Built CLI missing"):
                CHECKS.require_cli(cli)
            cli.write_text("#!/bin/sh\nexit 0\n")
            cli.chmod(0o600)
            with self.assertRaisesRegex(RuntimeError, "not executable"):
                CHECKS.require_cli(cli)
            cli.chmod(0o700)
            self.assertEqual(CHECKS.require_cli(cli)["IPHONE_USE_TEST_CLI"], str(cli))

    def test_swiftlint_version_mismatch_fails_explicitly(self):
        with patch.object(CHECKS, "run", return_value="0.0.0"):
            with self.assertRaisesRegex(RuntimeError, "Expected SwiftLint"):
                CHECKS.swiftlint_command()

    def test_suite_selection_preserves_full_default_and_separates_quick_checks(self):
        for suite, quick_count, native_count in [(None, 1, 1), ("quick", 1, 0), ("native", 0, 1)]:
            argv = ["check.py"] + (["--suite", suite] if suite else [])
            with self.subTest(suite=suite), patch("sys.argv", argv), \
                    patch.object(CHECKS, "quick_checks") as quick, \
                    patch.object(CHECKS, "native_checks") as native:
                CHECKS.main()
                self.assertEqual(quick.call_count, quick_count)
                self.assertEqual(native.call_count, native_count)
