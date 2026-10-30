import os
from pathlib import Path

import pytest

# Never order a real window on a developer's active desktop.
os.environ["QT_QPA_PLATFORM"] = "offscreen"
pytest.importorskip("PySide6")

from PySide6.QtWidgets import QApplication  # noqa: E402

from auraflow.gui import MainWindow  # noqa: E402
from auraflow.service import Client  # noqa: E402


@pytest.fixture(scope="module")
def application():
    return QApplication.instance() or QApplication(["auraflow-test"])


@pytest.fixture
def window(application, paths, monkeypatch):
    monkeypatch.setattr(MainWindow, "_poll", lambda _self: None)
    result = MainWindow(paths)
    result.timer.stop()
    yield result
    result.quitting = True
    result.tray.hide()
    result.close()
    result.deleteLater()
    application.processEvents()


def test_local_preview_does_not_contact_wallpaper_service(window, monkeypatch):
    def unexpected(*_, **__):
        pytest.fail("Preview must not contact the wallpaper service")

    monkeypatch.setattr(Client, "request", unexpected)
    image = Path(__file__).parents[1] / "src/auraflow/assets/icon.png"
    window._select_file(str(image))
    assert window.selected == image.resolve()
    assert window.library.count() == 1
    assert not window.preview.original.isNull()
    assert window.start_button.isEnabled()
    assert window.store.load().restore is None


@pytest.mark.parametrize("paused", [False, True])
def test_gui_autostart_checkbox_never_sends_playback_commands(window, monkeypatch, paused, media):
    def unexpected(*_, **__):
        pytest.fail("Launch at login must not contact the wallpaper service")

    monkeypatch.setattr(Client, "request", unexpected)
    window.store.update(restore=str(media))
    status = {
        "running": True,
        "paused": paused,
        "media": str(media),
        "backend": "x11",
        "scale": "fill",
        "speed": 1.0,
    }
    window._apply_status(status)
    before = window.paths.settings.read_bytes()
    for enabled in (True, False, True):
        window.autostart.setChecked(enabled)
        assert window.desktop.autostart_enabled() is enabled
        assert window.playback == status
        assert window.paths.settings.read_bytes() == before
