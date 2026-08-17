#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PROCESS_NAME="WallpaperControlApp"
APP_NAME="AuraFlow"
BUNDLE_ID="com.andrijvergeles.auraflow"
APP_VERSION="1.3.1"
APP_BUILD="10"
MIN_SYSTEM_VERSION="13.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$ROOT_DIR/macOSApp"
APP_BUNDLE="$ROOT_DIR/.build/codex-run/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_PLUGINS="$APP_CONTENTS/PlugIns"
APP_EXTENSIONS="$APP_CONTENTS/Extensions"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
HELPER_NAME="AuraWallpaperAgent"

SWIFT_BIN="${AURAFLOW_SWIFT_BIN:-swift}"
SWIFT_ARGS=()
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
if [[ -x "$XCODE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ]]; then
  export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
  SWIFT_BIN="$XCODE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
  SWIFT_ARGS=(--sdk "$XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk")
fi

pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

pushd "$SWIFT_DIR" >/dev/null
"$SWIFT_BIN" build "${SWIFT_ARGS[@]}"
BUILD_DIR="$("$SWIFT_BIN" build "${SWIFT_ARGS[@]}" --show-bin-path)"
popd >/dev/null

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_PLUGINS" "$APP_EXTENSIONS"
cp "$BUILD_DIR/$PROCESS_NAME" "$APP_BINARY"
cp "$BUILD_DIR/$HELPER_NAME" "$APP_MACOS/$HELPER_NAME"
chmod +x "$APP_BINARY" "$APP_MACOS/$HELPER_NAME"

RESOURCE_BUNDLE="$BUILD_DIR/${PROCESS_NAME}_${PROCESS_NAME}.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/$(basename "$RESOURCE_BUNDLE")"
fi
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
fi

AURAFLOW_VERSION="$APP_VERSION" \
AURAFLOW_BUILD="$APP_BUILD" \
BUILD_UNIVERSAL=0 \
  "$ROOT_DIR/scripts/build_screensaver.sh" "$APP_PLUGINS"

AURAFLOW_VERSION="$APP_VERSION" \
AURAFLOW_BUILD="$APP_BUILD" \
  "$ROOT_DIR/scripts/build_wallpaper_extension.sh" "$APP_EXTENSIONS"

cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$PROCESS_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_MACOS/$HELPER_NAME"
codesign --force --sign - "$APP_BINARY"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    expected_command="$APP_BINARY"
    verified_pid=""
    for _ in {1..30}; do
      while IFS= read -r candidate_pid; do
        candidate_command="$(ps -p "$candidate_pid" -o command= 2>/dev/null || true)"
        if [[ "$candidate_command" == "$expected_command" ]]; then
          verified_pid="$candidate_pid"
          break
        fi
      done < <(pgrep -x "$PROCESS_NAME" || true)
      [[ -n "$verified_pid" ]] && break
      sleep 0.1
    done
    if [[ -z "$verified_pid" ]]; then
      echo "Expected process is not running: $expected_command" >&2
      pgrep -x "$PROCESS_NAME" | while IFS= read -r candidate_pid; do
        ps -p "$candidate_pid" -o pid=,command= >&2
      done
      exit 1
    fi
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
