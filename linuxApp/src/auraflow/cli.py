from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict

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
    catalog = commands.add_parser("catalog", help="Browse and download catalog wallpapers")
    catalogs = catalog.add_subparsers(dest="catalog_action", required=True)
    catalogs.add_parser("sources")
    search = catalogs.add_parser("search")
    search.add_argument("query", nargs="?", default="")
    search.add_argument(
        "--source", choices=("moewalls", "motionbgs", "dareful"), default="moewalls"
    )
    search.add_argument("--page", type=int, default=1)
    download = catalogs.add_parser("download")
    download.add_argument("page_url")
    download.add_argument("--source", required=True, choices=("moewalls", "motionbgs", "dareful"))
    download.add_argument("--title", default="Wallpaper")
    catalogs.add_parser("downloaded")
    terminal = commands.add_parser("terminal", help="Discover and run terminal wallpapers")
    terminals = terminal.add_subparsers(dest="terminal_action", required=True)
    listing = terminals.add_parser("list")
    listing.add_argument("query", nargs="?", default="")
    launch = terminals.add_parser("start")
    selection = launch.add_mutually_exclusive_group(required=True)
    selection.add_argument("--preset")
    selection.add_argument("--command")
    for key, default in (("columns", 100), ("rows", 30), ("font-size", 16), ("fps", 20)):
        launch.add_argument("--" + key, type=int, default=default)
    launch.add_argument("--background", default="#0b0f16")
    launch.add_argument("--foreground", default="#dce6f2")
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
        elif action == "catalog":
            from .catalog import SOURCES, Catalog, Wallpaper

            catalog = Catalog(paths)
            if args.catalog_action == "sources":
                output = SOURCES
            elif args.catalog_action == "search":
                output = asdict(catalog.page(args.source, args.query, args.page))
            elif args.catalog_action == "download":

                def progress(received, total):
                    print(
                        f"\r{received / 1024 / 1024:.1f} MB"
                        + (f" / {total / 1024 / 1024:.1f} MB" if total else ""),
                        end="",
                        file=sys.stderr,
                        flush=True,
                    )

                item = Wallpaper(args.source, args.title, args.page_url)
                path = catalog.download(item, progress=progress)
                print(file=sys.stderr)
                output = {"path": str(path)}
            else:
                output = [
                    {**asdict(item), "path": str(path)} for item, path in catalog.downloaded()
                ]
        elif action == "terminal":
            from .terminal_config import TerminalConfig, programs

            if args.terminal_action == "list":
                output = programs(args.query)
            else:
                appearance = {
                    key: getattr(args, key)
                    for key in (
                        "columns",
                        "rows",
                        "font_size",
                        "fps",
                        "background",
                        "foreground",
                    )
                }
                config = (
                    TerminalConfig.from_preset(args.preset, **appearance)
                    if args.preset
                    else TerminalConfig.from_command(args.command, **appearance)
                )
                output = client.request("terminal-start", config=config.to_dict())
        elif action == "restore":
            settings = store.load()
            if not desktop.autostart_enabled():
                return 0
            restore_terminal = settings.restore_kind == "terminal" and settings.restore_terminal
            if not restore_terminal and not settings.restore:
                return 0
            # Duplicate autostart delivery must not restart or unpause a running session.
            if client.request("status")["running"]:
                return 0
            output = (
                client.request("terminal-start", config=settings.restore_terminal)
                if restore_terminal
                else client.request("start", media=settings.restore)
            )
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
    except KeyboardInterrupt:
        print("\nAuraFlow: cancelled.", file=sys.stderr)
        return 130
    except (AuraFlowError, OSError) as exc:
        print(f"AuraFlow: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
