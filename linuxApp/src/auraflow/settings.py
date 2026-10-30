from __future__ import annotations

import fcntl
import json
import math
import os
import tempfile
from dataclasses import asdict, dataclass, field
from pathlib import Path

from . import AuraFlowError
from .paths import AppPaths, private_directory

MEDIA_EXTENSIONS = frozenset(
    {
        ".mp4",
        ".m4v",
        ".mov",
        ".webm",
        ".mkv",
        ".avi",
        ".gif",
        ".apng",
        ".png",
        ".jpg",
        ".jpeg",
        ".webp",
        ".bmp",
        ".avif",
    }
)
SCALES = ("fill", "fit", "stretch")
BACKENDS = ("auto", "x11", "wayland")


def validate_media(value: str | Path) -> Path:
    path = Path(value).expanduser().resolve()
    if not path.is_file():
        raise AuraFlowError(f"Media file does not exist: {path}")
    if path.suffix.lower() not in MEDIA_EXTENSIONS:
        raise AuraFlowError(
            "Choose a local video, GIF, or image. Playlists and URLs are unsupported."
        )
    if not os.access(path, os.R_OK):
        raise AuraFlowError(f"Media file is not readable: {path}")
    return path


def validate_speed(value: object) -> float:
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        raise AuraFlowError("Playback speed must be a number from 0.1 to 4.")
    speed = float(value)
    if not math.isfinite(speed) or not 0.1 <= speed <= 4:
        raise AuraFlowError("Playback speed must be from 0.1 to 4.")
    return speed


@dataclass(frozen=True)
class Settings:
    version: int = 1
    selected: str | None = None
    restore: str | None = None
    recent: list[str] = field(default_factory=list)
    scale: str = "fill"
    speed: float = 1.0
    backend: str = "auto"

    @classmethod
    def parse(cls, raw: object) -> Settings:
        if not isinstance(raw, dict) or raw.get("version", 1) != 1:
            raise AuraFlowError(
                "Unsupported settings format; the original file has been preserved."
            )
        for key in ("selected", "restore"):
            if raw.get(key) is not None and not isinstance(raw[key], str):
                raise AuraFlowError(f"Invalid {key} in settings.")
        recent = raw.get("recent", [])
        if not isinstance(recent, list) or any(not isinstance(item, str) for item in recent):
            raise AuraFlowError("Invalid recent media in settings.")
        scale, backend = raw.get("scale", "fill"), raw.get("backend", "auto")
        if scale not in SCALES or backend not in BACKENDS:
            raise AuraFlowError("Invalid scale or backend in settings.")
        return cls(
            selected=raw.get("selected"),
            restore=raw.get("restore"),
            recent=recent[:50],
            scale=scale,
            speed=validate_speed(raw.get("speed", 1.0)),
            backend=backend,
        )


class SettingsStore:
    def __init__(self, paths: AppPaths):
        self.paths = paths

    def load(self) -> Settings:
        try:
            return Settings.parse(json.loads(self.paths.settings.read_text(encoding="utf-8")))
        except FileNotFoundError:
            return Settings()
        except (OSError, ValueError) as exc:
            raise AuraFlowError(f"Cannot read {self.paths.settings}: {exc}") from exc

    def update(self, **changes: object) -> Settings:
        private_directory(self.paths.config)
        # GUI selection and daemon playback updates must not overwrite one another.
        with (self.paths.config / "settings.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            raw = asdict(self.load())
            raw.update(changes)
            settings = Settings.parse(raw)
            fd, temporary = tempfile.mkstemp(prefix="settings-", dir=self.paths.config)
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as stream:
                    json.dump(asdict(settings), stream, indent=2, ensure_ascii=False)
                    stream.write("\n")
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, self.paths.settings)
            finally:
                Path(temporary).unlink(missing_ok=True)
            return settings

    def select(self, path: str | Path) -> Settings:
        media = str(validate_media(path))
        # A selection is a preview; only a successful Start changes restore.
        settings = self.load()
        recent = [media, *(item for item in settings.recent if item != media)][:50]
        return self.update(selected=media, recent=recent)
