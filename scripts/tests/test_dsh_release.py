import contextlib
import importlib.util
import io
import subprocess
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import Mock

spec = importlib.util.spec_from_file_location('dsh_release', Path(__file__).parents[1] / 'dsh-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class DshReleaseTests(unittest.TestCase):
    def test_only_matching_stable_harness_version(self):
        manifest = {'name': 'dsh-iphone-use', 'version': '0.1.13'}
        release.validate('0.1.13', manifest)
        for version in ['v0.1.13', '0.1.13-beta.1', '01.1.13', '0.1.10']:
            with self.subTest(version=version), self.assertRaises(ValueError):
                release.validate(version, manifest)
        with self.assertRaises(ValueError):
            release.validate('0.1.13', {**manifest, 'name': 'iphone-use-skill'})

    def test_registry_guard_rejects_existing_and_only_accepts_404(self):
        from unittest.mock import MagicMock
        with self.assertRaisesRegex(ValueError, 'already exists'):
            release.require_unpublished('0.1.13', fetch=MagicMock())
        for code in [401, 403, 404, 429, 500]:
            fetch = Mock(side_effect=urllib.error.HTTPError('fixture', code, '', {}, None))
            with self.subTest(code=code):
                if code == 404:
                    release.require_unpublished('0.1.13', fetch=fetch)
                else:
                    with self.assertRaises(urllib.error.HTTPError):
                        release.require_unpublished('0.1.13', fetch=fetch)

    def test_registry_identity_and_integrity_must_match(self):
        expected = {'name': 'dsh-iphone-use', 'version': '0.1.13', 'integrity': 'sha512-fixture'}
        actual = {**expected, 'dist': {'integrity': expected['integrity']}}
        release.verify_metadata(expected, actual)
        for changed in [{**actual, 'name': 'iphone-use-skill'}, {**actual, 'version': '0.1.10'},
                        {**actual, 'dist': {'integrity': 'wrong'}}]:
            with self.assertRaises(ValueError):
                release.verify_metadata(expected, changed)
        with self.assertRaises(ValueError):
            release.verify_metadata({**expected, 'name': 'iphone-use-skill'}, actual)

    def test_installation_retries_only_registry_availability_and_reports_errors(self):
        for code in ['E404', 'ETARGET', 'EACCES']:
            failed = subprocess.CompletedProcess(['npm'], 1, '', f'npm error code {code}\n')
            run = Mock(side_effect=[failed, subprocess.CompletedProcess(['npm'], 0)])
            sleep = Mock()
            with contextlib.redirect_stderr(io.StringIO()) as errors:
                if code == 'EACCES':
                    with self.assertRaises(subprocess.CalledProcessError):
                        release.install(['npm'], run=run, sleep=sleep)
                    sleep.assert_not_called()
                else:
                    release.install(['npm'], run=run, sleep=sleep)
                    sleep.assert_called_once_with(20)
            self.assertIn(code, errors.getvalue())

    def test_installation_retries_are_bounded(self):
        run = Mock(return_value=subprocess.CompletedProcess(['npm'], 1, '', 'npm error code E404\n'))
        sleep = Mock()
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(subprocess.CalledProcessError):
            release.install(['npm'], attempts=2, run=run, sleep=sleep)
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(20)
