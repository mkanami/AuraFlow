import os
from pathlib import Path

import pytest

from auraflow.backends.x11 import DesktopSurfaces, start
from auraflow.settings import Settings

pytestmark = [
    pytest.mark.x11,
    pytest.mark.skipif(
        os.environ.get("AURAFLOW_TEST_X11") != "1",
        reason="Requires an explicitly isolated Xvfb session",
    ),
]


def test_native_surfaces_are_desktop_click_through_and_not_focusable():
    from Xlib import Xatom
    from Xlib.ext import shape

    surfaces = DesktopSurfaces()
    try:
        atom = surfaces.display.intern_atom
        assert surfaces.windows
        for window in surfaces.windows:
            prop = window.get_full_property(atom("_NET_WM_WINDOW_TYPE"), Xatom.ATOM)
            assert list(prop.value) == [atom("_NET_WM_WINDOW_TYPE_DESKTOP")]
            assert window.get_wm_hints().input == 0
            assert window.shape_get_rectangles(shape.SK.Input).rectangles == []
            assert (
                window.get_full_property(atom("_NET_WM_DESKTOP"), Xatom.CARDINAL).value[0]
                == 0xFFFFFFFF
            )
    finally:
        surfaces.close()


def test_real_x11_playback_pause_scaling_and_cleanup_preserve_root_wallpaper(tmp_path):
    from Xlib import X, display

    connection = display.Display()
    root = connection.screen().root
    atom = connection.intern_atom("_XROOTPMAP_ID")
    before = root.get_full_property(atom, X.AnyPropertyType)
    before = None if before is None else (before.property_type, before.format, list(before.value))
    image = Path(__file__).parents[1] / "src/auraflow/assets/icon.png"
    with (tmp_path / "player.log").open("ab") as log:
        session = start(image, Settings(), log)
        try:
            session.wait_ready()
            assert session.alive()
            session.set_properties({"pause": True, "keepaspect": False, "panscan": 0, "speed": 0.5})
            for player in session.players:
                assert player.command("get_property", "pause") is True
                assert player.command("get_property", "video-params")["w"] == 1024
        except Exception:
            print((tmp_path / "player.log").read_text())
            raise
        finally:
            session.close()
        assert not session.alive()
    after = root.get_full_property(atom, X.AnyPropertyType)
    after = None if after is None else (after.property_type, after.format, list(after.value))
    assert before == after
    connection.close()


def test_real_x11_terminal_uses_shared_native_surfaces_and_cleans_up(tmp_path):
    import sys

    from auraflow.terminal import TerminalSession
    from auraflow.terminal_config import TerminalConfig

    config = TerminalConfig(
        argv=(sys.executable, "-u", "-c", 'print("X11 terminal wallpaper")'), columns=40, rows=10
    )
    with (tmp_path / "terminal.log").open("ab") as log:
        session = TerminalSession(config, Settings(backend="x11"), log)
        try:
            session.wait_ready()
            assert session.alive()
            session.set_properties({"pause": True})
            assert session.producer.paused
            session.set_properties({"keepaspect": True, "panscan": 0.0})
            for player in session.players:
                params = player.command("get_property", "video-params")
                assert params["w"] == session.producer.format.width
            session.set_properties({"pause": False})
        finally:
            session.close()
        assert not session.producer.thread.is_alive()
        assert not session.alive()
