import shutil
import tempfile
from pathlib import Path

import pytest

from auraflow.paths import AppPaths
from auraflow.settings import SettingsStore


@pytest.fixture
def paths(tmp_path, monkeypatch):
    # Unix socket paths have a small length limit, including on macOS test hosts.
    runtime = Path(tempfile.mkdtemp(prefix="auraflow-test-", dir="/tmp"))
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "config"))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(runtime))
    try:
        yield AppPaths.discover()
    finally:
        shutil.rmtree(runtime)


@pytest.fixture
def store(paths):
    return SettingsStore(paths)


@pytest.fixture
def media(tmp_path):
    file = tmp_path / "wallpaper with spaces;$(touch nope).mp4"
    file.write_bytes(b"media fixture; decoding is mocked in controller tests")
    return file
