import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest


WORKFLOW = Path(__file__).resolve().parents[2] / '.github/workflows/publish-verified-release.yml'
CHECKS = [textwrap.dedent(block) for block in re.findall(
    r"python3 - <<'PY'\n(.*?)\n          PY", WORKFLOW.read_text(), re.S)]


class VerifiedPublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sha = 'a' * 40
        self.env = dict(os.environ, RUNNER_TEMP=str(self.root), VERSION='0.3.8',
                        GITHUB_SHA=self.sha, ARCHIVE_SHA256='b' * 64,
                        ACCEPTANCE_SUMMARY='Runner and standard navigation verified; no submissions.')
        self.ci = {'head_sha': self.sha, 'head_branch': 'main', 'conclusion': 'success'}
        self.draft = {'isDraft': True, 'targetCommitish': self.sha,
                      'body': '## Changes\nGuard recovery fixed.\n\n## Local device acceptance — pending\nPending.\n\n## Installation\nInstructions.\n'}
        self.verified = {'version': '0.3.8', 'sourceCommit': self.sha, 'sha256': 'b' * 64}
        self.write('ci.json', {'workflow_runs': [self.ci]})
        self.write('draft.json', self.draft)
        self.write('verified.json', self.verified)
        (self.root / 'tag-refs.txt').write_text('')

    def write(self, name, value):
        (self.root / name).write_text(json.dumps(value))

    def run_check(self, index, success=True, **env):
        result = subprocess.run([sys.executable, '-c', CHECKS[index]],
                                env={**self.env, **env}, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stderr)

    def test_inputs_reject_unaccepted_or_unsafe_versions_and_digests(self):
        self.run_check(0)
        for values in [{'VERSION': '../0.3.8'}, {'VERSION': '0.3.8;echo bad'},
                       {'VERSION': '0.3.8-rc.1'}, {'ARCHIVE_SHA256': 'bad'},
                       {'ACCEPTANCE_SUMMARY': '  '}]:
            self.run_check(0, False, **values)

    def test_publication_requires_exact_successful_main_draft_and_matching_existing_tag(self):
        self.run_check(1)  # GitHub may create the tag only when the draft is published.
        for ref in [f'{self.sha}\trefs/tags/v0.3.8\n',
                    f'{"c" * 40}\trefs/tags/v0.3.8\n{self.sha}\trefs/tags/v0.3.8^{{}}\n']:
            (self.root / 'tag-refs.txt').write_text(ref)
            self.run_check(1)
        (self.root / 'tag-refs.txt').write_text(f'{"c" * 40}\trefs/tags/v0.3.8\n')
        self.run_check(1, False)
        (self.root / 'tag-refs.txt').write_text('')
        for field, value in [('head_sha', 'c' * 40), ('head_branch', 'feature'), ('conclusion', 'failure')]:
            self.write('ci.json', {'workflow_runs': [{**self.ci, field: value}]})
            self.run_check(1, False)
        self.write('ci.json', {'workflow_runs': []})
        self.run_check(1, False)
        self.write('ci.json', {'workflow_runs': [self.ci]})
        for field, value in [('isDraft', False), ('targetCommitish', 'main')]:
            self.write('draft.json', {**self.draft, field: value})
            self.run_check(1, False)

    def test_archive_identity_and_acceptance_notes_are_bound_to_verified_artifact(self):
        self.run_check(2)
        notes = (self.root / 'notes.md').read_text()
        self.assertIn(self.env['ARCHIVE_SHA256'], notes)
        self.assertIn(self.env['ACCEPTANCE_SUMMARY'], notes)
        self.assertIn('## Local device acceptance — passed', notes)
        self.assertTrue(notes.endswith('## Installation\nInstructions.\n'))
        for field in ['version', 'sourceCommit', 'sha256']:
            self.write('verified.json', {**self.verified, field: 'mismatch'})
            self.run_check(2, False)


if __name__ == '__main__':
    unittest.main()
