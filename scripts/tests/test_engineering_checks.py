"""The full check entry point must not silently skip CLI integration tests."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

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
