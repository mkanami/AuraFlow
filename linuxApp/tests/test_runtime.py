import io

import pytest

from auraflow import AuraFlowError
from auraflow.desktop import DesktopIntegration
from auraflow.runtime import Controller


class FakeSession:
    def __init__(self, media, settings, *, error=None):
        self.media = media
        self.backend = settings.backend
        self.players = [object(), object()]
        self.properties = []
        self.closed = False
        self.healthy = True
        self.error = error

    def wait_ready(self):
        if self.error:
            raise AuraFlowError(self.error)

    def set_properties(self, properties):
        self.properties.append(properties)

    def alive(self):
        return self.healthy

    def close(self):
        self.closed = True


@pytest.fixture
def controller(store):
    sessions = []

    def factory(media, settings, _log):
        session = FakeSession(media, settings)
        sessions.append(session)
        return session

    result = Controller(store, io.BytesIO(), factory)
    result.created = sessions
    return result


def test_start_pause_scale_speed_and_remove(controller, media, store):
    status = controller.execute({"action": "start", "media": str(media), "backend": "x11"})
    assert status["running"] and status["outputs"] == 2
    session = controller.created[0]
    controller.execute({"action": "pause"})
    controller.execute({"action": "scale", "value": "stretch"})
    controller.execute({"action": "speed", "value": 0.7})
    assert controller.status()["paused"]
    assert controller.created == [session]
    assert session.properties == [
        {"pause": True},
        {"keepaspect": False, "panscan": 0.0},
        {"speed": 0.7},
    ]
    assert store.load().restore == str(media)
    controller.execute({"action": "resume"})
    assert not controller.status()["paused"]
    controller.execute({"action": "remove"})
    assert session.closed and not controller.status()["running"]
    assert store.load().restore is None
    assert store.load().selected == str(media)


def test_preview_selection_does_not_replace_active_wallpaper(controller, media, store, tmp_path):
    controller.execute({"action": "start", "media": str(media)})
    preview = tmp_path / "preview.webm"
    preview.touch()
    store.select(preview)
    controller.execute({"action": "scale", "value": "fit"})
    assert controller.status()["media"] == str(media)
    assert store.load().selected == str(preview)
    assert store.load().restore == str(media)
    assert len(controller.created) == 1


def test_failed_replacement_keeps_previous_session_and_saved_choice(
    controller, media, store, tmp_path
):
    controller.execute({"action": "start", "media": str(media)})
    previous = controller.session
    invalid = tmp_path / "undecodable.mp4"
    invalid.touch()
    candidate = FakeSession(invalid, store.load(), error="Decoder failed")
    controller.factory = lambda *_: candidate
    with pytest.raises(AuraFlowError, match="Decoder failed"):
        controller.execute({"action": "start", "media": str(invalid)})
    assert candidate.closed and not previous.closed
    assert controller.session is previous
    assert store.load().restore == str(media)


def test_failed_settings_write_rolls_back_live_properties(controller, media, monkeypatch):
    controller.execute({"action": "start", "media": str(media)})

    def fail(**_):
        raise OSError("Disk full")

    monkeypatch.setattr(controller.store, "update", fail)
    with pytest.raises(OSError):
        controller.execute({"action": "speed", "value": 2.0})
    assert controller.session.properties[-2:] == [{"speed": 2.0}, {"speed": 1.0}]


def test_partial_pause_failure_rolls_back_other_displays(controller, media, monkeypatch):
    controller.execute({"action": "start", "media": str(media)})
    calls = []

    def partial(properties):
        calls.append(properties)
        if len(calls) == 1:
            raise AuraFlowError("Second display disconnected")

    monkeypatch.setattr(controller.session, "set_properties", partial)
    with pytest.raises(AuraFlowError, match="disconnected"):
        controller.execute({"action": "pause"})
    assert calls == [{"pause": True}, {"pause": False}]
    assert not controller.status()["paused"]


def test_shutdown_and_player_failure_clean_up_only_owned_session(controller, media, store):
    controller.execute({"action": "start", "media": str(media)})
    session = controller.session
    session.healthy = False
    controller.check_health()
    assert session.closed and controller.status()["error"]
    assert store.load().restore == str(media)
    controller.execute({"action": "start", "media": str(media)})
    session = controller.session
    controller.execute({"action": "shutdown"})
    assert session.closed and controller.shutdown_requested
    assert store.load().restore == str(media)


@pytest.mark.parametrize("paused", [False, True])
@pytest.mark.parametrize("enabled", [False, True])
def test_launch_at_login_is_independent_of_current_playback(
    controller,
    store,
    media,
    paths,
    paused,
    enabled,
):
    controller.execute({"action": "start", "media": str(media)})
    if paused:
        controller.execute({"action": "pause"})
    session = controller.session
    before_status = controller.status()
    before_settings = paths.settings.read_bytes()
    before_commands = session.properties.copy()
    registration = DesktopIntegration(paths, ["/test/venv/python", "-m", "auraflow"])
    registration.set_autostart(enabled)
    assert registration.autostart_enabled() is enabled
    assert controller.status() == before_status
    assert paths.settings.read_bytes() == before_settings
    assert session.properties == before_commands
    assert controller.created == [session]
    assert not session.closed


@pytest.mark.parametrize(
    "action,value", [("speed", float("nan")), ("scale", "crop"), ("speed", True)]
)
def test_invalid_playback_settings_do_not_reach_player(controller, media, action, value):
    controller.execute({"action": "start", "media": str(media)})
    with pytest.raises(AuraFlowError):
        controller.execute({"action": action, "value": value})
    assert controller.session.properties == []
