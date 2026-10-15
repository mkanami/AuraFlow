#!/usr/bin/env python3
"""Reject development-machine dependencies in optional bundled media tools."""
import argparse
from pathlib import Path
import subprocess


def verify(bundle: Path, universal: bool) -> None:
    directory = bundle / "Contents/Resources/BundledTools"
    for name in ("ffmpeg", "ffprobe"):
        tool = directory / name
        if not tool.exists():
            continue
        if universal:
            subprocess.run(["lipo", "-verify_arch", "arm64", "x86_64", str(tool)], check=True)
        # Standalone tools may use system libraries. Copying a Homebrew binary
        # alone leaves references to that builder's Cellar and cannot ship.
        output = subprocess.check_output(["otool", "-L", str(tool)], text=True)
        for line in output.splitlines():
            if " (compatibility version " not in line:
                continue
            dependency = line.split(" (compatibility version ", 1)[0].strip()
            if dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            raise RuntimeError(
                f"{name} depends on {dependency}. Supply a standalone portable binary; "
                "a Homebrew executable without its libraries cannot be distributed. "
                "FFMPEG_RUNTIME_BUNDLING=0 keeps media tools as a user-installed dependency."
            )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--universal", action="store_true")
    args = parser.parse_args()
    verify(args.bundle, args.universal)
