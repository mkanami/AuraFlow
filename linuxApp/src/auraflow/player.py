from __future__ import annotations

import json
import logging
import select
import socket
import subprocess
import time
from collections.abc import Callable
from pathlib import Path
from typing import BinaryIO

from . import AuraFlowError
from .settings import Settings


def scale_properties(scale: str) -> dict[str, bool | float]:
    return {"keepaspect": scale != "stretch", "panscan": 1.0 if scale == "fill" else 0.0}


def player_options(settings: Settings, ipc_fd: int | None) -> list[str]:
    scale = scale_properties(settings.scale)
    return [
        "--config=no",
        "--load-scripts=no",
        "--ytdl=no",
        "--audio=no",
        "--sid=no",
        "--loop-file=inf",
        "--image-display-duration=inf",
        "--keep-open=yes",
        "--hwdec=auto-safe",
        "--terminal=no",
        "--osc=no",
        "--osd-level=0",
        "--input-default-bindings=no",
        "--input-terminal=no",
        "--input-vo-keyboard=no",
        "--input-cursor=no",
        "--input-media-keys=no",
        "--stop-screensaver=no",
        "--cursor-autohide=no",
        *([f"--input-ipc-client=fd://{ipc_fd}"] if ipc_fd is not None else []),
        f"--speed={settings.speed}",
        f"--keepaspect={'yes' if scale['keepaspect'] else 'no'}",
        f"--panscan={scale['panscan']}",
    ]


class Player:
    """One owned player with a private inherited socket; closing it ends playback."""

    def __init__(self, command: Callable[[int], list[str]], log: BinaryIO, stdin=None):
        self.connection, child = socket.socketpair()
        self.buffer = bytearray()
        self.request_id = 0
        self.failure: str | None = None
        try:
            self.process = subprocess.Popen(
                command(child.fileno()),
                stdin=stdin if stdin is not None else subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=log,
                pass_fds=(child.fileno(),),
            )
        except BaseException:
            self.connection.close()
            raise
        finally:
            child.close()

    def command(self, *command: object, timeout: float = 1.0) -> object:
        self.request_id += 1
        request_id = self.request_id
        deadline = time.monotonic() + timeout
        try:
            self.connection.settimeout(timeout)
            self.connection.sendall(
                json.dumps({"command": command, "request_id": request_id}).encode() + b"\n"
            )
            while time.monotonic() < deadline:
                if b"\n" not in self.buffer:
                    self.connection.settimeout(max(0.001, deadline - time.monotonic()))
                    chunk = self.connection.recv(65536)
                    if not chunk:
                        raise AuraFlowError("The wallpaper player closed its connection.")
                    self.buffer.extend(chunk)
                    if len(self.buffer) > 1024 * 1024:
                        raise AuraFlowError("Oversized response from the wallpaper player.")
                    continue
                line, _, remaining = self.buffer.partition(b"\n")
                self.buffer = bytearray(remaining)
                message = json.loads(line)
                if message.get("event") == "end-file" and message.get("reason") == "error":
                    self.failure = str(message.get("file_error", "Cannot decode this media file."))
                if message.get("request_id") == request_id:
                    if message.get("error") != "success":
                        raise AuraFlowError(str(message.get("error", "Player command failed.")))
                    return message.get("data")
        except (OSError, ValueError) as exc:
            raise AuraFlowError(f"Cannot communicate with the wallpaper player: {exc}") from exc
        raise AuraFlowError("The wallpaper player did not respond in time.")

    def wait_ready(self, deadline: float) -> None:
        error = "No video frame was decoded."
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise AuraFlowError(
                    "Wallpaper player exited. Check `auraflow doctor` and daemon.log."
                )
            try:
                params = self.command("get_property", "video-params", timeout=0.5)
                if isinstance(params, dict) and params.get("w", 0) > 0 and params.get("h", 0) > 0:
                    if self.command("get_property", "vo-configured", timeout=0.5):
                        return
            except AuraFlowError as exc:
                error = str(exc)
            if self.failure:
                raise AuraFlowError(self.failure)
            time.sleep(0.05)
        raise AuraFlowError(f"Could not start wallpaper: {error}")

    def set_property(self, name: str, value: object) -> None:
        self.command("set_property", name, value)

    def healthy(self) -> bool:
        if self.process.poll() is not None or self.failure:
            return False
        try:
            # Drain unsolicited events even when the user leaves playback alone
            # overnight. Otherwise loop events eventually fill the IPC buffers.
            while select.select([self.connection], [], [], 0)[0]:
                chunk = self.connection.recv(65536)
                if not chunk:
                    return False
                self.buffer.extend(chunk)
                if len(self.buffer) > 1024 * 1024:
                    return False
            while b"\n" in self.buffer:
                line, _, remaining = self.buffer.partition(b"\n")
                self.buffer = bytearray(remaining)
                message = json.loads(line)
                if message.get("event") == "end-file" and message.get("reason") == "error":
                    self.failure = str(message.get("file_error", "Cannot decode this media file."))
            return self.failure is None
        except (OSError, ValueError):
            return False

    def close(self) -> None:
        self.connection.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)


class WallpaperSession:
    def __init__(
        self, backend: str, media: Path, players: list[Player], cleanup: Callable[[], None]
    ):
        self.backend = backend
        self.media = media
        self.players = players
        self.cleanup = cleanup

    def wait_ready(self) -> None:
        deadline = time.monotonic() + 12
        for player in self.players:
            player.wait_ready(deadline)

    def set_properties(self, properties: dict[str, object]) -> None:
        for player in self.players:
            for key, value in properties.items():
                player.set_property(key, value)

    def alive(self) -> bool:
        return all(player.healthy() for player in self.players)

    def close(self) -> None:
        try:
            for player in self.players:
                try:
                    player.close()
                except OSError:
                    logging.exception("Could not close wallpaper player")
        finally:
            try:
                self.cleanup()
            except Exception:
                logging.exception("Could not close wallpaper surfaces")
