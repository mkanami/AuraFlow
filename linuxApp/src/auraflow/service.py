from __future__ import annotations

import errno
import fcntl
import json
import logging
import select
import signal
import socket
import subprocess
import sys
import time

from . import AuraFlowError
from .paths import AppPaths, private_directory
from .runtime import Controller, idle_status
from .settings import SettingsStore

MAX_MESSAGE = 64 * 1024


def read_message(connection: socket.socket) -> dict[str, object]:
    buffer = bytearray()
    while b"\n" not in buffer:
        chunk = connection.recv(4096)
        if not chunk:
            raise AuraFlowError("Connection closed before a complete message arrived.")
        buffer.extend(chunk)
        if len(buffer) > MAX_MESSAGE:
            raise AuraFlowError("Runtime message is too large.")
    try:
        result = json.loads(buffer.partition(b"\n")[0])
    except (ValueError, UnicodeError) as exc:
        raise AuraFlowError("Invalid JSON runtime message.") from exc
    if not isinstance(result, dict):
        raise AuraFlowError("Runtime message must be an object.")
    return result


def serve(paths: AppPaths) -> int:
    private_directory(paths.runtime)
    private_directory(paths.state)
    with (paths.runtime / "daemon.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        with paths.log.open("ab", buffering=0) as log, socket.socket(socket.AF_UNIX) as server:
            paths.log.chmod(0o600)
            controller = Controller(SettingsStore(paths), log)

            def stop(_signum, _frame):
                controller.shutdown_requested = True

            signal.signal(signal.SIGTERM, stop)
            signal.signal(signal.SIGINT, stop)
            paths.socket.unlink(missing_ok=True)
            try:
                server.bind(str(paths.socket))
                paths.socket.chmod(0o600)
                server.listen(8)
                while not controller.shutdown_requested:
                    if select.select([server], [], [], 0.25)[0]:
                        connection, _ = server.accept()
                        with connection:
                            connection.settimeout(1)
                            try:
                                data = controller.execute(read_message(connection))
                                reply = {"ok": True, "data": data}
                            except Exception as exc:
                                logging.exception("Runtime command failed")
                                reply = {"ok": False, "error": str(exc)}
                            try:
                                connection.sendall(json.dumps(reply).encode() + b"\n")
                            except OSError:
                                pass
                    controller.check_health()
            finally:
                controller.close()
                paths.socket.unlink(missing_ok=True)
    return 0


class Client:
    def __init__(self, paths: AppPaths):
        self.paths = paths
        self.store = SettingsStore(paths)

    def _request(self, request: dict[str, object]) -> dict[str, object]:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(30)
            connection.connect(str(self.paths.socket))
            connection.sendall(json.dumps(request).encode() + b"\n")
            reply = read_message(connection)
        if not reply.get("ok"):
            raise AuraFlowError(str(reply.get("error", "Runtime command failed.")))
        data = reply.get("data")
        if not isinstance(data, dict):
            raise AuraFlowError("Invalid runtime response.")
        return data

    def request(self, action: str, **values: object) -> dict[str, object]:
        request = {"action": action, **values}
        try:
            return self._request(request)
        except OSError as exc:
            if exc.errno not in (errno.ENOENT, errno.ECONNREFUSED):
                raise AuraFlowError(f"Cannot contact AuraFlow: {exc}") from exc
        if action == "start":
            self._launch()
            return self._request(request)
        # No process is needed to change future preferences or remove a saved wallpaper.
        if action == "remove":
            self.store.update(restore=None)
        elif action in ("scale", "speed"):
            self.store.update(**{action: values.get("value")})
        elif action not in ("pause", "resume", "shutdown", "status"):
            raise AuraFlowError(f"Unknown runtime action: {action}")
        return idle_status(self.store)

    def _launch(self) -> None:
        private_directory(self.paths.runtime)
        private_directory(self.paths.state)
        if self.paths.log.exists() and self.paths.log.stat().st_size > 2 * 1024 * 1024:
            self.paths.log.replace(self.paths.log.with_suffix(".log.1"))
        with self.paths.log.open("ab") as log:
            self.paths.log.chmod(0o600)
            process = subprocess.Popen(
                [sys.executable, "-m", "auraflow", "serve"],
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=log,
                start_new_session=True,
            )
        deadline = time.monotonic() + 6
        while time.monotonic() < deadline:
            try:
                self._request({"action": "status"})
                return
            except OSError as exc:
                if exc.errno not in (errno.ENOENT, errno.ECONNREFUSED):
                    raise
            if process.poll() not in (None, 0):
                break
            time.sleep(0.05)
        raise AuraFlowError(f"AuraFlow service could not start. Check {self.paths.log}")
