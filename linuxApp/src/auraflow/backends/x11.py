from __future__ import annotations

import os
from pathlib import Path
from typing import BinaryIO

from .. import AuraFlowError
from ..player import Player, WallpaperSession, player_options
from ..settings import Settings
from ..streams import VideoFormat


class DesktopSurfaces:
    """Own desktop windows only. Never write a root pixmap or native wallpaper settings."""

    def __init__(self):
        from Xlib import X, Xatom, display
        from Xlib.ext import shape

        self.display = display.Display()
        self.windows = []
        try:
            if not self.display.has_extension("SHAPE"):
                raise AuraFlowError(
                    "The X server needs the SHAPE extension for click-through wallpapers."
                )
            for screen_index in range(self.display.screen_count()):
                screen = self.display.screen(screen_index)
                root = screen.root
                rectangles = []
                if self.display.has_extension("RANDR"):
                    try:
                        monitors = root.xrandr_get_monitors(True).monitors
                        rectangles = [
                            (m.x, m.y, m.width_in_pixels, m.height_in_pixels) for m in monitors
                        ]
                    except Exception:
                        # RandR before 1.5 has no get_monitors; use the live root geometry.
                        rectangles = []
                if not rectangles:
                    geometry = root.get_geometry()
                    rectangles = [(0, 0, geometry.width, geometry.height)]
                for x, y, width, height in dict.fromkeys(rectangles):
                    if width <= 0 or height <= 0:
                        continue
                    window = root.create_window(
                        x,
                        y,
                        width,
                        height,
                        0,
                        screen.root_depth,
                        X.InputOutput,
                        X.CopyFromParent,
                        background_pixel=screen.black_pixel,
                        event_mask=X.StructureNotifyMask,
                    )
                    self.windows.append(window)
                    atom = self.display.intern_atom
                    window.set_wm_name("AuraFlow Wallpaper")
                    window.set_wm_class("auraflow-wallpaper", "AuraFlow")
                    window.set_wm_hints(input=0)
                    window.change_property(
                        atom("_NET_WM_WINDOW_TYPE"),
                        Xatom.ATOM,
                        32,
                        [atom("_NET_WM_WINDOW_TYPE_DESKTOP")],
                    )
                    window.change_property(
                        atom("_NET_WM_STATE"),
                        Xatom.ATOM,
                        32,
                        [
                            atom(name)
                            for name in (
                                "_NET_WM_STATE_BELOW",
                                "_NET_WM_STATE_STICKY",
                                "_NET_WM_STATE_SKIP_TASKBAR",
                                "_NET_WM_STATE_SKIP_PAGER",
                            )
                        ],
                    )
                    window.change_property(
                        atom("_NET_WM_DESKTOP"), Xatom.CARDINAL, 32, [0xFFFFFFFF]
                    )
                    window.change_property(atom("_NET_WM_PID"), Xatom.CARDINAL, 32, [os.getpid()])
                    window.change_property(
                        atom("_NET_WM_BYPASS_COMPOSITOR"), Xatom.CARDINAL, 32, [0]
                    )
                    window.shape_rectangles(shape.SO.Set, shape.SK.Input, X.Unsorted, 0, 0, [])
                    window.map()
            if not self.windows:
                raise AuraFlowError("No connected X11 displays were found.")
            self.display.sync()
        except BaseException:
            self.close()
            raise

    def close(self) -> None:
        for window in self.windows:
            window.destroy()
        self.windows.clear()
        self.display.flush()
        self.display.close()


def command(
    media: Path, settings: Settings, ipc_fd: int, window_id: int, raw: VideoFormat | None = None
) -> list[str]:
    return [
        "mpv",
        *player_options(settings, ipc_fd),
        f"--wid={window_id}",
        "--vo=gpu,x11",
        "--gpu-context=x11egl",
        "--force-window=yes",
        "--auto-window-resize=no",
        "--border=no",
        *(raw.options() if raw else []),
        "--",
        str(media),
    ]


def start(media: Path, settings: Settings, log: BinaryIO, source=None) -> WallpaperSession:
    surfaces = DesktopSurfaces()
    players: list[Player] = []
    try:
        for window in surfaces.windows:
            reader = source.attach() if source else None
            try:
                players.append(
                    Player(
                        lambda fd, wid=window.id: command(
                            media, settings, fd, wid, source.format if source else None
                        ),
                        log,
                        stdin=reader,
                    )
                )
            finally:
                if reader:
                    reader.close()
    except BaseException:
        for player in players:
            player.close()
        surfaces.close()
        raise
    return WallpaperSession("x11", media, players, surfaces.close)
