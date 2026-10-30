from __future__ import annotations

import re
import shlex
import shutil
from dataclasses import asdict, dataclass
from pathlib import Path

from . import AuraFlowError


@dataclass(frozen=True)
class Preset:
    id: str
    title: str
    executable: str
    arguments: tuple[str, ...] = ()
    package: str = ""


PRESETS = (
    Preset("cmatrix", "CMatrix · digital rain", "cmatrix", ("-u", "4"), "cmatrix"),
    Preset("pipes", "Pipes · colorful pipes", "pipes.sh", (), "pipes.sh"),
    Preset("lavat", "Lavat · lava lamp", "lavat", (), "lavat"),
    Preset("cbonsai", "Bonsai · growing trees", "cbonsai", ("-l", "-i"), "cbonsai"),
    Preset("bonsai-static", "Bonsai · still composition", "cbonsai", (), "cbonsai"),
    Preset("asciiquarium", "Asciiquarium · fish", "asciiquarium", (), "asciiquarium"),
    Preset("nyancat", "Nyan Cat", "nyancat", ("-n", "-s"), "nyancat"),
    Preset("btop", "btop · system monitor", "btop", (), "btop"),
    Preset("htop", "htop · process monitor", "htop", (), "htop"),
    Preset("fastfetch", "Fastfetch · system information", "fastfetch", (), "fastfetch"),
    Preset("top", "top · process monitor", "top"),
    Preset("vmstat", "vmstat · memory statistics", "vmstat", ("2",), "procps"),
    Preset("iostat", "iostat · disk statistics", "iostat", ("2",), "sysstat"),
)


@dataclass(frozen=True)
class TerminalConfig:
    argv: tuple[str, ...]
    preset: str | None = None
    columns: int = 100
    rows: int = 30
    font_size: int = 16
    fps: int = 20
    background: str = "#0b0f16"
    foreground: str = "#dce6f2"

    @classmethod
    def parse(cls, raw: object) -> TerminalConfig:
        if not isinstance(raw, dict):
            raise AuraFlowError("Invalid terminal wallpaper configuration.")
        argv = raw.get("argv")
        if not isinstance(argv, (list, tuple)) or not 1 <= len(argv) <= 128:
            raise AuraFlowError("Enter a program and its arguments.")
        if (
            any(not isinstance(arg, str) or "\0" in arg or len(arg) > 4096 for arg in argv)
            or not argv[0]
        ):
            raise AuraFlowError("Invalid terminal command arguments.")
        values = {}
        for key, default, low, high in (
            ("columns", 100, 20, 200),
            ("rows", 30, 8, 80),
            ("font_size", 16, 8, 32),
            ("fps", 20, 1, 30),
        ):
            value = raw.get(key, default)
            if type(value) is not int or not low <= value <= high:
                raise AuraFlowError(f"Terminal {key} must be between {low} and {high}.")
            values[key] = value
        for key, default in (("background", "#0b0f16"), ("foreground", "#dce6f2")):
            value = raw.get(key, default)
            if not isinstance(value, str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", value):
                raise AuraFlowError("Terminal colors must use #RRGGBB.")
            values[key] = value
        preset = raw.get("preset")
        if preset is not None and preset not in {item.id for item in PRESETS}:
            raise AuraFlowError("Unknown terminal preset.")
        return cls(tuple(argv), preset=preset, **values)

    @classmethod
    def from_command(cls, command: str, **appearance) -> TerminalConfig:
        try:
            argv = shlex.split(command)
        except ValueError as exc:
            raise AuraFlowError(f"Invalid command: {exc}") from exc
        return cls.parse({"argv": argv, **appearance})

    @classmethod
    def from_preset(cls, preset_id: str, **appearance) -> TerminalConfig:
        preset = next((item for item in PRESETS if item.id == preset_id), None)
        if not preset:
            raise AuraFlowError("Unknown terminal preset.")
        return cls.parse(
            {"argv": [preset.executable, *preset.arguments], "preset": preset.id, **appearance}
        )

    def to_dict(self) -> dict:
        return asdict(self)

    @property
    def label(self) -> str:
        return shlex.join(self.argv)

    @property
    def live_speed(self) -> bool:
        return (
            self.preset == "cmatrix"
            and Path(self.argv[0]).name == "cmatrix"
            and "-s" not in self.argv
        )

    def executable(self) -> str:
        result = shutil.which(self.argv[0])
        if not result:
            raise AuraFlowError(
                f"Install {self.argv[0]} with your distribution's package manager first."
            )
        return result


def programs(query: str = "") -> list[dict]:
    query = query.casefold().strip()
    result = []
    known = set()
    for item in PRESETS:
        known.add(item.executable)
        if query and query not in (item.title + " " + item.executable).casefold():
            continue
        result.append(
            {
                "id": item.id,
                "title": item.title,
                "executable": item.executable,
                "installed": shutil.which(item.executable),
                "package": item.package,
                "command": shlex.join((item.executable, *item.arguments)),
            }
        )
    # Search the user's PATH without executing anything or inventing launch arguments.
    if len(query) >= 2:
        import os

        for directory in dict.fromkeys(os.get_exec_path()):
            try:
                entries = Path(directory).iterdir()
                for entry in entries:
                    if query in entry.name.casefold() and entry.name not in known:
                        if entry.is_file() and os.access(entry, os.X_OK):
                            known.add(entry.name)
                            result.append(
                                {
                                    "id": None,
                                    "title": entry.name,
                                    "executable": str(entry),
                                    "installed": str(entry),
                                    "package": "",
                                    "command": shlex.quote(str(entry)),
                                }
                            )
                        if len(result) >= 100:
                            return result
            except OSError:
                continue
    return result
