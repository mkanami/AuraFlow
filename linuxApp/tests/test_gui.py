import os
import sys
import time
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
    for dialog in (result.catalog_dialog, result.terminal_dialog):
        if dialog:
            dialog.close()
            if hasattr(dialog, "pool"):
                dialog.pool.waitForDone(3000)
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


def wait_until(application, predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while not predicate() and time.monotonic() < deadline:
        application.processEvents()
        time.sleep(0.01)
    application.processEvents()
    assert predicate()


def test_catalog_download_selects_media_without_touching_active_playback(
    window,
    application,
    monkeypatch,
    media,
):
    from auraflow.catalog import Catalog, CatalogPage, Wallpaper

    image = Path(__file__).parents[1] / "src/auraflow/assets/icon.png"
    item = Wallpaper("motionbgs", "Fixture wallpaper", "https://motionbgs.com/fixture")
    monkeypatch.setattr(Catalog, "page", lambda *_: CatalogPage([item], False))
    monkeypatch.setattr(Catalog, "download", lambda *_args, **_kwargs: image)

    def unexpected(*_, **__):
        pytest.fail("Catalog operations must not contact the wallpaper service")

    monkeypatch.setattr(Client, "request", unexpected)
    status = {
        "running": True,
        "paused": True,
        "media": str(media),
        "backend": "x11",
        "scale": "fit",
        "speed": 1.0,
    }
    window._apply_status(status)
    window.store.update(restore=str(media))
    window._open_catalog()
    catalog = window.catalog_dialog
    wait_until(application, lambda: catalog.list.count() == 1)
    catalog.list.setCurrentRow(0)
    catalog.download_button.click()
    wait_until(application, lambda: not catalog.transferring)
    assert window.selected == image.resolve()
    assert window.playback == status
    assert window.store.load().restore == str(media)


def test_terminal_dialog_previews_real_pty_without_changing_active_wallpaper(
    window,
    application,
    monkeypatch,
    media,
):
    import shlex

    def unexpected(*_, **__):
        pytest.fail("Terminal preview must not contact the wallpaper service")

    monkeypatch.setattr(Client, "request", unexpected)
    window.store.update(restore=str(media))
    window._open_terminal()
    dialog = window.terminal_dialog
    dialog.command.setText(shlex.join([sys.executable, "-u", "-c", 'print("Preview only")']))
    dialog.start_preview()
    producer = dialog.producer
    wait_until(application, lambda: producer.latest_frame is not None)
    dialog._frame()
    assert not dialog.preview.pixmap().isNull()
    assert window.store.load().restore == str(media)
    dialog.select_wallpaper()
    assert window.terminal_config.argv[0] == sys.executable
    assert window.start_button.isEnabled()
    assert window.store.load().restore == str(media)
    dialog.hide()
    assert dialog.producer is None and not producer.thread.is_alive()


@pytest.mark.parametrize("paused", [False, True])
def test_terminal_gui_login_toggle_preserves_command_and_playback(window, monkeypatch, paused):
    from auraflow.terminal_config import TerminalConfig

    config = TerminalConfig.from_preset("cmatrix")
    window.store.update(
        selected_kind="terminal",
        terminal=config.to_dict(),
        restore_kind="terminal",
        restore_terminal=config.to_dict(),
    )
    window._terminal_selected(config)
    status = {
        "running": True,
        "paused": paused,
        "media": "cmatrix",
        "label": "cmatrix -u 4",
        "backend": "x11",
        "scale": "fill",
        "speed": 1.0,
        "kind": "terminal",
    }
    window._apply_status(status)
    monkeypatch.setattr(Client, "request", lambda *_a, **_k: pytest.fail("No playback commands"))
    before = window.paths.settings.read_bytes()
    for enabled in (True, False):
        window.autostart.setChecked(enabled)
        assert window.playback == status
        assert window.paths.settings.read_bytes() == before


def test_failed_catalog_transfer_displays_error_without_selecting_a_file(
    window,
    application,
    monkeypatch,
):
    from auraflow import AuraFlowError
    from auraflow.catalog import Catalog, CatalogPage, Wallpaper

    item = Wallpaper(
        "moewalls", "Unavailable", "https://moewalls.com/anime/unavailable-live-wallpaper/"
    )
    monkeypatch.setattr(Catalog, "page", lambda *_: CatalogPage([item], False))

    def failed(*_args, **_kwargs):
        raise AuraFlowError("Provider unavailable")

    monkeypatch.setattr(Catalog, "download", failed)
    window._open_catalog()
    catalog = window.catalog_dialog
    wait_until(application, lambda: catalog.list.count() == 1)
    catalog.list.setCurrentRow(0)
    catalog.transfer(False)
    wait_until(application, lambda: not catalog.transferring)
    assert "Provider unavailable" in catalog.message.text()
    assert window.selected is None
