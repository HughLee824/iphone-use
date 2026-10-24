"""Exercise discovery and reuse through real local IPC, without a phone."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
CLI = Path(os.environ.get("IPHONE_USE_TEST_CLI", ROOT / '.build/debug/iphone-use'))


@unittest.skipUnless(CLI.is_file(), 'Build the CLI first')
class SessionReuseCLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='iu-reuse-', dir='/private/tmp')
        self.root = Path(self.temp.name)
        self.session = 's' + 'a' * 32
        self.directory = self.root / self.session
        self.directory.mkdir(mode=0o700)
        (self.directory / 'config.json').write_text(json.dumps(dict(
            session=self.session, device='fixture', xctestrun='/signed/Runner.xctestrun',
            idleTimeoutSeconds=3600, backend='xctest')))
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(str(self.directory / 'ipc.sock'))
        self.server.listen()
        self.server.settimeout(0.1)
        self.stopped = threading.Event()
        self.operations = []
        self.result = dict(runnerSession='same-runner', connection=dict(phase='ready'),
                           preview=dict(state='streaming', url='http://127.0.0.1:8765/same/'))
        self.thread = threading.Thread(target=self.serve)
        self.thread.start()

    def serve(self):
        while not self.stopped.is_set():
            try:
                client, _ = self.server.accept()
            except socket.timeout:
                continue
            with client, client.makefile('rb') as stream:
                request = json.loads(stream.readline())
                self.operations.append(request['op'])
                client.sendall((json.dumps(dict(id=request['id'], session=self.session,
                    ok=True, hostPid=123, idleTimeoutSeconds=3600, result=self.result)) + '\n').encode())

    def tearDown(self):
        self.stopped.set()
        self.thread.join(timeout=2)
        self.server.close()
        self.temp.cleanup()

    def call(self, *args, ok=True):
        result = subprocess.run([str(CLI), *args], env={**os.environ, 'IPHONE_USE_STATE_DIR': str(self.root)},
                                capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_discover_and_reuse_only_query_status_and_preserve_preview(self):
        listed = self.call('sessions', '--device', 'fixture')['result']['sessions']
        self.assertEqual([v['session'] for v in listed], [self.session])
        reused = self.call('connect', '--device', 'fixture', '--mode', 'runner', '--reuse')
        self.assertTrue(reused['reused'])
        self.assertEqual(reused['session'], self.session)
        self.assertEqual(reused['result'], self.result)
        self.assertEqual(reused['idleTimeoutSeconds'], 3600)
        self.assertFalse(reused['lifecycle']['disconnectOnFinish'])
        self.assertEqual(self.operations, ['status', 'status'])
        self.assertEqual([p.name for p in self.root.iterdir()], [self.session])

    def test_conflict_never_starts_host_or_queries_other_mode(self):
        response = self.call('connect', '--device', 'fixture', '--mode', 'standard', '--reuse', ok=False)
        self.assertEqual(response['error']['code'], 'session_configuration_conflict')
        self.assertEqual(self.operations, [])
        self.assertEqual(len(list(self.root.iterdir())), 1)

    def test_filter_and_ended_directory_do_not_probe_or_create(self):
        self.assertEqual(self.call('sessions', '--device', 'different')['result']['sessions'], [])
        self.assertEqual(self.operations, [])
        (self.directory / 'ipc.sock').unlink()
        self.assertEqual(self.call('sessions')['result']['sessions'], [])
        self.assertTrue(self.directory.exists())

    def test_pending_clipboard_does_not_attach_or_disconnect(self):
        self.result['touchPaste'] = dict(restorePending=True)
        response = self.call('connect', '--device', 'fixture', '--mode', 'runner', '--reuse', ok=False)
        self.assertEqual(response['error']['code'], 'session_transaction_pending')
        self.assertEqual(self.operations, ['status'])
