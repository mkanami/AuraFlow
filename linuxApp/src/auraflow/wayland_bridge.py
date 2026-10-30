"""Supervise mpvpaper and forward its IPC until the owning service disconnects."""

from __future__ import annotations

import json
import os
import secrets
import select
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

from . import AuraFlowError
from .backends.wayland import command
from .paths import AppPaths, private_directory
from .settings import Settings
from .streams import VideoFormat


def run(
    parent: socket.socket, media: Path, settings: Settings, raw: VideoFormat | None = None
) -> None:
    runtime = private_directory(AppPaths.discover().runtime)
    endpoint = runtime / f"mp-{secrets.token_hex(3)}.sock"
    if len(os.fsencode(endpoint)) > 107:
        raise AuraFlowError("Wayland runtime path is too long; use a shorter XDG_RUNTIME_DIR.")
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    # Raw terminal frames arrive on stdin from the owning producer.
    process = subprocess.Popen(
        command(media, settings, endpoint, raw), stdin=None if raw else subprocess.DEVNULL
    )
    try:
        with socket.socket(socket.AF_UNIX) as child:
            child.settimeout(1)
            parent.settimeout(1)
            deadline = time.monotonic() + 10
            while not stopping:
                if process.poll() is not None:
                    raise AuraFlowError("mpvpaper exited before its IPC connection was ready.")
                if select.select([parent], [], [], 0)[0] and not parent.recv(1, socket.MSG_PEEK):
                    return
                try:
                    child.connect(str(endpoint))
                    break
                except (FileNotFoundError, ConnectionRefusedError):
                    if time.monotonic() >= deadline:
                        raise AuraFlowError("mpvpaper did not create its IPC socket.") from None
                    time.sleep(0.05)
            while not stopping and process.poll() is None:
                for source in select.select([parent, child], [], [], 0.1)[0]:
                    data = source.recv(65536)
                    if not data:
                        return
                    (child if source is parent else parent).sendall(data)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)
        endpoint.unlink(missing_ok=True)


def main() -> int:
    try:
        with socket.socket(fileno=int(sys.argv[1])) as parent:
            raw = VideoFormat(**json.loads(sys.argv[4])) if len(sys.argv) > 4 else None
            run(parent, Path(sys.argv[3]), Settings.parse(json.loads(sys.argv[2])), raw)
        return 0
    except (AuraFlowError, OSError) as exc:
        print(f"AuraFlow Wayland: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
