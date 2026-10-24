"""Exercise the real preview daemon and private IPC without connecting a phone."""
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import uuid

CLI = Path(os.environ.get("IPHONE_USE_TEST_CLI", Path(__file__).resolve().parents[2] / ".build/debug/iphone-use"))


@unittest.skipUnless(CLI.is_file(), "Build the CLI before integration tests")
class PreviewServiceCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="iu-view-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.config = Path(self.temporary.name)
        self.env = {**os.environ, "IPHONE_USE_CONFIG_DIR": str(self.config)}
        with socket.socket() as available:
            available.bind(("127.0.0.1", 0))
            self.port = available.getsockname()[1]
        self.directory = self.config / "previews" / str(self.port)
        self.process = None
        self.addCleanup(self.stop)

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=6)

    def start(self):
        self.process = subprocess.Popen([str(CLI), "_preview-service", "--directory", str(self.directory),
                                         "--port", str(self.port)], env=self.env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline and self.process.poll() is None:
            try:
                if self.control("ping")["ok"]:
                    return
            except (OSError, ValueError):
                pass
            time.sleep(.02)
        self.fail("Preview service did not become ready")

    def control(self, operation, **fields):
        request = {"id": str(uuid.uuid4()), "version": 1, "op": operation,
                   "authorization": (self.directory / "authorization").read_text(), **fields}
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(3)
            client.connect(str(self.directory / "ipc.sock"))
            client.sendall(json.dumps(request).encode() + b"\n")
            with client.makefile("rb") as stream:
                return json.loads(stream.readline())

    def test_restart_keeps_url_but_drops_sources_and_cli_revoke_invalidates_it(self):
        self.start()
        source_token = str(uuid.uuid4())

        class Source(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                body = json.dumps({"generation": "source-generation", "url": "private-source",
                                   "state": "waiting", "readOnly": True}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("X-Preview-Generation", "source-generation")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Source)
        self.addCleanup(server.server_close)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.shutdown)
        source = f"http://127.0.0.1:{server.server_port}/{source_token}/"
        owner = str(uuid.uuid4())
        result = self.control("attach", device="fixture-phone", owner=owner, url=source)
        self.assertTrue(result["ok"], result)
        url = result["url"]
        missing = self.control("revoke", device="wrong-phone")
        self.assertFalse(missing["ok"])
        self.assertEqual(missing["error"]["code"], "preview_not_found")
        with urllib.request.urlopen(url + "state", timeout=3) as response:
            state = json.load(response)
            self.assertEqual(state["url"], url)
            self.assertEqual(response.headers["X-Preview-Generation"], state["generation"])
        stopped = subprocess.run([str(CLI), "preview-service-stop", "--port", str(self.port)],
                                 env=self.env, capture_output=True, text=True, timeout=8)
        self.assertEqual(stopped.returncode, 0, stopped.stdout + stopped.stderr)
        self.process.wait(timeout=5)
        self.start()
        with urllib.request.urlopen(url + "state", timeout=3) as response:
            self.assertEqual(json.load(response)["state"], "disconnected")
        self.assertFalse(self.control("renew", device="fixture-phone", owner=owner)["ok"])
        attached = self.control("attach", device="fixture-phone", owner=str(uuid.uuid4()), url=source)
        self.assertEqual(attached["url"], url)
        revoked = subprocess.run([str(CLI), "preview-revoke", "--device", "fixture-phone",
                                  "--port", str(self.port)], env=self.env, capture_output=True, text=True, timeout=8)
        self.assertEqual(revoked.returncode, 0, revoked.stdout + revoked.stderr)
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(url + "state", timeout=3)
        self.assertEqual(error.exception.code, 404)

    def test_occupied_port_failure_preserves_existing_listener(self):
        with socket.socket() as occupied:
            occupied.bind(("127.0.0.1", self.port))
            occupied.listen()
            result = subprocess.run([str(CLI), "preview-revoke", "--device", "fixture-phone",
                                     "--port", str(self.port)], env=self.env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)["error"]["code"], "preview_port_in_use")
            self.assertEqual(occupied.getsockname()[1], self.port)


if __name__ == "__main__":
    unittest.main()
