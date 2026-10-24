"""Setup presentation/validation contracts, using an isolated CLI without Runner resources."""
import errno
import json
import os
from pathlib import Path
import pty
import shutil
import subprocess
import tempfile
import unittest

CLI = Path(os.environ.get("IPHONE_USE_TEST_CLI", Path(__file__).resolve().parents[2] / ".build/debug/iphone-use"))


@unittest.skipUnless(CLI.is_file(), "Build the CLI before integration tests")
class SetupCLITests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="iu-setup-", dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cli = self.root / "bin/iphone-use"
        self.cli.parent.mkdir()
        shutil.copy2(CLI, self.cli)
        self.env = {**os.environ, "IPHONE_USE_CONFIG_DIR": str(self.root / "config"),
                    "IPHONE_USE_STATE_DIR": str(self.root / "state")}

    def call(self, *arguments, terminal=False):
        command = [str(self.cli), "setup", "--device", "fixture-not-a-device", *arguments]
        if terminal:
            master, slave = pty.openpty()
            try:
                process = subprocess.Popen(command, env=self.env, stdout=slave, stderr=subprocess.PIPE)
                # Keep the slave open until output is drained; macOS can discard
                # unread terminal output when the final slave descriptor closes.
                _, errors = process.communicate(timeout=10)
                os.set_blocking(master, False)
                chunks = []
                while True:
                    try:
                        data = os.read(master, 4096)
                    except BlockingIOError:
                        break
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not data:
                        break
                    chunks.append(data)
                output = b"".join(chunks).decode()
                code = process.returncode
            finally:
                os.close(master)
                if slave is not None:
                    os.close(slave)
        else:
            result = subprocess.run(command, env=self.env, capture_output=True, timeout=10)
            code, output, errors = result.returncode, result.stdout.decode(), result.stderr
        self.assertNotEqual(code, 0)
        self.assertTrue(output, (code, errors))
        self.assertFalse((self.root / "state").exists(), "No device host may start during argument/package checks")
        self.assertFalse((self.root / "config").exists(), "Never write user preferences")
        return [json.loads(line) for line in output.splitlines()]

    def test_pipe_defaults_to_single_json_and_progress_is_opt_in(self):
        replies = self.call()
        self.assertEqual(len(replies), 1)
        self.assertEqual(replies[-1]["error"]["code"], "runner_package_missing")
        for flags in [("--progress",), ("--progress", "--preview"), ("--progress", "--no-preview")]:
            replies = self.call(*flags)
            self.assertEqual(replies[0]["event"], "setup_progress")
            self.assertEqual(replies[0]["phase"], "checking")
            self.assertEqual(replies[-1]["error"]["code"], "runner_package_missing")

    def test_interactive_defaults_enable_progress_and_allow_explicit_opt_out(self):
        replies = self.call("--port", "9876", terminal=True)
        self.assertEqual(replies[0]["event"], "setup_progress")
        self.assertEqual(replies[-1]["error"]["code"], "runner_package_missing")
        self.assertEqual(len(self.call("--no-progress", terminal=True)), 1)
        self.assertEqual(self.call("--no-preview", terminal=True)[0]["event"], "setup_progress")

    def test_invalid_combinations_fail_before_setup_or_device_access(self):
        for flags, message in [
            (("--preview",), "requires --progress"),
            (("--preview", "--no-progress"), "requires --progress"),
            (("--port", "9876"), "requires --preview"),
            (("--progress", "--no-preview", "--port", "9876"), "requires --preview"),
        ]:
            replies = self.call(*flags)
            self.assertEqual(len(replies), 1)
            self.assertIn(message, replies[0]["error"]["message"])
        for port in ("0", "1023", "65536"):
            replies = self.call("--progress", "--preview", "--port", port)
            self.assertEqual(len(replies), 1)
            self.assertEqual(replies[0]["error"]["code"], "invalid_preview_port")


if __name__ == "__main__":
    unittest.main()
