import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import tempfile
import threading
import unittest


CLI = Path(__file__).resolve().parents[2] / ".build/debug/iphone-use"


@unittest.skipUnless(CLI.is_file(), "Run swift build or swift test before CLI integration tests")
class ActionObservationCLITests(unittest.TestCase):
    def run_cli(self, args, outcome="completed", refresh=None, capture_ok=True, stdin=None, lose_action=False, attached=None, details=None):
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
                                    response.update(ok=outcome in ("completed", "prepared"), outcome=outcome, result=details if details is not None else {"inputFact": "preserved"})
                                    if attached is not None:
                                        response["observation"] = attached
                                    if refresh is not None:
                                        response["requiresObservation"] = refresh
                                connection.sendall(json.dumps(response).encode() + b"\n")
                                # Keep the fixture socket open until the client consumes
                                # its response; immediate close can race Network.framework
                                # delivery for larger diagnostic replies on macOS.
                                connection.settimeout(2)
                                try:
                                    connection.recv(1)
                                except socket.timeout:
                                    pass
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

    def test_touch_paste_is_explicit_staging_and_keeps_prepared_receipt(self):
        details = {"phase": "awaiting_touch_paste", "textInserted": False, "inputReportsSent": 0,
                   "pasteboard": {"transactionID": "touch-token", "restorePending": True}}
        attached = {"ok": True, "result": {"observation": "o2", "screenshot": "/fixture/o2.png"}}
        code, response, requests = self.run_cli(
            ["type", "o1", "--mode", "insert", "--method", "touch-paste", "--stdin", "--observe", "--agent-output"],
            outcome="prepared", attached=attached, details=details, stdin="中文\r\nEnglish".encode())
        try:
            self.assertEqual(code, 0)
            self.assertEqual(len(requests), 1)
            self.assertEqual(requests[0]["op"], "type-with-method")
            self.assertEqual(requests[0]["textMethod"], "touch-paste")
            self.assertEqual(requests[0]["text"], "中文\r\nEnglish")
            self.assertEqual(response["action"]["outcome"], "prepared")
            self.assertFalse(response["agentSummary"]["textInserted"])
            self.assertEqual(response["agentSummary"]["nextStep"], "inspect_then_touch_paste_and_verify_before_text_finish")
        finally:
            if "receipt" in response:
                shutil.rmtree(Path(response["receipt"]).parent)

    def test_agent_output_keeps_attached_observations_without_another_host_call(self):
        attached = {"ok": True, "phase": "pre_input_rejection", "result": {
            "observation": "o2", "refs": "current", "screenshot": "/fixture/o2.png"}}
        checks = [{"stage": "before_clipboard", "attempt": n, "inTime": True,
                   "screenGuard": {"accepted": True, "fieldPixelsMatch": True, "fieldTemporalMatch": False},
                   "mediaPhaseSamples": ["diagnostics"] * 100} for n in range(1, 7)]
        details = {"preInputChecks": checks, "pasteboard": {"restorePending": True, "transactionID": "t1"}}
        for args in [["type", "o1", "--mode", "replace", "--text", "中文", "--observe"],
                     ["text-prepare"], ["text-finish", "o1", "--transaction", "t1"]]:
            for outcome in ["completed", "not_dispatched", "unknown"]:
                with self.subTest(command=args[0], outcome=outcome):
                    code, response, requests = self.run_cli([*args, "--agent-output"],
                        outcome=outcome, refresh=True, attached=attached, details=details)
                    receipt = Path(response["receipt"])
                    try:
                        full = json.loads(receipt.read_text())
                        self.assertEqual(code, 0 if outcome == "completed" else 1)
                        self.assertEqual([r["op"] for r in requests], [args[0]])
                        self.assertNotIn("agentOutput", requests[0])
                        self.assertEqual(response["observation"], attached)
                        action = response.get("action", response)
                        original = full.get("action", full)
                        self.assertEqual(action["outcome"], outcome)
                        self.assertEqual(original["result"], details)
                        self.assertEqual(action["result"]["pasteboard"], details["pasteboard"])
                        self.assertNotIn("preInputChecks", action["result"])
                        self.assertEqual(response["agentSummary"]["nextStep"], "inspect_attached_observation")
                        self.assertEqual(receipt.stat().st_mode & 0o777, 0o600)
                    finally:
                        shutil.rmtree(receipt.parent)

    def test_dynamic_tap_summary_and_raw_receipt_keep_distinct_formats(self):
        guard = {"accepted": True, "algorithm": "bounded-overlay-contrast-v1",
                 "validationScope": "explicit_target_and_anchor", "dynamicMatches": [True, True],
                 "screenChange": 0.265625, "maxScreenChange": 0.01, "regionChanges": []}
        attached = {"ok": True, "result": {"observation": "o2", "screenshot": "/fixture/o2.png"}}
        code, response, requests = self.run_cli(
            ["tap", "o1", "--x", "337", "--y", "793", "--dynamic-target", "321,778,31,31",
             "--dynamic-anchor", "58,656,84,26", "--observe", "--agent-output"],
            attached=attached, details={"screenGuard": guard})
        receipt = Path(response["receipt"])
        try:
            self.assertEqual(code, 0)
            self.assertEqual(len(requests), 1)
            self.assertEqual(response["action"]["outcome"], "completed")
            self.assertEqual(response["observation"], attached)
            self.assertEqual(response["agentSummary"]["comparison"]["mismatches"], [])
            self.assertEqual(response["agentSummary"]["comparison"]["dynamicMatches"], [True, True])
            raw = json.loads(receipt.read_text())
            self.assertNotIn("agentSummary", raw)
            self.assertEqual(raw["action"]["result"]["screenGuard"], guard)
        finally:
            shutil.rmtree(receipt.parent)

    def test_default_output_retains_all_diagnostics(self):
        details = {"preInputChecks": [{"mediaPhaseSamples": ["unchanged"]}]}
        code, response, requests = self.run_cli(["text-prepare"], details=details)
        self.assertEqual(code, 0)
        self.assertEqual(response["result"], details)
        self.assertNotIn("agentSummary", response)
        self.assertNotIn("receipt", response)
        self.assertEqual(len(requests), 1)

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

    def test_scoped_preparation_uses_fail_closed_operation(self):
        code, response, requests = self.run_cli(["text-prepare", "--field-rect", "18,209,354,160", "--ignore-rect", "18,89,177,60"])
        self.assertEqual(code, 0, response)
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0]["op"], "text-prepare-scoped")
        self.assertEqual(requests[0]["fieldRect"], "18,209,354,160")
        self.assertEqual(requests[0]["ignoreRect"], "18,89,177,60")
        code, response, requests = self.run_cli(["text-prepare", "--field-rect", "18,209,354,160"], lose_action=True)
        self.assertEqual(code, 1, response)
        self.assertEqual(response["outcome"], "unknown")
        self.assertEqual(len(requests), 1)

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

    def test_explicit_caret_uses_versioned_wire_operations_without_replay(self):
        for command, flags, operation in [("type", ["--mode", "insert", "--text", "中文", "--method", "paste"], "type-with-caret"),
                                          ("press", ["--key", "left"], "press-with-caret")]:
            with self.subTest(command=command):
                _, _, requests = self.run_cli([command, "o2", *flags, "--field-rect", "18,139,354,160",
                                              "--caret-rect", "49,149,4,22"], outcome="not_dispatched")
                self.assertEqual(len(requests), 1)
                self.assertEqual(requests[0]["op"], operation)
                self.assertEqual(requests[0]["reference"], "o2")
                self.assertEqual(requests[0]["caretRect"], "49,149,4,22")
                if command == "type":
                    self.assertEqual(requests[0]["textMethod"], "paste")

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
