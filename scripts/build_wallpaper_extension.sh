#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/macOSApp/Sources/AuraFlowWallpaperExtension"
BUNDLE_NAME="AuraFlowWallpaperExtension.appex"
EXECUTABLE_NAME="AuraFlowWallpaperExtension"
BUNDLE_ID="com.andrijvergeles.auraflow.wallpaper-extension"
MINIMUM_MACOS="26.0"
APP_VERSION="${AURAFLOW_VERSION:-1.3.1}"
APP_BUILD="${AURAFLOW_BUILD:-10}"

usage() {
  printf 'Usage: %s OUTPUT_DIR\n' "$0"
}

fail() {
  printf '[wallpaper-extension] error: %s\n' "$1" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

OUTPUT_DIR="$1"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

[[ -d "$SOURCE_DIR" ]] || fail "source directory is missing: $SOURCE_DIR"
[[ -f "$SOURCE_DIR/WallpaperExtension-Bridging-Header.h" ]] ||
  fail "bridging header is missing"

for command_name in xcrun plutil codesign file; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "required command not found: $command_name"
done

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="${AURAFLOW_SWIFTC:-$(xcrun --find swiftc)}"
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64 | x86_64) ;;
  *) fail "unsupported host architecture: $HOST_ARCH" ;;
esac

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/auraflow-wallpaper-extension.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

STAGED_BUNDLE="$WORK_DIR/$BUNDLE_NAME"
CONTENTS_DIR="$STAGED_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cat >"$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>AuraFlow Wallpaper</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>AuraFlowWallpaperExtension</string>
  <key>CFBundlePackageType</key>
  <string>XPC!</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>EXAppExtensionAttributes</key>
  <dict>
    <key>EXExtensionPointIdentifier</key>
    <string>com.apple.wallpaper</string>
  </dict>
  <key>LSMinimumSystemVersion</key>
  <string>$MINIMUM_MACOS</string>
</dict>
</plist>
PLIST

"$SWIFTC" \
  -sdk "$SDK_PATH" \
  -target "$HOST_ARCH-apple-macosx$MINIMUM_MACOS" \
  -swift-version 6 \
  -parse-as-library \
  -import-objc-header "$SOURCE_DIR/WallpaperExtension-Bridging-Header.h" \
  -framework AppKit \
  -framework AVFoundation \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework ExtensionFoundation \
  -framework ImageIO \
  -framework IOKit \
  -framework IOSurface \
  -framework QuartzCore \
  -framework Security \
  -framework VideoToolbox \
  "$SOURCE_DIR"/*.swift \
  -o "$MACOS_DIR/$EXECUTABLE_NAME"
chmod 0755 "$MACOS_DIR/$EXECUTABLE_NAME"

plutil -lint "$CONTENTS_DIR/Info.plist"
codesign --force --sign - --timestamp=none "$STAGED_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$STAGED_BUNDLE"
file "$MACOS_DIR/$EXECUTABLE_NAME"

FINAL_BUNDLE="$OUTPUT_DIR/$BUNDLE_NAME"
if [[ -e "$FINAL_BUNDLE" ]]; then
  rm -rf "$FINAL_BUNDLE"
fi
mv "$STAGED_BUNDLE" "$FINAL_BUNDLE"

printf '[wallpaper-extension] created %s\n' "$FINAL_BUNDLE"
printf '[wallpaper-extension] provider %s\n' "$BUNDLE_ID"
