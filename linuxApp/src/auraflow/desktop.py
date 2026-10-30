from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

from . import AuraFlowError
from .paths import AppPaths

DESKTOP_ID = "io.github.mkanami.AuraFlow.desktop"
MARKER = "X-AuraFlow-Managed=true"


def desktop_exec(arguments: list[str]) -> str:
    """Quote argv for Desktop Entry Exec, including its second escaping layer."""
    result = []
    for argument in arguments:
        if any(ord(character) < 32 for character in argument):
            raise AuraFlowError("Desktop entry paths cannot contain control characters.")
        argument = argument.replace("%", "%%")
        quoted = "".join("\\" + c if c in '\\"`$' else c for c in argument)
        result.append('"' + quoted.replace("\\", "\\\\") + '"')
    return " ".join(result)


class DesktopIntegration:
    def __init__(self, paths: AppPaths, command: list[str] | None = None):
        self.paths = paths
        # Do not resolve the venv interpreter symlink to the system interpreter.
        self.command = command or [os.path.abspath(sys.executable), "-m", "auraflow"]

    def autostart_enabled(self) -> bool:
        try:
            text = self.paths.autostart.read_text(encoding="utf-8")
            return MARKER in text.splitlines() and "Hidden=true" not in text.splitlines()
        except FileNotFoundError:
            return False

    def set_autostart(self, enabled: bool) -> None:
        # Registration only: never contact the runtime or mutate playback settings.
        self._write(self.paths.autostart, self._entry(["restore"], hidden=not enabled))

    def install_launcher(self) -> Path:
        target = self.paths.applications / DESKTOP_ID
        self._write(target, self._entry(["gui"]))
        return target

    def _entry(self, arguments: list[str], *, hidden: bool = False) -> str:
        return "\n".join(
            [
                "[Desktop Entry]",
                "Type=Application",
                "Version=1.0",
                "Name=AuraFlow",
                "Comment=Live wallpapers for your desktop",
                "Exec=" + desktop_exec([*self.command, *arguments]),
                "Icon=" + str(Path(__file__).parent / "assets/icon.png").replace("\\", "\\\\"),
                "Terminal=false",
                "Categories=Utility;Graphics;",
                "StartupNotify=false",
                f"Hidden={'true' if hidden else 'false'}",
                MARKER,
                "",
            ]
        )

    @staticmethod
    def _write(path: Path, contents: str) -> None:
        if path.exists() and MARKER not in path.read_text(encoding="utf-8").splitlines():
            raise AuraFlowError(
                f"Refusing to replace a desktop entry not managed by AuraFlow: {path}"
            )
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".auraflow-", dir=path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                stream.write(contents)
            os.replace(temporary, path)
        finally:
            Path(temporary).unlink(missing_ok=True)
