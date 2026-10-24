"""Exercise the real preview daemon and private IPC without connecting a phone."""
import fcntl
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
        try:
            self.control("stop")
        except (OSError, ValueError):
            pass
        if self.process and self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=6)
        # Also reap daemon ownership when ensureRunning launched the process.
        lock = self.directory / "device-service.lock"
        if lock.is_file():
            with lock.open("rb") as stream:
                deadline = time.monotonic() + 6
                while True:
                    try:
                        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        if time.monotonic() >= deadline:
                            self.fail("Preview daemon did not release ownership during cleanup")
                        time.sleep(.02)

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
        result = json.loads(stopped.stdout)["result"]
        self.assertEqual(result["state"], "stopped")
        self.assertTrue(result["stopAccepted"])
        self.assertTrue(result["exited"])
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

    def revoke_client(self, device="fixture-phone"):
        process = subprocess.Popen([str(CLI), "preview-revoke", "--device", device,
                                    "--port", str(self.port)], env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

        def cleanup():
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=8)

        self.addCleanup(cleanup)
        return process

    def test_concurrent_cold_and_warm_clients_share_one_service(self):
        for phase in ["cold", "warm"]:
            with self.subTest(phase=phase):
                clients = [self.revoke_client(f"missing-phone-{index}") for index in range(8)]
                for client in clients:
                    out, err = client.communicate(timeout=25)
                    self.assertEqual(json.loads(out)["error"]["code"], "preview_not_found", out + err)
                self.assertTrue(self.control("ping")["ok"])
                self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
                self.assertEqual((self.directory / "authorization").stat().st_mode & 0o777, 0o600)
        # Startup probes must not unlink the daemon's ownership lock.
        with (self.directory / "device-service.lock").open("rb") as stream:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_stop_fences_registration_and_client_waits_for_exit_before_restart(self):
        self.start()
        owner = str(uuid.uuid4())
        source = f"http://127.0.0.1:19999/{uuid.uuid4()}/"
        attached = self.control("attach", device="fixture-phone", owner=owner, url=source)
        self.assertTrue(attached["ok"], attached)
        entries = (self.directory / "entries.json").read_bytes()
        with socket.socket(socket.AF_UNIX) as pending_stop:
            pending_stop.settimeout(3)
            pending_stop.connect(str(self.directory / "ipc.sock"))
            request = {"id": str(uuid.uuid4()), "version": 1, "op": "stop",
                       "authorization": (self.directory / "authorization").read_text()}
            pending_stop.sendall(json.dumps(request).encode() + b"\n")
            data = b""
            while b"\n" not in data:
                chunk = pending_stop.recv(4096)
                self.assertTrue(chunk, "Service closed before acknowledging stop")
                data += chunk
            self.assertTrue(json.loads(data.split(b"\n")[0])["ok"])
            # Keep the reply connection open: the service is draining, not exited.
            for operation in ["ping", "attach", "renew", "revoke"]:
                result = self.control(operation, device="fixture-phone", owner=owner, url=source)
                self.assertEqual(result["error"]["code"], "preview_service_stopping", result)
            self.assertEqual((self.directory / "entries.json").read_bytes(), entries)
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(attached["url"] + "state", timeout=3)
            self.assertEqual(error.exception.code, 503)
            restarting = self.revoke_client()
            time.sleep(.2)
            self.assertIsNone(restarting.poll(), "Client must wait for the stopping daemon")
            self.assertIsNone(self.process.poll())
        self.process.wait(timeout=6)
        out, err = restarting.communicate(timeout=15)
        self.assertEqual(restarting.returncode, 0, out + err)
        self.assertTrue(self.control("ping")["ok"])
        self.assertEqual(self.control("renew", device="fixture-phone", owner=owner)["error"]["code"],
                         "preview_binding_lost")
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(attached["url"] + "state", timeout=3)
        self.assertEqual(error.exception.code, 404)

    def test_unclosed_stop_connection_expires_and_concurrent_clients_restart(self):
        self.start()
        with socket.socket(socket.AF_UNIX) as pending_stop:
            pending_stop.settimeout(3)
            pending_stop.connect(str(self.directory / "ipc.sock"))
            request = {"id": str(uuid.uuid4()), "version": 1, "op": "stop",
                       "authorization": (self.directory / "authorization").read_text()}
            pending_stop.sendall(json.dumps(request).encode() + b"\n")
            data = b""
            while b"\n" not in data:
                chunk = pending_stop.recv(4096)
                self.assertTrue(chunk)
                data += chunk
            response = json.loads(data.split(b"\n")[0])
            self.assertEqual(response["state"], "stop_requested")
            self.assertEqual(response["pid"], self.process.pid)
            clients = [self.revoke_client(f"missing-{index}") for index in range(8)]
            time.sleep(.2)
            self.assertIsNone(self.process.poll())
            self.assertTrue(all(client.poll() is None for client in clients))
            # Never close pending_stop to release shutdown; the daemon must enforce its deadline.
            self.process.wait(timeout=7)
            for client in clients:
                out, err = client.communicate(timeout=15)
                self.assertEqual(json.loads(out)["error"]["code"], "preview_not_found", out + err)
        self.assertTrue(self.control("ping")["ok"])

    def test_unresponsive_owner_times_out_without_starting_a_replacement(self):
        self.directory.mkdir(parents=True, mode=0o700)
        with (self.directory / "device-service.lock").open("w") as owner:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            client = self.revoke_client()
            started = time.monotonic()
            out, err = client.communicate(timeout=12)
            self.assertEqual(json.loads(out)["error"]["code"], "preview_service_busy", out + err)
            self.assertLess(time.monotonic() - started, 10)
            self.assertFalse((self.directory / "service.log").exists())
            self.assertFalse((self.directory / "ipc.sock").exists())


if __name__ == "__main__":
    unittest.main()
