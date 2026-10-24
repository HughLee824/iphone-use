import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


titles = load('check-pr-title')
versions = load('set-plugin-version')
swiftlint = load('install-swiftlint')


class GovernanceTests(unittest.TestCase):
    def test_titles_accept_scopes_and_breaking_changes(self):
        for title in ['fix(runner): preserve target identity', 'docs: clarify setup',
                      'feat(cli)!: require explicit session selection', 'ci: validate PR titles']:
            titles.validate(title)

    def test_titles_reject_missing_type_vague_multiline_and_oversized(self):
        for title in ['Update files', 'fix: fix bug', 'fix: change behavior.', 'fix: change\nmore',
                      'feat: ' + 'a' * 70, 'fix: 改动', 'fix: change ', 'unknown: change behavior']:
            with self.subTest(title=title), self.assertRaises(ValueError):
                titles.validate(title)

    def test_event_title_is_data_not_shell_code(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event = root / 'event.json'
            event.write_text(json.dumps({'pull_request': {'title': 'fix: avoid $(touch OWNED) expansion'}}))
            subprocess.run([sys.executable, str(ROOT / 'scripts/check-pr-title.py'), '--event', str(event)],
                           cwd=root, check=True, capture_output=True)
            self.assertFalse((root / 'OWNED').exists())
            event.write_text('{}')
            subprocess.run([sys.executable, str(ROOT / 'scripts/check-pr-title.py'), '--event', str(event)],
                           check=True, capture_output=True)

    def version_fixture(self, root):
        for name in versions.MANIFESTS:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('{"name":"fixture","version":"0.1.20"}\n')
        skill = root / 'skills/iphone-use/SKILL.md'
        skill.parent.mkdir(parents=True)
        skill.write_text('Workflow version: **0.1.20**.\n')

    def test_version_updates_all_sources_preserving_other_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.version_fixture(root)
            updates = versions.planned_updates(root, '0.2.0')
            self.assertEqual(len(updates), 5)
            for path, content in updates.items():
                self.assertIn('0.2.0', content)
                self.assertIn('0.1.20', path.read_text())  # Planning never writes.
            for name in versions.MANIFESTS:
                self.assertEqual(json.loads(updates[root / name])['name'], 'fixture')
            self.assertEqual(len(versions.planned_updates(root, '0.1.20')), 5)

    def test_bad_version_and_drift_fail_before_any_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.version_fixture(root)
            for version in ['0.1.19', 'v1.0.0', '01.0.0', '1.0.0-rc.1', '../escape']:
                with self.subTest(version=version), self.assertRaises(ValueError):
                    versions.planned_updates(root, version)
            path = root / versions.MANIFESTS[-1]
            path.write_text('{"version":"0.1.21"}')
            with self.assertRaisesRegex(ValueError, 'differ'):
                versions.planned_updates(root, '0.2.0')
            self.assertIn('0.1.20', (root / versions.MANIFESTS[0]).read_text())

    def test_swiftlint_archive_verifies_digest_and_expected_members(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'tool.zip'
            destination = root / 'tool'
            destination.mkdir()
            with zipfile.ZipFile(archive, 'w') as bundle:
                bundle.writestr('swiftlint', b'fixture binary')
                bundle.writestr('LICENSE', 'fixture license')
            with self.assertRaisesRegex(ValueError, 'checksum'):
                swiftlint.extract(archive, destination, '0' * 64)
            self.assertEqual(list(destination.iterdir()), [])
            swiftlint.extract(archive, destination, hashlib.sha256(archive.read_bytes()).hexdigest())
            self.assertEqual((destination / 'swiftlint').read_bytes(), b'fixture binary')
            self.assertEqual((destination / 'swiftlint').stat().st_mode & 0o777, 0o755)
            with zipfile.ZipFile(archive, 'w') as bundle:
                bundle.writestr('../outside', 'unexpected')
            with self.assertRaisesRegex(ValueError, 'layout'):
                swiftlint.extract(archive, destination, hashlib.sha256(archive.read_bytes()).hexdigest())
            self.assertFalse((root / 'outside').exists())

    def test_failed_tool_download_never_executes_or_installs_a_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            (root / 'scripts/swiftlint.json').write_text(json.dumps({'version': '0.65.1', 'sha256': '0' * 64}))
            with patch.object(swiftlint, 'ROOT', root), patch('sys.argv', ['install-swiftlint.py']), \
                    patch.object(swiftlint.subprocess, 'run', side_effect=subprocess.CalledProcessError(60, 'curl')), \
                    patch.object(swiftlint.subprocess, 'check_output') as execute:
                with self.assertRaises(subprocess.CalledProcessError):
                    swiftlint.main()
                execute.assert_not_called()
            self.assertFalse((root / '.build/tools/swiftlint-0.65.1').exists())

    def test_required_gate_fails_for_failed_cancelled_or_skipped_dependencies(self):
        # Exercise the actual shell condition used by the required status gate.
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        gate = workflow.split('\n  test:\n', 1)[1]
        self.assertIn('if: always()', gate)
        self.assertIn('needs: [quick, native]', gate)
        command = next(line.strip().removeprefix('run: ') for line in gate.splitlines()
                       if line.strip().startswith('run: '))
        for quick in ['success', 'failure', 'cancelled', 'skipped']:
            for native in ['success', 'failure', 'cancelled', 'skipped']:
                result = subprocess.run(['/bin/sh', '-c', command],
                                        env={'QUICK_RESULT': quick, 'NATIVE_RESULT': native})
                self.assertEqual(result.returncode == 0, quick == native == 'success')


if __name__ == '__main__':
    unittest.main()
