"""Controlled preview lifecycle peers; only used with isolated test directories."""
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import socket
import sys


def await_release():
    if not select.select([sys.stdin], [], [], 30)[0]:
        raise TimeoutError("Test did not release the fixture")
    if sys.stdin.readline().strip() != "exit":
        raise RuntimeError("Expected an explicit exit command")


def run(mode, directory):
    if mode == "unresponsive-owner":
        with (directory / "device-service.lock").open("w") as owner:
            fcntl.flock(owner, fcntl.LOCK_EX | fcntl.LOCK_NB)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            (directory / "ready").touch()
            await_release()
    elif mode == "delayed-stop":
        # Deliberately hold no service lock: only the stopping CLI's startup lock
        # can prevent replacement between this acknowledgment and process exit.
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(directory / "ipc.sock"))
            server.listen()
            server.settimeout(10)
            (directory / "ready").touch()
            connection, _ = server.accept()
            with connection:
                connection.settimeout(3)
                with connection.makefile("rb") as stream:
                    request = json.loads(stream.readline(65536))
                assert request["op"] == "stop" and request["version"] == 1
                assert request["authorization"] == (directory / "authorization").read_text()
                response = {"id": request["id"], "ok": True,
                            "pid": os.getpid(), "state": "stop_requested"}
                connection.sendall(json.dumps(response).encode() + b"\n")
        (directory / "acknowledged").touch()
        await_release()
    else:
        raise ValueError(f"Unknown fixture mode: {mode}")


if __name__ == "__main__":
    run(sys.argv[1], Path(sys.argv[2]))
