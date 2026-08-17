#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODE_PROJECT="$ROOT_DIR/macOSApp/AuraFlowWallpaperExtensionXcode/AuraFlowWallpaperExtension.xcodeproj"
BUNDLE_NAME="AuraFlowWallpaperExtension.appex"
TARGET_NAME="AuraFlowWallpaperExtension"

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

[[ -d "$XCODE_PROJECT" ]] || fail "Xcode project is missing: $XCODE_PROJECT"

for command_name in xcodebuild codesign; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "required command not found: $command_name"
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/auraflow-wallpaper-extension.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  SIGNING_IDENTITY="$CODESIGN_IDENTITY"
else
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | awk -F'\"' '/Apple Development:/ {print $2; exit}')"
  SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
fi
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-8CNCVLS7WN}"

XCODEBUILD_ARGS=(
  -project "$XCODE_PROJECT"
  -target "$TARGET_NAME"
  -configuration Release
  CONFIGURATION_BUILD_DIR="$WORK_DIR/Products"
  SYMROOT="$WORK_DIR/SymRoot"
  OBJROOT="$WORK_DIR/ObjRoot"
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
)

XCODEBUILD_ARGS+=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-)

XCODEBUILD_ARGS+=(build)

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcodebuild "${XCODEBUILD_ARGS[@]}"

BUILT_BUNDLE="$WORK_DIR/Products/$BUNDLE_NAME"
[[ -d "$BUILT_BUNDLE" ]] || fail "Xcode did not produce $BUILT_BUNDLE"

EXTENSION_ENTITLEMENTS="$ROOT_DIR/macOSApp/Sources/AuraFlowWallpaperExtension/AuraFlowWallpaperExtension.entitlements"
codesign --force --options runtime --timestamp=none \
  --entitlements "$EXTENSION_ENTITLEMENTS" \
  --sign "$SIGNING_IDENTITY" "$BUILT_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$BUILT_BUNDLE"

FINAL_BUNDLE="$OUTPUT_DIR/$BUNDLE_NAME"
if [[ -e "$FINAL_BUNDLE" ]]; then
  rm -rf "$FINAL_BUNDLE"
fi
mv "$BUILT_BUNDLE" "$FINAL_BUNDLE"

printf '[wallpaper-extension] created %s\n' "$FINAL_BUNDLE"
printf '[wallpaper-extension] provider com.andrijvergeles.auraflow.wallpaper-extension\n'
