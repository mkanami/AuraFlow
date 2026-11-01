from __future__ import annotations

import hashlib
import os
import stat
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from . import AuraFlowError


def private_directory(path: Path) -> Path:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise AuraFlowError(f"Not a private directory owned by this user: {path}")
    path.chmod(0o700)
    return path


@dataclass(frozen=True)
class AppPaths:
    config: Path
    data: Path
    state: Path
    runtime: Path
    autostart: Path
    applications: Path

    @classmethod
    def discover(cls, env: Mapping[str, str] | None = None) -> AppPaths:
        env = os.environ if env is None else env
        home = Path(env.get("HOME", str(Path.home())))

        def xdg(name: str, fallback: Path) -> Path:
            candidate = Path(env.get(name, ""))
            return candidate if candidate.is_absolute() else fallback

        config = xdg("XDG_CONFIG_HOME", home / ".config")
        data = xdg("XDG_DATA_HOME", home / ".local/share")
        state = xdg("XDG_STATE_HOME", home / ".local/state")
        cache = xdg("XDG_CACHE_HOME", home / ".cache")
        runtime = xdg("XDG_RUNTIME_DIR", cache)
        # Separate an X11 login from a Wayland login, including its Xwayland display.
        session = env.get("WAYLAND_DISPLAY") or env.get("DISPLAY") or "headless"
        # Launchers managed by systemd can omit XDG_SESSION_ID while terminals
        # have it. They still need to reach the same graphical session's service.
        identity = session
        digest = hashlib.sha256(identity.encode()).hexdigest()[:12]
        return cls(
            config / "auraflow",
            data / "auraflow",
            state / "auraflow",
            runtime / "auraflow" / digest,
            config / "autostart" / "io.github.mkanami.AuraFlow.desktop",
            data / "applications",
        )

    @property
    def settings(self) -> Path:
        return self.config / "settings.json"

    @property
    def socket(self) -> Path:
        result = self.runtime / "control.sock"
        if len(os.fsencode(result)) > 100:
            raise AuraFlowError("Runtime path is too long. Set XDG_RUNTIME_DIR to a shorter path.")
        return result

    @property
    def log(self) -> Path:
        return self.state / "daemon.log"
