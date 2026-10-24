"""The full check entry point must not silently skip CLI integration tests."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("engineering_checks", Path(__file__).resolve().parents[1] / "check.py")
CHECKS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECKS)


class EngineeringChecksTests(unittest.TestCase):
    def test_direct_governance_entry_runs_every_discovered_test(self):
        spec = importlib.util.spec_from_file_location(
            'governance_entry', CHECKS.ROOT / 'scripts/tests/test_governance.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        suite = unittest.defaultTestLoader.loadTestsFromModule(module)
        result = subprocess.run(
            [sys.executable, str(CHECKS.ROOT / 'scripts/tests/test_governance.py'), '-v'],
            check=True, capture_output=True, text=True)
        for group in suite:
            for test in group:
                # unittest's display format differs between supported Python versions.
                label = str(test).replace('governance_entry.', '__main__.')
                self.assertIn(f'{label} ... ok', result.stderr)

    def test_brand_ci_runs_inside_required_native_job(self):
        workflow = (CHECKS.ROOT / '.github/workflows/ci.yml').read_text()
        native = workflow.split('\n  native:\n', 1)[1].split('\n  test:\n', 1)[0]
        self.assertIn('npm ci --prefix scripts/brand --ignore-scripts', native)
        self.assertIn('python3 -m venv .build/brand-venv', native)
        self.assertIn('.build/brand-venv/bin/python -m pip install -r scripts/brand/requirements.txt', native)
        self.assertIn('.build/brand-venv/bin/python scripts/brand/check.py', native)
        self.assertNotIn('continue-on-error:', native)
        self.assertIn('needs: [quick, native]', workflow.split('\n  test:\n', 1)[1])

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

    def test_acceptance_checks_only_run_help_and_fake_transport_self_test(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for layout in ('xcode', 'native'):
                directory = root / layout
                directory.mkdir()
                for name in ('IPhoneUseCore', 'IPhoneUseRunnerSupport', 'AppleNativeBridge'):
                    object_path = directory / f'{name}.o' if layout == 'xcode' else directory / f'{name}.build/source.o'
                    object_path.parent.mkdir(exist_ok=True)
                    object_path.touch()
                if layout == 'native':
                    (directory / 'Modules').mkdir()
                with patch.object(CHECKS, 'ROOT', root), patch.object(CHECKS, 'run') as run:
                    CHECKS.acceptance_checks(directory, 2)
                    commands = [call.args[0] for call in run.call_args_list]
                    self.assertIn('CODE_SIGNING_ALLOWED=NO', commands[0])
                    self.assertEqual(commands[-2][1:], ['--help'])
                    self.assertEqual(commands[-1][1:], ['--self-test'])
                    self.assertEqual(len(commands), 4)

    def test_homebrew_template_imports_tools_from_current_and_published_legacy_layouts(self):
        import os
        workflow = (CHECKS.ROOT / 'packaging/homebrew-tap/.github/workflows/update-iphone-use.yml').read_text()
        selection = workflow.split('          release_tools=', 1)[1].split('          python3 ', 1)[0]
        selection = 'release_tools=' + selection
        for layout in ('source/scripts/release', 'source/scripts'):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                directory = root / layout
                directory.mkdir(parents=True)
                (directory / 'verify-release.py').touch()
                (directory / 'release_artifact.py').write_text('marker = "correct tagged source"\n')
                command = selection + '\nPYTHONPATH="$release_tools" "$TEST_PYTHON" -c \'import release_artifact; print(release_artifact.marker)\''
                result = subprocess.run(['/bin/sh', '-eu', '-c', command], cwd=root,
                                        env={**os.environ, 'TEST_PYTHON': sys.executable},
                                        check=True, capture_output=True, text=True)
                self.assertEqual(result.stdout.strip(), 'correct tagged source')
        self.assertIn('PYTHONPATH="$release_tools" python3', workflow)
