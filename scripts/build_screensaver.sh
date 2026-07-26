#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/macOSApp/Sources/AuraFlowLockScreenSaver"
BUNDLE_NAME="AuraFlowLockScreen.saver"
EXECUTABLE_NAME="AuraFlowLockScreen"
MINIMUM_MACOS="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
BUILD_UNIVERSAL="${BUILD_UNIVERSAL:-0}"
REQUIRE_UNIVERSAL="${REQUIRE_UNIVERSAL:-0}"
APP_VERSION="${AURAFLOW_VERSION:-1.3.0}"
APP_BUILD="${AURAFLOW_BUILD:-9}"

usage() {
  printf 'Usage: %s OUTPUT_DIR [VIDEO_PATH] [FALLBACK_FRAME_PATH] [CONFIG_PATH]\n' "$0"
  printf 'Set BUILD_UNIVERSAL=1 to attempt an arm64+x86_64 executable.\n'
}

fail() {
  printf '[screensaver] error: %s\n' "$1" >&2
  exit 1
}

log() {
  printf '[screensaver] %s\n' "$1"
}

if [[ $# -lt 1 || $# -gt 4 ]]; then
  usage >&2
  exit 2
fi

OUTPUT_DIR="$1"
VIDEO_PATH="${2:-}"
FALLBACK_FRAME_PATH="${3:-}"
CONFIG_PATH="${4:-}"

for command_name in xcrun plutil codesign file lipo; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "required command not found: $command_name"
done

[[ -f "$SOURCE_DIR/AuraFlowLockScreen.m" ]] ||
  fail "source file is missing"
[[ -f "$SOURCE_DIR/AuraFlowLockScreenConfig.json" ]] ||
  fail "default configuration is missing"
[[ -z "$VIDEO_PATH" || -f "$VIDEO_PATH" ]] ||
  fail "video does not exist: $VIDEO_PATH"
[[ -z "$FALLBACK_FRAME_PATH" || -f "$FALLBACK_FRAME_PATH" ]] ||
  fail "fallback frame does not exist: $FALLBACK_FRAME_PATH"
[[ -z "$CONFIG_PATH" || -f "$CONFIG_PATH" ]] ||
  fail "configuration does not exist: $CONFIG_PATH"

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
FINAL_BUNDLE="$OUTPUT_DIR/$BUNDLE_NAME"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/auraflow-screensaver.XXXXXX")"
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
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>AuraFlow Lock Screen</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>com.andrijvergeles.auraflow.lockscreen-saver</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AuraFlowLockScreen</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${APP_BUILD}</string>
  <key>LSMinimumSystemVersion</key>
  <string>${MINIMUM_MACOS}</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>AuraFlowLockScreen</string>
</dict>
</plist>
PLIST

CONFIG_OUTPUT="$RESOURCES_DIR/AuraFlowLockScreenConfig.json"
if [[ -n "$CONFIG_PATH" ]]; then
  plutil -convert json -o "$CONFIG_OUTPUT" -- "$CONFIG_PATH" ||
    fail "configuration is not a JSON-compatible dictionary"
else
  cp "$SOURCE_DIR/AuraFlowLockScreenConfig.json" "$CONFIG_OUTPUT"
fi

ensure_config_key() {
  local key="$1"
  local value="$2"
  if ! plutil -extract "$key" raw "$CONFIG_OUTPUT" >/dev/null 2>&1; then
    plutil -insert "$key" -string "$value" "$CONFIG_OUTPUT"
  fi
}

ensure_config_key video_file ""
ensure_config_key fallback_frame_file ""
ensure_config_key scale_mode "fill"

if [[ -n "$VIDEO_PATH" ]]; then
  video_name="$(basename "$VIDEO_PATH")"
  mkdir -p "$RESOURCES_DIR/Media/Video"
  cp "$VIDEO_PATH" "$RESOURCES_DIR/Media/Video/$video_name"
  plutil -replace video_file -string "Media/Video/$video_name" "$CONFIG_OUTPUT"
fi

if [[ -n "$FALLBACK_FRAME_PATH" ]]; then
  fallback_name="$(basename "$FALLBACK_FRAME_PATH")"
  mkdir -p "$RESOURCES_DIR/Media/Fallback"
  cp "$FALLBACK_FRAME_PATH" "$RESOURCES_DIR/Media/Fallback/$fallback_name"
  plutil -replace fallback_frame_file \
    -string "Media/Fallback/$fallback_name" "$CONFIG_OUTPUT"
fi

scale_mode="$(plutil -extract scale_mode raw "$CONFIG_OUTPUT" 2>/dev/null || true)"
case "$scale_mode" in
  fill | fit | stretch) ;;
  *)
    log "normalizing unsupported scale_mode '$scale_mode' to fill"
    plutil -replace scale_mode -string fill "$CONFIG_OUTPUT"
    ;;
esac
plutil -convert json "$CONFIG_OUTPUT"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64 | x86_64) ;;
  *) fail "unsupported host architecture: $HOST_ARCH" ;;
esac

compile_architecture() {
  local architecture="$1"
  local output="$2"
  "$CLANG" \
    -x objective-c \
    -fobjc-arc \
    -fmodules \
    -Wall \
    -Wextra \
    -Wno-deprecated-declarations \
    -arch "$architecture" \
    -isysroot "$SDK_PATH" \
    -mmacosx-version-min="$MINIMUM_MACOS" \
    -I"$SOURCE_DIR" \
    -bundle \
    -framework AppKit \
    -framework AVFoundation \
    -framework QuartzCore \
    -framework ScreenSaver \
    "$SOURCE_DIR/AuraFlowLockScreen.m" \
    -o "$output"
}

ARCHITECTURES=("$HOST_ARCH")
if [[ "$BUILD_UNIVERSAL" == "1" ]]; then
  if [[ "$HOST_ARCH" == "arm64" ]]; then
    OPTIONAL_ARCH="x86_64"
  else
    OPTIONAL_ARCH="arm64"
  fi

  OPTIONAL_OUTPUT="$WORK_DIR/$EXECUTABLE_NAME.$OPTIONAL_ARCH"
  if compile_architecture "$OPTIONAL_ARCH" "$OPTIONAL_OUTPUT" \
    >"$WORK_DIR/optional-architecture.log" 2>&1; then
    ARCHITECTURES+=("$OPTIONAL_ARCH")
    log "universal build supports $HOST_ARCH and $OPTIONAL_ARCH"
  else
    if [[ "$REQUIRE_UNIVERSAL" == "1" ]]; then
      fail "failed to build required $OPTIONAL_ARCH screen saver slice"
    fi
    log "$OPTIONAL_ARCH toolchain support is unavailable; building $HOST_ARCH only"
  fi
fi

HOST_OUTPUT="$WORK_DIR/$EXECUTABLE_NAME.$HOST_ARCH"
compile_architecture "$HOST_ARCH" "$HOST_OUTPUT"

EXECUTABLE_PATH="$MACOS_DIR/$EXECUTABLE_NAME"
if [[ ${#ARCHITECTURES[@]} -eq 2 ]]; then
  lipo -create \
    "$HOST_OUTPUT" \
    "$WORK_DIR/$EXECUTABLE_NAME.$OPTIONAL_ARCH" \
    -output "$EXECUTABLE_PATH"
else
  cp "$HOST_OUTPUT" "$EXECUTABLE_PATH"
fi
chmod 0755 "$EXECUTABLE_PATH"

plutil -lint "$CONTENTS_DIR/Info.plist"
plutil -convert xml1 -o "$WORK_DIR/config-validation.plist" -- "$CONFIG_OUTPUT"
plutil -lint "$WORK_DIR/config-validation.plist"
[[ "$(plutil -extract CFBundlePackageType raw "$CONTENTS_DIR/Info.plist")" == "BNDL" ]] ||
  fail "CFBundlePackageType must be BNDL"
[[ "$(plutil -extract NSPrincipalClass raw "$CONTENTS_DIR/Info.plist")" == \
  "AuraFlowLockScreen" ]] ||
  fail "NSPrincipalClass is incorrect"

codesign --force --sign - --timestamp=none "$STAGED_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$STAGED_BUNDLE"
file "$EXECUTABLE_PATH"

if [[ -e "$FINAL_BUNDLE" ]]; then
  rm -rf "$FINAL_BUNDLE"
fi
mv "$STAGED_BUNDLE" "$FINAL_BUNDLE"

log "created $FINAL_BUNDLE"
log "architectures: $(lipo -archs "$FINAL_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME")"
