import json
import os
import socket
import subprocess
import sys
import threading
import time

import pytest

from auraflow import AuraFlowError
from auraflow.cli import main
from auraflow.desktop import DesktopIntegration
from auraflow.service import MAX_MESSAGE, Client, read_message


def test_offline_controls_do_not_launch_processes(paths, store, media, monkeypatch):
    client = Client(paths)

    def unexpected_launch():
        pytest.fail("This action must not launch the wallpaper service")

    monkeypatch.setattr(client, "_launch", unexpected_launch)
    store.update(restore=str(media))
    assert not client.request("status")["running"]
    client.request("scale", value="fit")
    client.request("speed", value=1.25)
    client.request("pause")
    client.request("remove")
    assert store.load().scale == "fit"
    assert store.load().speed == 1.25
    assert store.load().restore is None


def test_login_restore_requires_registration_and_does_not_restart_active_playback(
    paths,
    store,
    media,
    monkeypatch,
):
    calls = []

    def request(_self, action, **values):
        calls.append((action, values))
        return {"running": True, "paused": True}

    monkeypatch.setattr(Client, "request", request)
    store.update(restore=str(media))
    assert main(["restore"]) == 0
    assert calls == []
    registration = DesktopIntegration(paths)
    registration.set_autostart(True)
    assert main(["restore"]) == 0
    assert calls == [("status", {})]
    registration.set_autostart(False)
    calls.clear()
    assert main(["restore"]) == 0
    assert calls == []


@pytest.mark.parametrize("payload", [b"[]\n", b"broken\n", b"x" * (MAX_MESSAGE + 1) + b"\n"])
def test_protocol_rejects_invalid_or_oversized_messages(payload):
    sender, receiver = socket.socketpair()
    with sender, receiver:
        writer = threading.Thread(target=sender.sendall, args=(payload,), daemon=True)
        writer.start()
        with pytest.raises(AuraFlowError):
            read_message(receiver)
        writer.join(timeout=2)
        assert not writer.is_alive()


def test_real_service_singleton_protocol_and_shutdown_in_temporary_session(paths, store, media):
    # No display surfaces are created: all service commands here are read-only/idle.
    store.update(restore=str(media))
    process = subprocess.Popen([sys.executable, "-m", "auraflow", "serve"], env=dict(os.environ))
    client = Client(paths)
    try:
        deadline = time.monotonic() + 5
        while not paths.socket.exists() and time.monotonic() < deadline:
            assert process.poll() is None
            time.sleep(0.02)
        assert paths.socket.stat().st_mode & 0o777 == 0o600
        assert not client.request("status")["running"]
        duplicate = subprocess.run(
            [sys.executable, "-m", "auraflow", "serve"],
            timeout=5,
            check=False,
        )
        assert duplicate.returncode == 0
        assert paths.socket.exists()
        with socket.socket(socket.AF_UNIX) as connection:
            connection.connect(str(paths.socket))
            connection.sendall(b"[invalid]\n")
            assert json.loads(connection.recv(4096))["ok"] is False
        assert not client.request("status")["running"]
        client.request("shutdown")
        process.wait(timeout=5)
        assert not paths.socket.exists()
        assert store.load().restore == str(media)
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
