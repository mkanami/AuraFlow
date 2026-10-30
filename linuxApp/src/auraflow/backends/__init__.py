from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path
from typing import BinaryIO

from .. import AuraFlowError
from ..player import WallpaperSession
from ..settings import BACKENDS, Settings


def detect_backend(requested: str = "auto") -> str:
    if requested not in BACKENDS:
        raise AuraFlowError(f"Unknown backend: {requested}")
    if sys.platform != "linux":
        raise AuraFlowError("Desktop playback is available on Linux.")
    wayland = bool(os.environ.get("WAYLAND_DISPLAY")) or (
        os.environ.get("XDG_SESSION_TYPE") == "wayland"
    )
    backend = ("wayland" if wayland else "x11") if requested == "auto" else requested
    if backend == "x11":
        if wayland:
            raise AuraFlowError(
                "Choose an X11 login session for X11 playback; Xwayland is unsupported."
            )
        if not os.environ.get("DISPLAY"):
            raise AuraFlowError("No X11 display. Run AuraFlow inside your graphical login session.")
        if not shutil.which("mpv"):
            raise AuraFlowError("Install mpv using your distribution's package manager.")
    else:
        if not os.environ.get("WAYLAND_DISPLAY"):
            raise AuraFlowError(
                "No Wayland display. Run AuraFlow inside your graphical login session."
            )
        if "gnome" in os.environ.get("XDG_CURRENT_DESKTOP", "").lower():
            raise AuraFlowError(
                "GNOME Wayland needs a Shell extension, which this port does not include yet. "
                "Use a supported X11 session or a layer-shell compositor such as Sway/Hyprland."
            )
        if not shutil.which("mpvpaper"):
            raise AuraFlowError(
                "Install mpvpaper for Wayland wallpaper playback (layer-shell required)."
            )
    return backend


def start_session(media: Path, settings: Settings, log: BinaryIO) -> WallpaperSession:
    backend = detect_backend(settings.backend)
    if backend == "x11":
        from .x11 import start
    else:
        from .wayland import start
    return start(media, settings, log)


def start_stream(source, settings: Settings, log: BinaryIO) -> WallpaperSession:
    backend = detect_backend(settings.backend)
    if backend == "x11":
        from .x11 import start
    else:
        from .wayland import start
    return start(Path("-"), settings, log, source=source)


def diagnostics(requested: str = "auto") -> dict[str, object]:
    result: dict[str, object] = {
        "platform": sys.platform,
        "session": os.environ.get("XDG_SESSION_TYPE", "unknown"),
        "desktop": os.environ.get("XDG_CURRENT_DESKTOP", "unknown"),
        "mpv": shutil.which("mpv"),
        "mpvpaper": shutil.which("mpvpaper"),
        "lock_screen": "Not implemented; the system locker is left in control.",
    }
    try:
        result.update(backend=detect_backend(requested), available=True)
    except AuraFlowError as exc:
        result.update(available=False, error=str(exc))
    return result
