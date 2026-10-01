import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest


CLI = Path(__file__).resolve().parents[2] / ".build/debug/iphone-use"


@unittest.skipUnless(CLI.is_file(), "Run swift build or swift test before CLI integration tests")
class ActionObservationCLITests(unittest.TestCase):
    def run_cli(self, args, outcome="completed", refresh=None, capture_ok=True, stdin=None, lose_action=False):
        with tempfile.TemporaryDirectory(prefix="as-cli-", dir="/private/tmp") as root:
            session = "s" + "a" * 32
            directory = Path(root) / session
            directory.mkdir(mode=0o700)
            requests, failures = [], []
            stop = threading.Event()
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(directory / "ipc.sock"))
                server.listen()
                server.settimeout(0.1)

                def serve():
                    try:
                        while not stop.is_set():
                            try:
                                connection, _ = server.accept()
                            except socket.timeout:
                                continue
                            with connection, connection.makefile("rb") as stream:
                                request = json.loads(stream.readline())
                                requests.append(request)
                                if lose_action and request["op"] != "observe":
                                    continue
                                response = {"id": request["id"], "session": session}
                                if request["op"] == "observe":
                                    response.update(ok=capture_ok, result={"text": "observation=o2 refs=current", "screenshot": "/fixture/o2.png"})
                                    if not capture_ok:
                                        response["error"] = {"code": "capture_failed"}
                                else:
                                    response.update(ok=outcome == "completed", outcome=outcome, result={"inputFact": "preserved"})
                                    if refresh is not None:
                                        response["requiresObservation"] = refresh
                                connection.sendall(json.dumps(response).encode() + b"\n")
                    except Exception as error:
                        failures.append(error)

                thread = threading.Thread(target=serve, daemon=True)
                thread.start()
                try:
                    result = subprocess.run([str(CLI), "--session", session, *args],
                        env={**os.environ, "IPHONE_USE_STATE_DIR": root}, input=stdin,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
                finally:
                    stop.set()
                    thread.join(timeout=2)
                self.assertFalse(thread.is_alive())
                self.assertEqual(failures, [])
            self.assertTrue(result.stdout, f"CLI returned no JSON: exit={result.returncode}, stderr={result.stderr!r}, requests={requests!r}")
            return result.returncode, json.loads(result.stdout), requests

    def test_coordinate_video_exclusion_is_per_action_and_preserves_observation_flow(self):
        args = ["swipe", "o1", "--from-x", "315", "--from-y", "685", "--to-x", "315", "--to-y", "280",
                "--ignore-rect", "60,150,180,200", "--observe"]
        code, response, requests = self.run_cli(args, outcome="unknown", refresh=True)
        self.assertNotEqual(code, 0)
        self.assertEqual([r["op"] for r in requests], ["swipe", "observe"])
        self.assertEqual(requests[0]["ignoreRect"], "60,150,180,200")
        self.assertEqual(requests[0]["maxScreenChange"], 0.01)
        self.assertEqual(requests[0]["maxRegionChange"], 0)
        self.assertNotIn("ignoreRect", requests[1])

    def test_app_lifecycle_commands_preserve_unknown_without_replay(self):
        for command in ["terminate", "relaunch"]:
            args = [command, "com.example.fixture", "--observe"]
            code, response, requests = self.run_cli(args)
            self.assertEqual(code, 0)
            self.assertEqual(requests[0]["bundleId"], "com.example.fixture")
            self.assertEqual([r["op"] for r in requests], [command, "observe"])
            code, response, requests = self.run_cli(args, lose_action=True)
            self.assertNotEqual(code, 0)
            self.assertEqual(response["action"]["outcome"], "unknown")
            self.assertEqual([r["op"] for r in requests], [command, "observe"])

    def test_recording_commands_do_not_replay_after_lost_reply(self):
        for args, operation in [(["record-start", "--duration", "5"], "record-start"),
                                (["record-stop", "00000000-0000-0000-0000-000000000001"], "record-stop")]:
            code, response, requests = self.run_cli(args)
            self.assertEqual(code, 0)
            self.assertEqual([r["op"] for r in requests], [operation])
            code, response, requests = self.run_cli(args, lose_action=True)
            self.assertNotEqual(code, 0)
            self.assertEqual(response["outcome"], "unknown")
            self.assertEqual([r["op"] for r in requests], [operation])

    def test_all_five_commands_use_existing_host_requests(self):
        for args in [["open", "com.example.fixture"], ["tap", "o1:e11"],
                     ["swipe", "o1:e11", "--direction", "up"],
                     ["type", "o1:e8", "--mode", "replace", "--text", "O'Brien 中文"],
                     ["press", "o1:e8", "--key", "return"]]:
            with self.subTest(command=args[0]):
                code, response, requests = self.run_cli([*args, "--observe"])
                self.assertEqual(code, 0, response)
                self.assertTrue(response["ok"])
                self.assertEqual(response["action"]["result"]["inputFact"], "preserved")
                self.assertEqual(response["observation"]["result"]["screenshot"], "/fixture/o2.png")
                self.assertEqual([request["op"] for request in requests], [args[0], "observe"])
                self.assertNotEqual(requests[0]["id"], requests[1]["id"])
                self.assertTrue(all(request["version"] == 1 and "observe" not in request for request in requests))

    def test_native_home_and_long_press_never_replay_lost_input(self):
        for args in [["home", "o1"], ["long-press", "o1", "--x", "100", "--y", "200", "--duration", "1.2"]]:
            with self.subTest(command=args[0]):
                code, response, requests = self.run_cli([*args, "--observe"], lose_action=True)
                self.assertEqual(code, 1)
                self.assertEqual(response["action"]["outcome"], "unknown")
                self.assertEqual([r["op"] for r in requests], [args[0], "observe"])
                self.assertEqual(requests[0]["reference"], "o1")
                if args[0] == "long-press":
                    self.assertEqual(requests[0]["duration"], 1.2)
                    self.assertEqual((requests[0]["x"], requests[0]["y"]), (100, 200))

    def test_native_double_tap_lost_reply_is_not_two_cli_taps(self):
        code, response, requests = self.run_cli(
            ["double-tap", "o1", "--x", "100", "--y", "200", "--observe"], lose_action=True)
        self.assertEqual(code, 1)
        self.assertEqual(response["action"]["outcome"], "unknown")
        self.assertEqual([r["op"] for r in requests], ["double-tap", "observe"])
        self.assertEqual((requests[0]["x"], requests[0]["y"]), (100, 200))

    def test_native_pinch_lost_reply_preserves_geometry_without_replay(self):
        code, response, requests = self.run_cli(
            ["pinch", "o1", "--x", "195", "--y", "300", "--from-distance", "80",
             "--to-distance", "200", "--duration", "0.5", "--observe"], lose_action=True)
        self.assertEqual(code, 1)
        self.assertEqual(response["action"]["outcome"], "unknown")
        self.assertEqual([r["op"] for r in requests], ["pinch", "observe"])
        self.assertEqual([requests[0][key] for key in ["x", "y", "fromDistance", "toDistance", "duration"]],
                         [195, 300, 80, 200, 0.5])

    def test_without_flag_preserves_original_response(self):
        code, response, requests = self.run_cli(["tap", "o1:e11"])
        self.assertEqual(code, 0, response)
        self.assertEqual(response["outcome"], "completed")
        self.assertNotIn("action", response)
        self.assertEqual(len(requests), 1)

    def test_native_text_method_and_explicit_finish_are_forwarded_once(self):
        code, response, requests = self.run_cli(["type", "o1", "--mode", "insert", "--method", "paste", "--text", "A" * 100])
        self.assertEqual(code, 0, response)
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0]["textMethod"], "paste")
        self.assertEqual(requests[0]["op"], "type-with-method")
        self.assertEqual(requests[0]["text"], "A" * 100)
        token = "2F1DC2FE-B72E-4F93-B2BD-54DB23D694DD"
        code, response, requests = self.run_cli(["text-finish", "o2", "--transaction", token], lose_action=True)
        self.assertEqual(code, 1, response)
        self.assertEqual(response["outcome"], "unknown")
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0]["op"], "text-finish")
        self.assertEqual(requests[0]["transaction"], token)
        self.assertEqual(requests[0]["reference"], "o2")

    def test_native_editing_modes_are_forwarded_once_without_replay(self):
        for mode, text in [("replace", "替换🙂"), ("append", "追加"), ("replace", "")]:
            with self.subTest(mode=mode, text=text):
                code, response, requests = self.run_cli(
                    ["type", "o1", "--mode", mode, "--method", "paste", "--text", text], lose_action=True)
                self.assertEqual(code, 1, response)
                self.assertEqual(response["outcome"], "unknown")
                self.assertEqual(len(requests), 1)
                self.assertEqual(requests[0]["op"], "type-with-method")
                self.assertEqual(requests[0]["mode"], mode)
                self.assertEqual(requests[0]["text"], text)

    def test_native_preparation_and_return_field_are_forwarded_once(self):
        code, response, requests = self.run_cli(["text-prepare"])
        self.assertEqual(code, 0, response)
        self.assertEqual([request["op"] for request in requests], ["text-prepare"])
        self.assertNotIn("reference", requests[0])
        code, response, requests = self.run_cli(["text-prepare"], lose_action=True)
        self.assertEqual(code, 1, response)
        self.assertEqual(response["outcome"], "unknown")
        self.assertEqual(len(requests), 1)
        code, response, requests = self.run_cli(
            ["press", "o2", "--key", "return", "--field-rect", "18,146,354,48"], lose_action=True)
        self.assertEqual(code, 1, response)
        self.assertEqual(response["outcome"], "unknown")
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0]["key"], "return")
        self.assertEqual(requests[0]["fieldRect"], "18,146,354,48")

    def test_native_editing_keys_are_forwarded_once_after_lost_reply(self):
        for key in ["backspace", "left", "right", "up", "down", "tab", "shift-tab", "escape"]:
            with self.subTest(key=key):
                code, response, requests = self.run_cli(
                    ["press", "o2", "--key", key, "--field-rect", "60,78,724,82"], lose_action=True)
                self.assertEqual(code, 1, response)
                self.assertEqual(response["outcome"], "unknown")
                self.assertEqual(len(requests), 1)
                self.assertEqual(requests[0]["key"], key)
                self.assertEqual(requests[0]["fieldRect"], "60,78,724,82")

    def test_runner_editing_keys_keep_element_reference_without_replay(self):
        for key in ["backspace", "left", "right", "up", "down", "tab", "shift-tab"]:
            with self.subTest(key=key):
                code, response, requests = self.run_cli(
                    ["press", "o2:e8", "--key", key], lose_action=True)
                self.assertEqual(code, 1, response)
                self.assertEqual(response["outcome"], "unknown")
                self.assertEqual(len(requests), 1)
                self.assertEqual(requests[0]["key"], key)
                self.assertEqual(requests[0]["reference"], "o2:e8")
                self.assertNotIn("fieldRect", requests[0])

    def test_unknown_and_observation_failure_exit_nonzero_without_replay(self):
        for outcome, capture_ok in [("unknown", True), ("completed", False), ("unknown", False)]:
            with self.subTest(outcome=outcome, capture_ok=capture_ok):
                code, response, requests = self.run_cli(["tap", "o1:e11", "--observe"], outcome=outcome, capture_ok=capture_ok)
                self.assertEqual(code, 1)
                self.assertFalse(response["ok"])
                self.assertEqual(response["action"]["outcome"], outcome)
                self.assertEqual(response["observation"]["ok"], capture_ok)
                self.assertEqual([request["op"] for request in requests], ["tap", "observe"])

    def test_rejection_refresh_is_optional_for_older_hosts(self):
        for refresh in [None, False, True]:
            with self.subTest(refresh=refresh):
                code, response, requests = self.run_cli(["tap", "o1:e11", "--observe"], outcome="not_dispatched", refresh=refresh)
                self.assertEqual(code, 1)
                self.assertEqual(len(requests), 2 if refresh else 1)
                if not refresh:
                    self.assertEqual(response["observation"], {"skipped": "not_dispatched"})

    def test_lost_action_response_observes_without_replaying(self):
        code, response, requests = self.run_cli(["tap", "o1:e11", "--observe"], lose_action=True)
        self.assertEqual(code, 1)
        self.assertEqual(response["action"]["outcome"], "unknown")
        self.assertTrue(response["observation"]["ok"])
        self.assertEqual([request["op"] for request in requests], ["tap", "observe"])

    def test_invalid_stdin_fails_before_any_host_request(self):
        code, response, requests = self.run_cli(["type", "o1:e8", "--mode", "replace", "--stdin", "--observe"], stdin=b"\xff")
        self.assertEqual(code, 1)
        self.assertEqual(response["action"]["outcome"], "not_dispatched")
        self.assertEqual(response["observation"], {"skipped": "not_dispatched"})
        self.assertEqual(requests, [])


if __name__ == "__main__":
    unittest.main()
