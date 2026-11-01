import io
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest
from PIL import Image

from auraflow import AuraFlowError
from auraflow.backends.wayland import bridge_command
from auraflow.desktop import DesktopIntegration
from auraflow.player import Player, player_options
from auraflow.runtime import Controller
from auraflow.settings import Settings
from auraflow.terminal import FrameSink, TerminalProducer, TerminalRenderer, TerminalSession
from auraflow.terminal_config import TerminalConfig, programs


def configuration(code='print("Terminal wallpaper")', **kwargs):
    return TerminalConfig(argv=(sys.executable, "-u", "-c", code), columns=40, rows=10, **kwargs)


def test_terminal_configuration_is_argv_and_preserves_shell_metacharacters_as_text(tmp_path):
    config = TerminalConfig.from_command("printf '%s' '$(touch nope); echo hello'")
    assert config.argv == ("printf", "%s", "$(touch nope); echo hello")
    assert not (tmp_path / "nope").exists()
    for raw in (
        {"argv": []},
        {"argv": [1]},
        {"argv": ["a\0b"]},
        {"argv": ["printf"], "rows": 9999},
        {"argv": ["printf"], "fps": True},
        {"argv": ["printf"], "background": "not a color"},
    ):
        with pytest.raises(AuraFlowError):
            TerminalConfig.parse(raw)


def test_missing_program_is_reported_before_starting_a_pty():
    with pytest.raises(AuraFlowError, match="Install"):
        TerminalProducer(TerminalConfig(argv=("auraflow-nonexistent-test-program",)))


def test_ansi_colors_cursor_movement_unicode_and_static_frames():
    renderer = TerminalRenderer(configuration())
    renderer.feed(b"\x1b[2J\x1b[H\x1b[31mRed\x1b[0m\r\n\x1b[42mGreen\x1b[0m")
    renderer.feed("\r\nПривет".encode())
    assert renderer.screen.display[0].startswith("Red")
    assert renderer.screen.display[2].startswith("Привет")
    frame = renderer.render()
    image = Image.frombytes("RGB", (renderer.format.width, renderer.format.height), frame)
    assert image.getpixel((0, renderer.cell_height)) == (13, 188, 121)
    assert image.getpixel((image.width - 1, image.height - 1)) == (11, 15, 22)
    assert frame == renderer.render()
    renderer.feed(b"\x1b[H\x1b[2KChanged")
    assert renderer.render() != frame


def test_real_pty_keeps_completed_output_and_closes_idempotently():
    producer = TerminalProducer(configuration())
    try:
        producer.wait_ready()
        producer.process.wait(timeout=3)
        before = producer.latest_frame
        time.sleep(0.1)
        assert producer.latest_frame == before
        assert producer.failure is None
        assert producer.renderer.screen.display[0].startswith("Terminal wallpaper")
    finally:
        producer.close()
        producer.close()
    assert not producer.thread.is_alive()


def test_pause_freezes_the_program_and_resume_keeps_the_same_pty():
    code = 'import time\ni=0\nwhile True:\n print("\\033[H"+str(i),flush=True);i+=1;time.sleep(.03)'
    producer = TerminalProducer(configuration(code))
    try:
        producer.wait_ready()
        pid = producer.process.pid
        producer.set_paused(True)
        time.sleep(0.05)
        frame = producer.latest_frame
        time.sleep(0.15)
        assert producer.latest_frame == frame
        producer.set_paused(False)
        deadline = time.monotonic() + 2
        while producer.latest_frame == frame and time.monotonic() < deadline:
            time.sleep(0.02)
        assert producer.latest_frame != frame
        assert producer.process.pid == pid
        assert producer.failure is None
    finally:
        producer.close()


def test_cleanup_targets_owned_process_group_and_preserves_unrelated_process():
    unrelated = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(10)"])
    producer = TerminalProducer(
        configuration('import time;print("ready",flush=True);time.sleep(10)')
    )
    try:
        producer.wait_ready()
        producer.set_paused(True)
        producer.close()
        assert producer.process.poll() is not None
        assert unrelated.poll() is None
        with pytest.raises(ProcessLookupError):
            os.killpg(producer.process.pid, signal.SIGCONT)
    finally:
        producer.close()
        unrelated.terminate()
        unrelated.wait(timeout=3)


def test_slow_frame_consumer_never_gets_interleaved_partial_frames():
    reader, writer = os.pipe()
    os.set_blocking(reader, False)
    sink = FrameSink(writer)
    frame = b"A" * 300000
    output = bytearray()
    try:
        sink.offer(frame)
        sink.flush()
        sink.offer(b"B" * len(frame))
        deadline = time.monotonic() + 3
        while len(output) < len(frame) and time.monotonic() < deadline:
            try:
                output.extend(os.read(reader, 65536))
            except BlockingIOError:
                pass
            sink.flush()
        assert bytes(output) == frame
        assert not sink.pending
    finally:
        sink.close()
        os.close(reader)


@pytest.mark.skipif(not shutil.which("mpv"), reason="mpv is not installed")
def test_real_mpv_decodes_terminal_frames_with_no_desktop_windows(tmp_path):
    producer = TerminalProducer(configuration())
    try:
        with (tmp_path / "terminal-mpv.log").open("ab") as log:
            reader = producer.attach()
            player = Player(
                lambda fd: [
                    "mpv",
                    *player_options(Settings(), fd),
                    *producer.format.options(),
                    "--vo=null",
                    "--",
                    "-",
                ],
                log,
                stdin=reader,
            )
            reader.close()
            try:
                producer.wait_ready()
                player.wait_ready(time.monotonic() + 5)
                params = player.command("get_property", "video-params")
                assert (params["w"], params["h"]) == (producer.format.width, producer.format.height)
                player.set_property("pause", True)
                producer.set_paused(True)
                assert player.command("get_property", "pause") is True
                assert player.healthy()
            finally:
                player.close()
    finally:
        producer.close()


@pytest.mark.skipif(not shutil.which("cmatrix"), reason="CMatrix is not installed")
def test_cmatrix_native_speed_does_not_restart_or_resume_paused_program():
    producer = TerminalProducer(TerminalConfig.from_preset("cmatrix", columns=40, rows=10))
    try:
        producer.wait_ready()
        pid = producer.process.pid
        producer.set_paused(True)
        producer.set_speed(2.0)
        assert producer.paused and producer.process.pid == pid
        producer.set_paused(False)
        time.sleep(0.05)
        assert producer.process.poll() is None
    finally:
        producer.close()


class FakeVideo:
    def __init__(self):
        self.players = [object(), object()]
        self.backend = "x11"
        self.properties = []
        self.closed = False

    def wait_ready(self):
        pass

    def set_properties(self, value):
        self.properties.append(value)

    def alive(self):
        return not self.closed

    def close(self):
        self.closed = True


def test_terminal_session_shares_one_program_and_forwards_only_video_properties(tmp_path):
    native = FakeVideo()
    with (tmp_path / "terminal.log").open("ab") as log:
        session = TerminalSession(configuration(), Settings(), log, factory=lambda *_: native)
        try:
            session.wait_ready()
            session.set_properties({"pause": True})
            session.set_properties({"keepaspect": True, "panscan": 0})
            assert session.producer.paused
            assert session.players == native.players
            assert session.alive()
            with pytest.raises(AuraFlowError, match="Live speed"):
                session.set_properties({"speed": 2})
            assert native.properties == [{"pause": True}, {"keepaspect": True, "panscan": 0}]
        finally:
            session.close()
        assert native.closed and not session.producer.thread.is_alive()


def test_applied_terminal_snapshot_keeps_resolved_executable_for_login(paths, store):
    native = FakeVideo()
    config = TerminalConfig(argv=("printf", "Wallpaper"), columns=40, rows=10)
    controller = Controller(
        store,
        io.BytesIO(),
        terminal_factory=lambda cfg, settings, log: TerminalSession(
            cfg, settings, log, factory=lambda *_: native
        ),
    )
    try:
        controller.execute({"action": "terminal-start", "config": config.to_dict()})
        saved = TerminalConfig.parse(store.load().restore_terminal)
        assert saved.argv[0] == str(Path(shutil.which("printf")).absolute())
        assert saved.argv[1:] == config.argv[1:]
    finally:
        controller.close()


class FakeTerminal(FakeVideo):
    kind = "terminal"
    speed_supported = False

    def __init__(self, config, settings, log):
        super().__init__()
        self.config = config
        self.media = Path(config.argv[0])
        self.label = config.label


@pytest.mark.parametrize("paused", [False, True])
@pytest.mark.parametrize("enabled", [False, True])
def test_login_registration_is_independent_of_terminal_playback_and_restoration(
    paths,
    store,
    paused,
    enabled,
):
    controller = Controller(store, io.BytesIO(), terminal_factory=FakeTerminal)
    config = configuration()
    controller.execute({"action": "terminal-start", "config": config.to_dict()})
    if paused:
        controller.execute({"action": "pause"})
    session = controller.session
    before = (controller.status(), paths.settings.read_bytes(), session.properties.copy())
    DesktopIntegration(paths).set_autostart(enabled)
    assert controller.status() == before[0]
    assert paths.settings.read_bytes() == before[1]
    assert session.properties == before[2]
    assert not session.closed


def test_terminal_preview_selection_does_not_replace_restoration_and_remove_clears_it(paths, store):
    controller = Controller(store, io.BytesIO(), terminal_factory=FakeTerminal)
    active = configuration()
    controller.execute({"action": "terminal-start", "config": active.to_dict()})
    preview = configuration('print("Different command")')
    store.select_terminal(preview)
    assert TerminalConfig.parse(store.load().restore_terminal) == active
    assert controller.status()["label"] == active.label
    with pytest.raises(AuraFlowError, match="no live speed"):
        controller.execute({"action": "speed", "value": 2})
    assert controller.session is not None and not controller.session.closed
    controller.execute({"action": "remove"})
    assert store.load().restore_terminal is None
    assert TerminalConfig.parse(store.load().terminal) == preview


def test_program_search_never_executes_commands(monkeypatch, tmp_path):
    executable = tmp_path / "auraflow-custom-program"
    executable.write_text("#!/bin/sh\ntouch should-not-exist\n")
    executable.chmod(0o755)
    monkeypatch.setenv("PATH", str(tmp_path))
    result = programs("auraflow-custom")
    assert len(result) == 1 and result[0]["installed"] == str(executable)
    assert not (tmp_path / "should-not-exist").exists()


def test_wayland_bridge_passes_the_frame_stream_to_its_owned_child(paths, tmp_path, monkeypatch):
    helper = Path(__file__).with_name("fake_player.py")
    executable = tmp_path / "mpvpaper"
    executable.write_text(f"#!{sys.executable}\n" + helper.read_text())
    executable.chmod(0o755)
    monkeypatch.setenv("PATH", str(tmp_path) + os.pathsep + os.environ["PATH"])
    monkeypatch.setenv("AURAFLOW_TEST_PLAYER_PID", str(tmp_path / "paper.pid"))
    producer = TerminalProducer(configuration())
    try:
        with (tmp_path / "bridge.log").open("ab") as log:
            reader = producer.attach()
            player = Player(
                lambda fd: bridge_command(Path("-"), Settings(), fd, producer.format),
                log,
                stdin=reader,
            )
            reader.close()
            try:
                player.wait_ready(time.monotonic() + 5)
                assert player.command("get_property", "frame-sample") == (b"\x0b\x0f\x16" * 4).hex()
            finally:
                player.close()
    finally:
        producer.close()
