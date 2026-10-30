from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import BinaryIO

from .. import AuraFlowError
from ..player import Player, WallpaperSession, player_options
from ..settings import Settings


def command(media: Path, settings: Settings, ipc_path: Path) -> list[str]:
    # ALL discovers outputs through Wayland; no saved connector names or display IDs.
    # mpvpaper loads options before AND after mpv initialization. Reapplying
    # input-ipc-client would create competing readers on the same inherited FD.
    # Instead use a private server socket and one supervised bridge connection.
    path = str(ipc_path)
    if any(ord(c) < 32 or c in '\\"' for c in path):
        raise AuraFlowError("Wayland runtime paths cannot contain quotes or backslashes.")
    options = " ".join(
        [
            *player_options(settings, None),
            f'--input-ipc-server="{path}"',
        ]
    )
    return ["mpvpaper", "-o", options, "ALL", str(media)]


def bridge_command(media: Path, settings: Settings, ipc_fd: int) -> list[str]:
    return [
        sys.executable,
        "-m",
        "auraflow.wayland_bridge",
        str(ipc_fd),
        json.dumps({"scale": settings.scale, "speed": settings.speed}),
        str(media),
    ]


def start(media: Path, settings: Settings, log: BinaryIO) -> WallpaperSession:
    player = Player(lambda fd: bridge_command(media, settings, fd), log)
    return WallpaperSession("wayland", media, [player], lambda: None)
