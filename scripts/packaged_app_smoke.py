#!/usr/bin/env python3
"""Check a relocated app's resources and startup, including Rosetta slices."""

import argparse
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import time


BUNDLE_NAME = "WallpaperControlApp_WallpaperControlApp.bundle"


def resource_check(app: Path, architecture: str) -> subprocess.CompletedProcess:
    # This diagnostic exits before constructing wallpaper controllers. Launch
    # the actual GUI separately through LaunchServices below.
    return subprocess.run(
        ["/usr/bin/arch", f"-{architecture}",
         str(app / "Contents/MacOS/WallpaperControlApp"), "--verify-resources"],
        cwd="/", capture_output=True, text=True, timeout=30,
    )


def require_resource_failure(app: Path, architecture: str, cause: str) -> None:
    result = resource_check(app, architecture)
    if result.returncode != 1 or cause not in result.stderr or "copy the entire AuraFlow.app" not in result.stderr:
        raise RuntimeError(f"Incomplete app did not report a repairable error: {result}")
    if "Fatal error" in result.stderr or ".build/" in result.stderr:
        raise RuntimeError(f"Incomplete app invoked the SwiftPM fallback: {result.stderr}")


def app_pids(app: Path) -> list[int]:
    binary = str(app / "Contents/MacOS/WallpaperControlApp")
    processes = subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True)
    result = []
    for line in processes.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and (parts[1] == binary or parts[1].startswith(binary + " ")):
            result.append(int(parts[0]))
    return result


def launch_check(app: Path, architecture: str) -> None:
    try:
        subprocess.run(["/usr/bin/open", "-n", "--arch", architecture, str(app)], check=True, timeout=30)
        deadline = time.monotonic() + 15
        while not app_pids(app):
            if time.monotonic() >= deadline:
                raise RuntimeError(f"{architecture}: AuraFlow exited before startup completed")
            time.sleep(0.2)
        # Detect the delayed resource crash triggered by initial view models,
        # rather than merely accepting open(1)'s successful handoff.
        for _ in range(25):
            if not app_pids(app):
                raise RuntimeError(f"{architecture}: AuraFlow crashed during startup")
            time.sleep(0.2)
    finally:
        # Only stop the relocated test copy, never the user's installed app.
        pids = app_pids(app)
        for pid in pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 5
        while app_pids(app) and time.monotonic() < deadline:
            time.sleep(0.1)
        if app_pids(app):
            raise RuntimeError("The relocated smoke-test app did not terminate")


def verify(source: Path, architectures: list[str], launch: bool) -> None:
    with tempfile.TemporaryDirectory(prefix="AuraFlow installed smoke ") as directory:
        # LaunchServices reports canonical paths (/private/var on macOS).
        app = Path(directory).resolve() / "AuraFlow.app"
        subprocess.run(["/usr/bin/ditto", str(source), str(app)], check=True)
        resources = app / "Contents/Resources" / BUNDLE_NAME
        if not resources.is_dir() or (app / BUNDLE_NAME).exists():
            raise RuntimeError("Expected one resource bundle in Contents/Resources")
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        for architecture in architectures:
            result = resource_check(app, architecture)
            if result.returncode:
                raise RuntimeError(f"{architecture}: resource check failed: {result.stderr}")
            report = json.loads(result.stdout)
            if report.get("architecture") != architecture:
                raise RuntimeError(f"Wrong executable slice: {report}")
            if Path(report.get("resourceBundlePath", "")).resolve() != resources.resolve():
                raise RuntimeError(f"App loaded resources outside Contents/Resources: {report}")

            hidden = Path(directory) / BUNDLE_NAME
            resources.rename(hidden)
            try:
                require_resource_failure(app, architecture, "resources are missing")
            finally:
                hidden.rename(resources)

            resource = resources / "Contents/Resources/desktophut-api.json"
            if not resource.exists():
                resource = resources / "desktophut-api.json"
            original = resource.read_bytes()
            try:
                resource.unlink()
                require_resource_failure(app, architecture, "desktophut-api.json is missing")
                resource.write_text("damaged JSON")
                require_resource_failure(app, architecture, "unreadable or damaged")
            finally:
                resource.write_bytes(original)

            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
            if launch:
                launch_check(app, architecture)
            print(f"PASS {architecture}: embedded resources, missing/damaged resources"
                  + (", GUI startup" if launch else ""), flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--arch", action="append", choices=["arm64", "x86_64"])
    parser.add_argument("--launch", action="store_true", help="Also open the GUI in a dedicated test session")
    args = parser.parse_args()
    verify(args.bundle.resolve(), args.arch or [platform.machine()], args.launch)


if __name__ == "__main__":
    main()
