import importlib.util
import contextlib
import io
import subprocess
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import Mock


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / f'{name}.py')
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


release = module('check-skill-release')
publication = module('verify-skill-publication')


class SkillReleaseTests(unittest.TestCase):
    def test_installation_retries_only_registry_propagation_errors(self):
        for code in ['ETARGET', 'E404']:
            with self.subTest(code=code):
                unavailable = subprocess.CompletedProcess(['npx'], 1, '', f'npm error code {code}\n')
                success = subprocess.CompletedProcess(['npx'], 0, '{"result":"installed"}', '')
                run = Mock(side_effect=[unavailable, success])
                sleep = Mock()
                with contextlib.redirect_stderr(io.StringIO()) as errors, contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(publication.run_npx(['npx'], run=run, sleep=sleep), success)
                self.assertIn(code, errors.getvalue())
                self.assertEqual(run.call_count, 2)
                sleep.assert_called_once_with(20)

    def test_installer_errors_are_reported_without_retry(self):
        failure = subprocess.CompletedProcess(['npx'], 1, '', 'Conflicting skills: preserve this directory')
        run = Mock(return_value=failure)
        sleep = Mock()
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            with self.assertRaises(subprocess.CalledProcessError):
                publication.run_npx(['npx'], run=run, sleep=sleep)
        self.assertIn('Conflicting skills', errors.getvalue())
        run.assert_called_once()
        sleep.assert_not_called()

    def test_registry_retries_are_bounded(self):
        run = Mock(return_value=subprocess.CompletedProcess(['npx'], 1, '', 'npm error code ETARGET\n'))
        sleep = Mock()
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(subprocess.CalledProcessError):
                publication.run_npx(['npx'], attempts=2, run=run, sleep=sleep)
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(20)

    def test_only_matching_stable_portable_version_is_accepted(self):
        manifest = {'name': 'iphone-use-skill', 'version': '0.1.13'}
        release.validate('0.1.13', manifest)
        for value in ['v0.1.13', '0.1.13-beta.1', '0.1.12', '01.1.13', '$(echo unsafe)']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.validate(value, manifest)
        with self.assertRaises(ValueError):
            release.validate('0.1.13', {**manifest, 'name': 'dsh-iphone-use'})

    def test_existing_version_is_rejected(self):
        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                pass

        with self.assertRaisesRegex(ValueError, 'already exists'):
            release.require_unpublished('0.1.13', fetch=lambda *args, **kwargs: Response())

    def test_only_404_proves_version_absent(self):
        for status in [401, 403, 404, 429, 500]:
            def fetch(url, **kwargs):
                raise urllib.error.HTTPError(url, status, 'fixture', {}, None)

            with self.subTest(status=status):
                if status == 404:
                    release.require_unpublished('0.1.13', fetch=fetch)
                else:
                    with self.assertRaises(urllib.error.HTTPError):
                        release.require_unpublished('0.1.13', fetch=fetch)

    def test_publication_requires_exact_identity_and_integrity(self):
        expected = {'version': '0.1.13', 'integrity': 'sha512-example'}
        actual = {'name': 'iphone-use-skill', 'version': '0.1.13', 'dist': {'integrity': 'sha512-example'}}
        publication.verify_metadata(expected, actual)
        for changed in [{**actual, 'name': 'dsh-iphone-use'},
                        {**actual, 'version': '0.1.12'},
                        {**actual, 'dist': {'integrity': 'sha512-other'}}]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                publication.verify_metadata(expected, changed)
