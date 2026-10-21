"""Port configuration and CLI/host request integration; no physical device is used."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest

CLI = Path(__file__).resolve().parents[2] / ".build/debug/iphone-use"


@unittest.skipUnless(CLI.is_file(), "Build the CLI before integration tests")
class PreviewPortCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="iu-port-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.config = self.root / "config"
        self.env = {**os.environ, "IPHONE_USE_CONFIG_DIR": str(self.config),
                    "IPHONE_USE_STATE_DIR": str(self.root)}
        self.session = "s" + "a" * 32

    def cli(self, *args):
        result = subprocess.run([str(CLI), *args], env=self.env, capture_output=True, text=True, timeout=10)
        self.assertTrue(result.stdout, result.stderr)
        return result.returncode, json.loads(result.stdout)

    def preview_request(self, *args, failure=None):
        directory = self.root / self.session
        directory.mkdir(exist_ok=True)
        requests, errors = [], []
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(directory / "ipc.sock"))
            server.listen()
            server.settimeout(5)

            def serve():
                try:
                    connection, _ = server.accept()
                    with connection, connection.makefile("rb") as stream:
                        request = json.loads(stream.readline())
                        requests.append(request)
                        response = {"id": request["id"], "session": self.session, "ok": failure is None}
                        if failure:
                            response["error"] = {"code": failure, "message": "Use another preview --port"}
                        else:
                            response["result"] = {"state": "waiting", "port": request.get("port"),
                                                  "url": "http://127.0.0.1:9876/fixture/"}
                        connection.sendall(json.dumps(response).encode() + b"\n")
                        connection.settimeout(2)
                        try:
                            connection.recv(1)
                        except socket.timeout:
                            pass
                except Exception as error:
                    errors.append(error)

            thread = threading.Thread(target=serve, daemon=True)
            thread.start()
            try:
                result = self.cli("--session", self.session, "preview", "--no-open", *args)
            finally:
                thread.join(timeout=6)
                (directory / "ipc.sock").unlink()
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])
        self.assertEqual(len(requests), 1, "CLI must not silently retry, reconnect or change configuration")
        return result, requests[0]

    def test_default_saved_and_explicit_port_precedence(self):
        code, result = self.cli("config", "get", "preview-port")
        self.assertEqual(code, 0)
        self.assertEqual(result["result"]["port"], 8765)
        self.assertFalse(self.config.exists())
        (_, _), request = self.preview_request()
        self.assertEqual((request["port"], request["portExplicit"]), (8765, False))
        self.assertFalse(self.config.exists())
        self.assertEqual(self.cli("config", "set", "preview-port", "9876")[0], 0)
        (_, _), request = self.preview_request()
        self.assertEqual((request["port"], request["portExplicit"]), (9876, False))
        (_, _), request = self.preview_request("--port", "9877")
        self.assertEqual((request["port"], request["portExplicit"]), (9877, True))
        self.assertEqual(self.cli("config", "get", "preview-port")[1]["result"]["port"], 9876)
        self.assertFalse((self.config / "config.json").exists())

    def test_collision_is_preserved_and_agent_can_retry_same_session(self):
        (code, reply), first = self.preview_request(failure="preview_port_in_use")
        self.assertNotEqual(code, 0)
        self.assertEqual(reply["error"]["code"], "preview_port_in_use")
        (code, _), second = self.preview_request("--port", "9877")
        self.assertEqual(code, 0)
        self.assertEqual(first["session"], second["session"])
        self.assertEqual(second["port"], 9877)
        self.assertFalse(self.config.exists())

    def test_invalid_ports_and_stop_conflict_do_not_contact_host(self):
        for value in ["0", "1023", "65536", "999999999"]:
            code, result = self.cli("--session", self.session, "preview", "--port", value, "--no-open")
            self.assertNotEqual(code, 0)
            self.assertEqual(result["error"]["code"], "invalid_preview_port")
            self.assertNotEqual(self.cli("config", "set", "preview-port", value)[0], 0)
        code, reply = self.cli("--session", self.session, "preview", "--stop", "--port", "9876")
        self.assertNotEqual(code, 0)
        self.assertIn("--stop", reply["error"]["message"])
        self.assertFalse(self.config.exists())

    def test_explicit_port_and_stop_can_bypass_malformed_saved_port(self):
        self.config.mkdir()
        file = self.config / "preview.json"
        file.write_text("malformed")
        (code, _), request = self.preview_request("--port", "9876")
        self.assertEqual(code, 0)
        self.assertEqual(request["port"], 9876)
        (code, _), request = self.preview_request("--stop")
        self.assertEqual(code, 0)
        self.assertEqual(request["op"], "preview-stop")
        self.assertNotIn("port", request)
        self.assertEqual(file.read_text(), "malformed")

    def test_early_preview_flags_are_validated_before_device_access(self):
        cases = [
            (["--mode", "runner", "--preview"], "requires --progress"),
            (["--mode", "standard", "--progress", "--preview"], "Runner mode"),
            (["--mode", "runner", "--port", "9876"], "requires --preview"),
            (["--mode", "runner", "--progress", "--preview", "--port", "0"], "1024"),
        ]
        for args, message in cases:
            code, result = self.cli("connect", "--device", "not-a-real-device", *args)
            self.assertNotEqual(code, 0)
            self.assertIn(message, result["error"]["message"])
            self.assertNotIn("event", result)
        self.assertFalse(list(self.root.glob("s*")), "Invalid options must not create a session or launch Runner")


if __name__ == "__main__":
    unittest.main()
