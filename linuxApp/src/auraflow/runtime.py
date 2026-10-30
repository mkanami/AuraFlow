from __future__ import annotations

import logging
from dataclasses import replace
from typing import BinaryIO

from . import AuraFlowError
from .backends import start_session
from .player import WallpaperSession, scale_properties
from .settings import BACKENDS, SCALES, SettingsStore, validate_media, validate_speed


class Controller:
    def __init__(self, store: SettingsStore, log: BinaryIO, factory=start_session):
        self.store = store
        self.log = log
        self.factory = factory
        self.session: WallpaperSession | None = None
        self.paused = False
        self.error: str | None = None
        self.shutdown_requested = False

    def status(self) -> dict[str, object]:
        settings = self.store.load()
        return {
            "running": self.session is not None,
            "paused": self.paused,
            "media": str(self.session.media) if self.session else None,
            "backend": self.session.backend if self.session else None,
            "outputs": len(self.session.players) if self.session else 0,
            "scale": settings.scale,
            "speed": settings.speed,
            "error": self.error,
        }

    def execute(self, request: dict[str, object]) -> dict[str, object]:
        action = request.get("action")
        if action == "start":
            self._start(request)
        elif action in ("pause", "resume"):
            if self.session:
                paused = action == "pause"
                try:
                    self.session.set_properties({"pause": paused})
                except AuraFlowError:
                    try:
                        self.session.set_properties({"pause": self.paused})
                    except AuraFlowError:
                        self.close()
                    raise
                self.paused = paused
        elif action == "remove":
            self.store.update(restore=None)
            self.close()
            self.error = None
        elif action in ("scale", "speed"):
            self._set_playback_property(action, request.get("value"))
        elif action == "shutdown":
            self.close()
            self.shutdown_requested = True
        elif action != "status":
            raise AuraFlowError(f"Unknown runtime action: {action}")
        return self.status()

    def _start(self, request: dict[str, object]) -> None:
        settings = self.store.load()
        media_value = request.get("media") or settings.selected
        if not isinstance(media_value, str):
            raise AuraFlowError("Choose a local wallpaper first.")
        media = validate_media(media_value)
        backend = request.get("backend", settings.backend)
        if backend not in BACKENDS:
            raise AuraFlowError("Choose auto, x11, or wayland as the backend.")
        settings = replace(settings, backend=backend)
        candidate = self.factory(media, settings, self.log)
        try:
            candidate.wait_ready()
            recent = [str(media), *(item for item in settings.recent if item != str(media))][:50]
            self.store.update(
                selected=str(media), restore=str(media), recent=recent, backend=backend
            )
        except BaseException:
            candidate.close()
            raise
        previous, self.session = self.session, candidate
        self.paused = False
        self.error = None
        if previous:
            previous.close()

    def _set_playback_property(self, name: str, value: object) -> None:
        settings = self.store.load()
        if name == "scale":
            if value not in SCALES:
                raise AuraFlowError("Scale must be fill, fit, or stretch.")
            properties = scale_properties(value)
            previous = scale_properties(settings.scale)
        else:
            value = validate_speed(value)
            properties, previous = {"speed": value}, {"speed": settings.speed}
        try:
            if self.session:
                self.session.set_properties(properties)
            self.store.update(**{name: value})
        except (AuraFlowError, OSError):
            if self.session:
                try:
                    self.session.set_properties(previous)
                except AuraFlowError:
                    self.close()
            raise

    def check_health(self) -> None:
        if self.session and not self.session.alive():
            self.close()
            self.error = "Wallpaper player stopped. Run auraflow doctor or check daemon.log."
            logging.error(self.error)

    def close(self) -> None:
        previous, self.session = self.session, None
        self.paused = False
        if previous:
            previous.close()


def idle_status(store: SettingsStore) -> dict[str, object]:
    settings = store.load()
    return {
        "running": False,
        "paused": False,
        "media": None,
        "backend": None,
        "outputs": 0,
        "scale": settings.scale,
        "speed": settings.speed,
        "error": None,
    }
