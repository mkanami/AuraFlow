#!/usr/bin/env python3
"""Verify portable macOS targets and private-framework isolation in CI."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


PRIVATE_FRAMEWORK_PATTERN = re.compile(
    r"/(?:Wallpaper|WallpaperTypes)\.framework(?:/|$)"
)
PRIVATE_IMPORT_PATTERN = re.compile(
    r"^\s*(?:@preconcurrency\s+)?import\s+(?:Wallpaper|WallpaperTypes)\b",
    re.MULTILINE,
)


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def run(command: list[str], *, cwd: Path | None = None) -> str:
    result = subprocess.run(
        command,
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        details = result.stderr.strip() or result.stdout.strip()
        fail(f"{' '.join(command)} failed{': ' + details if details else ''}")
    return result.stdout


def parse_version(value: str) -> tuple[int, ...]:
    try:
        return tuple(int(component) for component in value.split("."))
    except ValueError:
        fail(f"invalid macOS version reported by otool: {value}")


def deployment_versions(binary: Path) -> list[str]:
    output = run(["otool", "-l", str(binary)])
    versions = re.findall(r"^\s*minos\s+([0-9]+(?:\.[0-9]+){0,2})\s*$", output, re.MULTILINE)
    if versions:
        return versions

    legacy_versions = re.findall(
        r"cmd\s+LC_VERSION_MIN_MACOSX[\s\S]*?^\s*version\s+([0-9]+(?:\.[0-9]+){0,2})\s*$",
        output,
        re.MULTILINE,
    )
    return legacy_versions


def verify_deployment_target(binary_name: str, binary: Path, expected_major: int) -> None:
    versions = deployment_versions(binary)
    if not versions:
        fail(f"could not find a macOS deployment load command in {binary}")

    for version in versions:
        if parse_version(version)[0] != expected_major:
            fail(
                f"{binary_name} has deployment target {version}; "
                f"expected macOS {expected_major}.x ({binary})"
            )
    print(f"{binary_name}: macOS {expected_major}.x deployment target ({', '.join(versions)})")


def verify_no_private_linkage(binary_name: str, binary: Path) -> None:
    output = run(["otool", "-L", str(binary)])
    matches = sorted(set(PRIVATE_FRAMEWORK_PATTERN.findall(output)))
    if matches:
        fail(f"{binary_name} links private Wallpaper frameworks: {', '.join(matches)}")
    print(f"{binary_name}: no private Wallpaper framework linkage")


def verify_source_imports(source_root: Path) -> None:
    if not source_root.is_dir():
        fail(f"source root does not exist: {source_root}")

    for source_file in sorted(source_root.rglob("*.swift")):
        contents = source_file.read_text(encoding="utf-8")
        if PRIVATE_IMPORT_PATTERN.search(contents):
            fail(f"private Wallpaper import found outside native bridge: {source_file}")
    print(f"{source_root}: no private Wallpaper imports")


def verify_package_scope(package_directory: Path) -> None:
    package = json.loads(run(["swift", "package", "dump-package"], cwd=package_directory))
    targets = package.get("targets", [])
    if not targets:
        fail("swift package dump-package returned no targets")

    for target in targets:
        target_name = target.get("name", "<unnamed>")
        settings = json.dumps(target.get("settings", []), sort_keys=True)
        if target_name != "AuraWallpaperNativeBridge" and re.search(
            r"Wallpaper(?:Types)?", settings
        ):
            fail(
                f"private Wallpaper linker/module settings are scoped to "
                f"{target_name}, not AuraWallpaperNativeBridge"
            )
    print("Package settings: private Wallpaper flags are scoped to AuraWallpaperNativeBridge")


def parse_binary(value: str) -> tuple[str, Path]:
    name, separator, path = value.partition("=")
    if not separator or not name or not path:
        fail(f"--binary must use NAME=PATH, got: {value}")
    binary = Path(path)
    if not binary.is_file() or not binary.stat().st_mode & 0o111:
        fail(f"binary is missing or not executable: {binary}")
    return name, binary


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--package-directory", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, action="append", default=[])
    parser.add_argument("--binary", action="append", default=[])
    parser.add_argument("--deployment-major", type=int)
    args = parser.parse_args()

    package_directory = args.package_directory.resolve()
    if not package_directory.is_dir():
        fail(f"package directory does not exist: {package_directory}")

    verify_package_scope(package_directory)
    for source_root in args.source_root:
        verify_source_imports((package_directory / source_root).resolve())

    for binary_value in args.binary:
        binary_name, binary = parse_binary(binary_value)
        verify_no_private_linkage(binary_name, binary)
        if args.deployment_major is not None:
            verify_deployment_target(binary_name, binary, args.deployment_major)


if __name__ == "__main__":
    main()
