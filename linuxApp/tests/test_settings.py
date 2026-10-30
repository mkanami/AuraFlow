import json
import os
from dataclasses import replace
from pathlib import Path

import pytest

from auraflow import AuraFlowError
from auraflow.paths import AppPaths, private_directory
from auraflow.settings import validate_media, validate_speed


def test_selection_is_a_preview_and_atomic_store_keeps_active_choice(store, media, tmp_path):
    installed = tmp_path / "installed.png"
    installed.write_bytes(b"image")
    store.update(restore=str(installed), scale="fit", speed=0.5)
    store.select(media)
    store.select(media)
    assert store.load().selected == str(media)
    assert store.load().restore == str(installed)
    assert store.load().recent == [str(media)]
    store.update(speed=1.5)
    assert store.load().scale == "fit"
    assert store.load().selected == str(media)
    assert store.paths.settings.stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize("contents", ["broken json", '{"version": 99}', '{"recent": [42]}'])
def test_invalid_settings_are_preserved(store, contents):
    store.paths.config.mkdir(parents=True)
    store.paths.settings.write_text(contents)
    with pytest.raises(AuraFlowError):
        store.update(scale="fit")
    assert store.paths.settings.read_text() == contents


@pytest.mark.parametrize("speed", [True, "fast", None, float("nan"), float("inf"), 0, 4.01])
def test_speed_is_validated(speed):
    with pytest.raises(AuraFlowError):
        validate_speed(speed)


def test_media_validation_rejects_playlists_urls_and_directories(tmp_path):
    for name in ("script.sh", "playlist.m3u"):
        path = tmp_path / name
        path.touch()
        with pytest.raises(AuraFlowError):
            validate_media(path)
    for value in (
        str(tmp_path),
        "https://example.com/wallpaper.mp4",
        str(tmp_path / "missing.mp4"),
    ):
        with pytest.raises(AuraFlowError):
            validate_media(value)


def test_xdg_relative_variables_are_ignored_and_sessions_are_separate(tmp_path):
    env = {"HOME": str(tmp_path), "XDG_CONFIG_HOME": "relative", "DISPLAY": ":1"}
    x11 = AppPaths.discover(env)
    wayland = AppPaths.discover({**env, "WAYLAND_DISPLAY": "wayland-1"})
    assert x11.config == tmp_path / ".config/auraflow"
    assert x11.runtime != wayland.runtime
    assert x11.settings == wayland.settings
    assert x11.runtime == AppPaths.discover({**env, "XDG_SESSION_ID": "terminal-login"}).runtime


def test_private_runtime_rejects_symlink(paths, tmp_path):
    target = tmp_path / "target"
    target.mkdir()
    link = tmp_path / "runtime-link"
    link.symlink_to(target, target_is_directory=True)
    with pytest.raises(AuraFlowError):
        private_directory(link)
    assert target.stat().st_mode & 0o777 != 0o700


def test_long_runtime_path_has_actionable_error(paths):
    with pytest.raises(AuraFlowError, match="XDG_RUNTIME_DIR"):
        _ = replace(paths, runtime=Path("/" + "x" * 110)).socket


def test_no_native_wallpaper_descriptor_is_touched(store, media, tmp_path):
    descriptor = tmp_path / "native-wallpaper.json"
    original = json.dumps({"dark": "user:///dark", "light": "user:///light", "appearance": "auto"})
    descriptor.write_text(original)
    store.select(media)
    store.update(scale="stretch", restore=str(media))
    store.update(restore=None)
    assert descriptor.read_text() == original
    assert not (tmp_path / "nope").exists()
    assert os.path.isabs(store.load().selected)
