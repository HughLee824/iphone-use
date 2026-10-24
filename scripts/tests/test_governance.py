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
    spec = importlib.util.spec_from_file_location(name.replace('-', '_').replace('/', '_'), ROOT / 'scripts' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


titles = load('checks/check-pr-title')
versions = load('plugin/set-plugin-version')
swiftlint = load('tools/install-swiftlint')


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
            subprocess.run([sys.executable, str(ROOT / 'scripts/checks/check-pr-title.py'), '--event', str(event)],
                           cwd=root, check=True, capture_output=True)
            self.assertFalse((root / 'OWNED').exists())
            event.write_text('{}')
            subprocess.run([sys.executable, str(ROOT / 'scripts/checks/check-pr-title.py'), '--event', str(event)],
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
            (root / 'scripts/tools').mkdir(parents=True)
            (root / 'scripts/tools/swiftlint.json').write_text(json.dumps({'version': '0.65.1', 'sha256': '0' * 64}))
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


class ActionlintInstallerTests(unittest.TestCase):
    def test_archive_rejects_bad_digest_and_symlink_binary(self):
        import hashlib
        import io
        import tarfile
        installer = load('tools/install-actionlint')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            archive = directory / 'tool.tar.gz'
            for symlink in (False, True):
                with tarfile.open(archive, 'w:gz') as bundle:
                    for name in ('actionlint', 'LICENSE.txt'):
                        entry = tarfile.TarInfo(name)
                        data = b'fixture'
                        if name == 'actionlint' and symlink:
                            entry.type = tarfile.SYMTYPE
                            entry.linkname = '/tmp/untrusted'
                            bundle.addfile(entry)
                        else:
                            entry.size = len(data)
                            bundle.addfile(entry, io.BytesIO(data))
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    installer.extract(archive, directory, '0' * 64)
                digest = hashlib.sha256(archive.read_bytes()).hexdigest()
                if symlink:
                    with self.assertRaisesRegex(ValueError, 'regular actionlint'):
                        installer.extract(archive, directory, digest)
                else:
                    installer.extract(archive, directory, digest)
                    self.assertEqual((directory / 'actionlint').read_bytes(), b'fixture')

    def test_download_failure_does_not_execute_payload(self):
        installer = load('tools/install-actionlint')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'scripts/tools').mkdir(parents=True)
            (root / 'scripts/tools/actionlint.json').write_text(json.dumps({
                'version': '1.7.12', 'sha256': {'linux_amd64': '0' * 64}}))
            with patch.object(installer, 'ROOT', root), patch.object(installer, 'platform_key', return_value='linux_amd64'), \
                    patch('sys.argv', ['install-actionlint.py']), \
                    patch.object(installer.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'curl')), \
                    patch.object(installer, 'version_of') as execute:
                with self.assertRaises(subprocess.CalledProcessError):
                    installer.main()
                execute.assert_not_called()
                self.assertFalse((root / '.build/tools/actionlint-1.7.12').exists())


if __name__ == '__main__':
    unittest.main()
