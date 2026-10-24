"""Brand checks must reject drift without overwriting approved checkout assets."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('brand_check', ROOT / 'scripts/brand/check.py')
BRAND = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRAND)


class BrandChecksTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.assets = {
            str(BRAND.BRAND / 'manifest.json'): b'{"fixture": true}\n',
            str(BRAND.BRAND / 'iphone-use-final/mark.svg'): b'<svg/>',
            BRAND.RUNNER_ICON: b'approved icon',
        }
        for name, data in self.assets.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        tools = self.root / 'scripts/brand'
        tools.mkdir(parents=True)
        for name in BRAND.TOOLS:
            (tools / name).write_text('fixture tool\n')
        # These must not be copied into, or touched by, the generation workspace.
        (self.root / 'assets/preview').mkdir()
        (self.root / 'assets/preview/apple.png').write_bytes(b'original bezel')
        (self.root / BRAND.BRAND / 'iphone-use-final/mark.png').write_bytes(b'stale local render')
        self.calls = []
        self.staging = None

    def generate(self, command, *, cwd, env, check):
        self.staging = cwd
        self.calls.append(Path(command[1]).name)
        self.assertTrue(check)
        self.assertNotEqual(cwd, self.root)
        self.assertEqual(env['NODE_PATH'], str(self.root / 'scripts/brand/node_modules'))
        self.assertFalse((cwd / 'assets/preview').exists())
        self.assertFalse((cwd / BRAND.BRAND / 'iphone-use-final/mark.png').exists())
        report = cwd / BRAND.BRAND / 'iphone-use-final/validation.json'
        report.write_text(json.dumps({'visual_review': 'not performed'}))

    def run_check(self, generate):
        inventory = ('\0'.join(self.assets) + '\0').encode()
        with patch.object(BRAND.subprocess, 'check_output', return_value=inventory), \
                patch.object(BRAND.subprocess, 'run', side_effect=generate):
            BRAND.check(self.root)

    def assert_checkout_unchanged(self):
        for name, data in self.assets.items():
            self.assertEqual((self.root / name).read_bytes(), data)
        self.assertEqual((self.root / 'assets/preview/apple.png').read_bytes(), b'original bezel')
        self.assertEqual((self.root / BRAND.BRAND / 'iphone-use-final/mark.png').read_bytes(), b'stale local render')
        self.assertFalse(self.staging.exists())

    def test_complete_pipeline_is_isolated_and_leaves_checkout_unchanged(self):
        self.run_check(self.generate)
        self.assertEqual(self.calls, list(BRAND.TOOLS))
        self.assert_checkout_unchanged()

    def test_changed_or_missing_export_fails_without_overwriting_checkout(self):
        for remove in (False, True):
            with self.subTest(remove=remove):
                def generate(command, **kwargs):
                    self.generate(command, **kwargs)
                    if self.calls[-1] == 'export-brand-assets.cjs':
                        target = kwargs['cwd'] / BRAND.RUNNER_ICON
                        if remove:
                            target.unlink()
                        else:
                            target.write_bytes(b'drifted icon')
                with self.assertRaisesRegex(ValueError, 'Brand rebuild differs'):
                    self.run_check(generate)
                self.assert_checkout_unchanged()

    def test_tool_failure_stops_pipeline_and_cleans_temporary_files(self):
        def fail(command, **kwargs):
            self.generate(command, **kwargs)
            raise subprocess.CalledProcessError(1, command)
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_check(fail)
        self.assertEqual(self.calls, ['build.py'])
        self.assert_checkout_unchanged()

    def test_automated_report_cannot_claim_manual_review(self):
        def generate(command, **kwargs):
            self.generate(command, **kwargs)
            report = kwargs['cwd'] / BRAND.BRAND / 'iphone-use-final/validation.json'
            report.write_text(json.dumps({'visual_review': 'passed'}))
        with self.assertRaisesRegex(ValueError, 'must not claim a manual'):
            self.run_check(generate)
        self.assert_checkout_unchanged()


if __name__ == '__main__':
    unittest.main()
