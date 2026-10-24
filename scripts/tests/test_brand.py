"""Brand checks must regenerate every output and reject incomplete Git inventories."""
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
        self.assets = {name: b'fixture input' for name in BRAND.INPUTS}
        self.export = str(BRAND.BRAND / 'wordmark.png')
        self.assets.update({
            str(BRAND.BRAND / 'manifest.json'): json.dumps({
                'files': [{'path': 'wordmark.png'}], 'app_icon': {'path': BRAND.RUNNER_ICON}
            }).encode(),
            str(BRAND.DESIGN / 'manifest.json'): b'{"svg_sha256": {"mark.svg": "fixture digest"}}',
            str(BRAND.DESIGN / 'resolved-geometry.json'): b'{}',
            str(BRAND.DESIGN / 'mark.svg'): b'<svg/>',
            self.export: b'approved wordmark',
            BRAND.RUNNER_ICON: b'approved icon',
        })
        for name, data in self.assets.items():
            self.write(self.root / name, data)
        self.outputs = BRAND.declared_outputs(self.root)
        tools = self.root / 'scripts/brand'
        tools.mkdir(parents=True)
        for name in BRAND.TOOLS:
            (tools / name).write_text('fixture tool\n')
        self.git('init', '--quiet')
        self.git('add', 'assets/brand', 'Runner')
        self.write(self.root / 'assets/preview/apple.png', b'original bezel')
        self.write(self.root / BRAND.DESIGN / 'mark.png', b'stale local render')
        self.calls = []
        self.staging = None
        self.omit_stage = None

    @staticmethod
    def write(path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def git(self, *arguments):
        subprocess.run(['git', *arguments], cwd=self.root, check=True, capture_output=True)

    def generate(self, command, *, cwd, env, check):
        self.staging = cwd
        stage = Path(command[1]).name
        if not self.calls:
            for name in self.outputs | BRAND.LOCAL_OUTPUTS:
                self.assertFalse((cwd / name).exists(), f'Output was seeded: {name}')
        self.calls.append(stage)
        self.assertTrue(check)
        self.assertNotEqual(cwd, self.root)
        self.assertEqual(env['NODE_PATH'], str(self.root / 'scripts/brand/node_modules'))
        self.assertFalse((cwd / 'assets/preview').exists())
        if stage == self.omit_stage:
            return
        if stage == 'build.py':
            for name in self.outputs:
                if Path(name).parent == BRAND.DESIGN:
                    self.write(cwd / name, self.assets[name])
        elif stage == 'render.cjs':
            for name in BRAND.LOCAL_OUTPUTS - {str(BRAND.DESIGN / 'validation.json')}:
                self.write(cwd / name, b'fresh render')
        elif stage == 'verify.py':
            self.write(cwd / BRAND.DESIGN / 'validation.json', b'{"visual_review": "not performed"}')
        elif stage == 'export-brand-assets.cjs':
            for name in self.outputs:
                if Path(name).parent != BRAND.DESIGN:
                    self.write(cwd / name, self.assets[name])

    def run_check(self, generate=None):
        real_run = subprocess.run
        def dispatch(command, *args, **kwargs):
            # Keep the Git inventory real, including index-only removals.
            if command[0] == 'git':
                return real_run(command, *args, **kwargs)
            return (generate or self.generate)(command, *args, **kwargs)
        with patch.object(BRAND.subprocess, 'run', side_effect=dispatch):
            BRAND.check(self.root)

    def assert_checkout_unchanged(self):
        for name, data in self.assets.items():
            self.assertEqual((self.root / name).read_bytes(), data)
        self.assertEqual((self.root / 'assets/preview/apple.png').read_bytes(), b'original bezel')
        self.assertEqual((self.root / BRAND.DESIGN / 'mark.png').read_bytes(), b'stale local render')
        if self.staging is not None:
            self.assertFalse(self.staging.exists())

    def test_complete_pipeline_starts_without_outputs_and_preserves_checkout(self):
        self.run_check()
        self.assertEqual(self.calls, list(BRAND.TOOLS))
        self.assert_checkout_unchanged()

    def test_successful_no_op_build_or_export_is_rejected(self):
        for stage in ('build.py', 'export-brand-assets.cjs'):
            with self.subTest(stage=stage):
                self.calls = []
                self.omit_stage = stage
                with self.assertRaisesRegex(ValueError, 'Generated file inventory differs: missing='):
                    self.run_check()
                self.assert_checkout_unchanged()

    def test_existing_but_untracked_manifest_output_is_rejected_before_execution(self):
        self.git('rm', '--cached', self.export)
        self.assertTrue((self.root / self.export).is_file())
        with self.assertRaisesRegex(ValueError, 'Git tracking: missing='):
            self.run_check()
        self.assertEqual(self.calls, [])
        self.assert_checkout_unchanged()

    def test_tracked_but_missing_output_is_rejected_before_execution(self):
        (self.root / self.export).unlink()
        with self.assertRaises(FileNotFoundError):
            self.run_check()
        self.assertEqual(self.calls, [])

    def test_removing_manifest_entry_and_tracking_does_not_hide_generated_output(self):
        name = str(BRAND.BRAND / 'manifest.json')
        manifest = json.loads(self.assets[name])
        manifest['files'] = []
        self.assets[name] = json.dumps(manifest).encode()
        (self.root / name).write_bytes(self.assets[name])
        self.git('rm', '--cached', self.export)
        # The exporter still creates this file, even though both inventories omit it.
        with self.assertRaisesRegex(ValueError, 'undeclared=.*wordmark.png'):
            self.run_check()
        self.assert_checkout_unchanged()

    def test_undeclared_tracked_asset_is_rejected_before_execution(self):
        self.write(self.root / BRAND.BRAND / 'forgotten.png', b'undeclared')
        self.git('add', 'assets/brand/forgotten.png')
        with self.assertRaisesRegex(ValueError, 'undeclared=.*forgotten.png'):
            self.run_check()
        self.assertEqual(self.calls, [])
        self.assert_checkout_unchanged()

    def test_changed_missing_or_extra_generated_file_is_rejected(self):
        for change in ('modify', 'remove', 'extra'):
            with self.subTest(change=change):
                self.calls = []
                def generate(command, **kwargs):
                    self.generate(command, **kwargs)
                    if self.calls[-1] == 'export-brand-assets.cjs':
                        target = kwargs['cwd'] / BRAND.RUNNER_ICON
                        if change == 'modify':
                            target.write_bytes(b'drifted icon')
                        elif change == 'remove':
                            target.unlink()
                        else:
                            self.write(kwargs['cwd'] / BRAND.BRAND / 'extra.png', b'undeclared')
                with self.assertRaises(ValueError):
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
            if self.calls[-1] == 'verify.py':
                report = kwargs['cwd'] / BRAND.DESIGN / 'validation.json'
                report.write_text('{"visual_review": "passed"}')
        with self.assertRaisesRegex(ValueError, 'must not claim a manual'):
            self.run_check(generate)
        self.assert_checkout_unchanged()

    def test_manifest_paths_cannot_escape_or_overwrite_inputs(self):
        manifest = self.root / BRAND.BRAND / 'manifest.json'
        for name in ('../preview/apple.png', '/tmp/escape', 'iphone-use-final/geometry.json', 'wordmark.png'):
            with self.subTest(name=name):
                data = json.loads(self.assets[str(BRAND.BRAND / 'manifest.json')])
                data['files'].append({'path': name})
                manifest.write_text(json.dumps(data))
                with self.assertRaises(ValueError):
                    self.run_check()
                self.assertEqual(self.calls, [])
        manifest.write_bytes(self.assets[str(BRAND.BRAND / 'manifest.json')])
        self.assert_checkout_unchanged()


if __name__ == '__main__':
    unittest.main()
