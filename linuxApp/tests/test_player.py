import os
import shutil
import sys
import time
from pathlib import Path

import pytest

from auraflow import AuraFlowError
from auraflow.backends.wayland import bridge_command
from auraflow.backends.wayland import command as wayland_command
from auraflow.player import Player, player_options
from auraflow.settings import Settings


def test_json_ipc_handles_events_and_fragmented_replies_and_child_lifetime(tmp_path):
    helper = Path(__file__).with_name("fake_player.py")
    with (tmp_path / "player.log").open("ab") as log:
        player = Player(lambda fd: [sys.executable, str(helper), str(fd)], log)
        try:
            player.wait_ready(time.monotonic() + 3)
            player.set_property("pause", True)
            assert player.command("get_property", "pause") is True
            player.set_property("speed", 2.0)
            assert player.command("get_property", "speed") == 2.0
            with pytest.raises(AuraFlowError, match="property unavailable"):
                player.command("get_property", "missing")
        finally:
            player.close()
        assert player.process.poll() is not None


def test_wayland_bridge_cleans_up_its_player_when_owner_disconnects(paths, tmp_path, monkeypatch):
    helper = Path(__file__).with_name("fake_player.py")
    executable = tmp_path / "mpvpaper"
    executable.write_text(f"#!{sys.executable}\n" + helper.read_text())
    executable.chmod(0o755)
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ["PATH"])
    pid_file = tmp_path / "player.pid"
    monkeypatch.setenv("AURAFLOW_TEST_PLAYER_PID", str(pid_file))
    with (tmp_path / "bridge.log").open("ab") as log:
        player = Player(lambda fd: bridge_command(tmp_path / "video.mp4", Settings(), fd), log)
        try:
            player.wait_ready(time.monotonic() + 5)
            player.set_property("pause", True)
            assert player.command("get_property", "pause") is True
            child_pid = int(pid_file.read_text())
        except Exception:
            print((tmp_path / "bridge.log").read_text())
            raise
        finally:
            player.close()
    with pytest.raises(ProcessLookupError):
        os.kill(child_pid, 0)
    assert list(paths.runtime.glob("mp-*.sock")) == []


@pytest.mark.skipif(not shutil.which("mpv"), reason="mpv is not installed")
def test_real_mpv_decodes_an_image_and_accepts_runtime_options_without_windows(tmp_path):
    image = Path(__file__).parents[1] / "src/auraflow/assets/icon.png"
    with (tmp_path / "mpv.log").open("ab") as log:
        player = Player(
            lambda fd: [
                "mpv",
                *player_options(Settings(), fd),
                "--vo=null",
                "--",
                str(image),
            ],
            log,
        )
        try:
            player.wait_ready(time.monotonic() + 10)
            assert player.command("get_property", "video-params")["w"] == 1024
            for name, value in (
                ("pause", True),
                ("speed", 0.75),
                ("keepaspect", False),
                ("panscan", 0),
            ):
                player.set_property(name, value)
                assert player.command("get_property", name) == value
        except Exception:
            print((tmp_path / "mpv.log").read_text())
            raise
        finally:
            player.close()
        assert player.process.poll() is not None


@pytest.mark.skipif(not shutil.which("mpv"), reason="mpv is not installed")
def test_real_mpv_accepts_mpvpaper_config_syntax_and_socket_paths_with_spaces(tmp_path):
    image = Path(__file__).parents[1] / "src/auraflow/assets/icon.png"
    # Keep the Unix socket short enough on macOS too.
    from tempfile import TemporaryDirectory

    with TemporaryDirectory(prefix="af-config-", dir="/tmp") as directory:
        endpoint = Path(directory) / "socket with spaces.sock"
        config = tmp_path / "mpv.conf"
        options = wayland_command(image, Settings(speed=0.75, scale="stretch"), endpoint)[2]
        config.write_text(options.replace(" --", "\n--"))
        with (tmp_path / "config.log").open("ab") as log:
            player = Player(
                lambda fd: [
                    "mpv",
                    "--vo=null",
                    f"--include={config}",
                    f"--input-ipc-client=fd://{fd}",
                    "--",
                    str(image),
                ],
                log,
            )
            try:
                player.wait_ready(time.monotonic() + 5)
                assert player.command("get_property", "speed") == 0.75
                assert player.command("get_property", "keepaspect") is False
                assert player.command("get_property", "input-ipc-server") == str(endpoint)
                assert player.healthy()
            finally:
                player.close()
