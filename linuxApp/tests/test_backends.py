from pathlib import Path

import pytest

from auraflow import AuraFlowError
from auraflow.backends import detect_backend
from auraflow.backends.wayland import command as wayland_command
from auraflow.backends.x11 import command as x11_command
from auraflow.player import scale_properties
from auraflow.settings import Settings


@pytest.fixture
def linux_session(monkeypatch):
    monkeypatch.setattr("sys.platform", "linux")
    monkeypatch.setenv("DISPLAY", ":test")
    monkeypatch.setenv("XDG_SESSION_TYPE", "x11")
    monkeypatch.delenv("WAYLAND_DISPLAY", raising=False)
    monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
    monkeypatch.setattr("auraflow.backends.shutil.which", lambda name: "/bin/" + name)


def test_x11_detection(linux_session):
    assert detect_backend() == "x11"


def test_wayland_takes_precedence_over_xwayland(linux_session, monkeypatch):
    monkeypatch.setenv("WAYLAND_DISPLAY", "wayland-test")
    monkeypatch.setenv("XDG_CURRENT_DESKTOP", "sway")
    assert detect_backend() == "wayland"
    with pytest.raises(AuraFlowError, match="Xwayland"):
        detect_backend("x11")


def test_gnome_wayland_fails_before_creating_wallpaper_windows(linux_session, monkeypatch):
    monkeypatch.setenv("WAYLAND_DISPLAY", "wayland-test")
    monkeypatch.setenv("XDG_CURRENT_DESKTOP", "ubuntu:GNOME")
    with pytest.raises(AuraFlowError, match="Shell extension"):
        detect_backend()


def test_missing_binary_and_headless_session_have_clear_errors(linux_session, monkeypatch):
    monkeypatch.setattr("auraflow.backends.shutil.which", lambda _: None)
    with pytest.raises(AuraFlowError, match="Install mpv"):
        detect_backend()
    monkeypatch.delenv("DISPLAY")
    with pytest.raises(AuraFlowError, match="No X11 display"):
        detect_backend()


def test_commands_use_exact_local_path_disable_audio_and_do_not_inhibit_saver(media):
    for arguments in (
        x11_command(media, Settings(), 14, 1234),
        wayland_command(media, Settings(), Path("/run/user/test/auraflow/mp.sock")),
    ):
        assert arguments[-1] == str(media)
        assert arguments.count(str(media)) == 1
        options = " ".join(arguments)
        assert "--audio=no" in options
        assert "--stop-screensaver=no" in options
        assert "--load-scripts=no" in options
        assert "--input-ipc-" in options
    assert x11_command(media, Settings(), 14, 1234)[-2] == "--"
    assert wayland_command(media, Settings(), Path("/run/test.sock"))[-2] == "ALL"
    assert not Path("nope").exists()


def test_shared_scale_mapping():
    assert scale_properties("fill") == {"keepaspect": True, "panscan": 1.0}
    assert scale_properties("fit") == {"keepaspect": True, "panscan": 0.0}
    assert scale_properties("stretch") == {"keepaspect": False, "panscan": 0.0}
