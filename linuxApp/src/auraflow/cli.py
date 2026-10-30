from __future__ import annotations

import argparse
import json
import sys

from . import AuraFlowError, __version__
from .backends import diagnostics
from .desktop import DesktopIntegration
from .paths import AppPaths
from .service import Client, serve
from .settings import BACKENDS, SCALES, SettingsStore


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="AuraFlow live wallpapers for Linux")
    result.add_argument("--version", action="version", version=f"AuraFlow Linux {__version__}")
    commands = result.add_subparsers(dest="action")
    commands.add_parser("gui", help="Open the control panel (default)")
    start = commands.add_parser("start", help="Start a local video, GIF, or image wallpaper")
    start.add_argument("media", nargs="?")
    start.add_argument("--backend", choices=BACKENDS)
    for action in ("status", "pause", "resume", "remove", "shutdown"):
        commands.add_parser(action)
    scale = commands.add_parser("scale", help="Change scale without restarting playback")
    scale.add_argument("value", choices=SCALES)
    speed = commands.add_parser("speed", help="Playback speed, 0.1 to 4")
    speed.add_argument("value", type=float)
    login = commands.add_parser("autostart", help="Change future login registration only")
    login.add_argument("value", choices=("on", "off", "status"))
    commands.add_parser("restore", help="Restore saved playback at login when autostart is enabled")
    commands.add_parser("doctor", help="Report session compatibility and required executables")
    commands.add_parser("install-desktop", help="Install a launcher for this Python environment")
    commands.add_parser("serve", help=argparse.SUPPRESS)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    paths = AppPaths.discover()
    try:
        action = args.action or "gui"
        if action == "gui":
            try:
                from .gui import run
            except ImportError as exc:
                raise AuraFlowError(
                    "Install the GUI with: pip install '.[gui]' (in linuxApp)."
                ) from exc
            return run(paths)
        if action == "serve":
            return serve(paths)
        desktop = DesktopIntegration(paths)
        store = SettingsStore(paths)
        client = Client(paths)
        if action == "doctor":
            output = diagnostics(store.load().backend)
            output.update(settings=str(paths.settings), log=str(paths.log))
        elif action == "install-desktop":
            output = {"launcher": str(desktop.install_launcher())}
        elif action == "autostart":
            if args.value != "status":
                desktop.set_autostart(args.value == "on")
            output = {"autostart": desktop.autostart_enabled()}
        elif action == "restore":
            settings = store.load()
            if not desktop.autostart_enabled() or not settings.restore:
                return 0
            # Duplicate autostart delivery must not restart or unpause a running session.
            if client.request("status")["running"]:
                return 0
            output = client.request("start", media=settings.restore)
        elif action == "start":
            values = {"media": args.media} if args.media else {}
            if args.backend:
                values["backend"] = args.backend
            output = client.request("start", **values)
        else:
            values = {"value": args.value} if action in ("scale", "speed") else {}
            output = client.request(action, **values)
        print(json.dumps(output, indent=2, ensure_ascii=False))
        return 0
    except (AuraFlowError, OSError) as exc:
        print(f"AuraFlow: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
