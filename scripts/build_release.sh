#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$ROOT_DIR/macOSApp"
DIST_DIR="$ROOT_DIR/dist"
APP_TARGET="WallpaperControlApp"
HELPER_TARGET="AuraWallpaperAgent"
APP_DISPLAY_NAME="AuraFlow"
APP_VERSION="${AURAFLOW_VERSION:-1.2.2}"
APP_BUILD="${AURAFLOW_BUILD:-4}"
APP_BUNDLE="$DIST_DIR/${APP_DISPLAY_NAME}.app"
APP_ZIP="$DIST_DIR/${APP_DISPLAY_NAME}.zip"
APP_DMG="$DIST_DIR/${APP_DISPLAY_NAME}.dmg"
ICON_PNG="$ROOT_DIR/Resources/AppIcon.png"
ICON_ICNS="$ROOT_DIR/Resources/AppIcon.icns"
BUILD_UNIVERSAL="${BUILD_UNIVERSAL:-1}"
LOCK_DIR="$ROOT_DIR/.build-lock"
BUNDLED_TOOLS_DIR="$APP_BUNDLE/Contents/Resources/BundledTools"

log() {
  printf '[build] %s\n' "$1"
}

ensure_xcode_toolchain() {
  local current_dev_dir=""
  current_dev_dir="$(xcode-select -p 2>/dev/null || true)"

  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    log "Using DEVELOPER_DIR=$DEVELOPER_DIR"
    return
  fi

  if [[ "$current_dev_dir" == "/Library/Developer/CommandLineTools" ]] && [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    log "Switched build toolchain to Xcode SDK at $DEVELOPER_DIR"
    return
  fi

  if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    log "Using Xcode SDK at $DEVELOPER_DIR"
  fi
}

cleanup_lock() {
  rm -rf "$LOCK_DIR"
}

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Another build is already running. Stop it first or remove $LOCK_DIR"
    exit 1
  fi
  trap cleanup_lock EXIT
}

plist_set_string() {
  local plist="$1"
  local key="$2"
  local value="$3"
  /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "$plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "$plist"
}

plist_set_bool() {
  local plist="$1"
  local key="$2"
  local value="$3"
  /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "$plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :${key} bool ${value}" "$plist"
}

ensure_icon() {
  if [[ -f "$ICON_ICNS" ]]; then
    return
  fi

  if [[ ! -f "$ICON_PNG" ]]; then
    log "Icon not found. Place AppIcon.png or AppIcon.icns under Resources/ before building."
    exit 1
  fi

  if ! command -v iconutil >/dev/null 2>&1; then
    log "iconutil not available. Install Xcode command line tools."
    exit 1
  fi

  tmpdir="$(mktemp -d)"
  iconset="$tmpdir/AppIcon.iconset"
  mkdir -p "$iconset"

  for size in 16 32 64 128 256 512; do
    for scale in 1 2; do
      scaled=$((size * scale))
      name="icon_${size}x${size}"
      if [[ "$scale" -eq 2 ]]; then
        name+="@2x"
      fi
      sips -z "$scaled" "$scaled" "$ICON_PNG" --out "$iconset/${name}.png" >/dev/null
    done
  done

  iconutil -c icns "$iconset" -o "$ICON_ICNS"
  rm -rf "$tmpdir"
  log "Generated AppIcon.icns from AppIcon.png"
}

prepare_environment() {
  rm -rf "$DIST_DIR"
  mkdir -p "$DIST_DIR"
}

resolve_tool_path() {
  local env_var_name="$1"
  local tool_name="$2"
  local env_value="${!env_var_name:-}"

  if [[ -n "$env_value" && -x "$env_value" ]]; then
    printf '%s\n' "$env_value"
    return 0
  fi

  local candidate
  for candidate in \
    "/opt/homebrew/bin/${tool_name}" \
    "/usr/local/bin/${tool_name}" \
    "/usr/bin/${tool_name}"
  do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v "$tool_name" >/dev/null 2>&1; then
    command -v "$tool_name"
    return 0
  fi

  return 1
}

build_swift_app() {
  log "Building Swift target"
  pushd "$SWIFT_DIR" >/dev/null
  swift build -c release

  local arm_binary="$SWIFT_DIR/.build/arm64-apple-macosx/release/${APP_TARGET}"
  local arm_helper="$SWIFT_DIR/.build/arm64-apple-macosx/release/${HELPER_TARGET}"
  local x86_binary="$SWIFT_DIR/.build/x86_64-apple-macosx/release/${APP_TARGET}"
  local x86_helper="$SWIFT_DIR/.build/x86_64-apple-macosx/release/${HELPER_TARGET}"
  local universal_dir="$SWIFT_DIR/.build/universal"
  local built_x86="0"

  if [[ "$BUILD_UNIVERSAL" == "1" ]] && command -v arch >/dev/null 2>&1; then
    log "Building x86_64 slice (Rosetta may be required)"
    if arch -x86_64 swift build -c release; then
      log "Built x86_64 slice"
      built_x86="1"
    else
      log "[warn] Failed to build x86_64 slice. Using arm64 only."
    fi
  elif [[ "$BUILD_UNIVERSAL" != "1" ]]; then
    log "Skipping x86_64 build (BUILD_UNIVERSAL=$BUILD_UNIVERSAL)"
  else
    log "[warn] 'arch' command not found; building arm64 slice only."
  fi

  local bin_path
  local helper_path
  if [[ "$built_x86" == "1" && -f "$arm_binary" && -f "$x86_binary" && -f "$arm_helper" && -f "$x86_helper" ]]; then
    mkdir -p "$universal_dir"
    lipo -create -output "$universal_dir/${APP_TARGET}" "$arm_binary" "$x86_binary"
    lipo -create -output "$universal_dir/${HELPER_TARGET}" "$arm_helper" "$x86_helper"
    bin_path="$universal_dir"
    helper_path="$universal_dir/${HELPER_TARGET}"
    log "Created universal binary"
  elif [[ -f "$arm_binary" ]]; then
    bin_path="$(dirname "$arm_binary")"
    helper_path="$bin_path/${HELPER_TARGET}"
  else
    bin_path=$(swift build -c release --show-bin-path)
    helper_path="$bin_path/${HELPER_TARGET}"
  fi
  popd >/dev/null

  local binary="$bin_path/${APP_TARGET}"
  local resources_bundle="$bin_path/${APP_TARGET}_${APP_TARGET}.bundle"

  if [[ ! -x "$binary" ]]; then
    log "Не найден бинарник ($binary)"
    exit 1
  fi
  if [[ ! -x "$helper_path" ]]; then
    log "Не найден helper binary ($helper_path)"
    exit 1
  fi

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_BUNDLE/Contents/MacOS"
  mkdir -p "$APP_BUNDLE/Contents/Resources"

  cp "$binary" "$APP_BUNDLE/Contents/MacOS/${APP_TARGET}"
  cp "$helper_path" "$APP_BUNDLE/Contents/MacOS/${HELPER_TARGET}"
  chmod +x "$APP_BUNDLE/Contents/MacOS/${APP_TARGET}"
  chmod +x "$APP_BUNDLE/Contents/MacOS/${HELPER_TARGET}"

  if [[ -d "$resources_bundle" ]]; then
    cp -R "$resources_bundle" "$APP_BUNDLE/Contents/Resources/${APP_TARGET}.bundle"
  fi

  cat > "$APP_BUNDLE/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>WallpaperControlApp</string>
  <key>CFBundleIdentifier</key>
  <string>com.andrijvergeles.auraflow</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>AuraFlow</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
</dict>
</plist>
EOF
}

apply_plist_customizations() {
  local plist="$APP_BUNDLE/Contents/Info.plist"
  plist_set_string "$plist" CFBundleName "$APP_DISPLAY_NAME"
  plist_set_string "$plist" CFBundleDisplayName "$APP_DISPLAY_NAME"
  plist_set_string "$plist" CFBundleIdentifier "com.andrijvergeles.auraflow"
  plist_set_string "$plist" CFBundleShortVersionString "$APP_VERSION"
  plist_set_string "$plist" CFBundleVersion "$APP_BUILD"
  ensure_icon
  cp "$ICON_ICNS" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
  plist_set_string "$plist" CFBundleIconFile "AppIcon"
}

bundle_runtime_tools() {
  mkdir -p "$BUNDLED_TOOLS_DIR"

  local ffmpeg_path=""
  local ffprobe_path=""

  if ffmpeg_path="$(resolve_tool_path AURAFLOW_FFMPEG_PATH ffmpeg 2>/dev/null)"; then
    cp "$ffmpeg_path" "$BUNDLED_TOOLS_DIR/ffmpeg"
    chmod +x "$BUNDLED_TOOLS_DIR/ffmpeg"
    log "Bundled ffmpeg from $ffmpeg_path"
  else
    log "ffmpeg not found; compatibility transcodes will use system ffmpeg only."
  fi

  if ffprobe_path="$(resolve_tool_path AURAFLOW_FFPROBE_PATH ffprobe 2>/dev/null)"; then
    cp "$ffprobe_path" "$BUNDLED_TOOLS_DIR/ffprobe"
    chmod +x "$BUNDLED_TOOLS_DIR/ffprobe"
    log "Bundled ffprobe from $ffprobe_path"
  else
    log "ffprobe not found; continuing without bundled ffprobe."
  fi

  if [[ -z "$(ls -A "$BUNDLED_TOOLS_DIR" 2>/dev/null)" ]]; then
    rmdir "$BUNDLED_TOOLS_DIR" 2>/dev/null || true
  fi
}

package_distribution() {
  log "Создание ZIP архива"
  pushd "$DIST_DIR" >/dev/null
  ditto -c -k --keepParent "${APP_DISPLAY_NAME}.app" "$(basename "$APP_ZIP")"
  popd >/dev/null

  log "Создание DMG"
  local dmg_stage="$DIST_DIR/.dmg-stage"
  rm -rf "$dmg_stage"
  mkdir -p "$dmg_stage"
  cp -R "$APP_BUNDLE" "$dmg_stage/${APP_DISPLAY_NAME}.app"
  ln -s /Applications "$dmg_stage/Applications"

  hdiutil create -volname "$APP_DISPLAY_NAME" \
    -srcfolder "$dmg_stage" \
    -ov -format UDZO "$APP_DMG" >/dev/null

  rm -rf "$dmg_stage"
  log "DMG готов: $APP_DMG"
}

main() {
  acquire_lock
  ensure_xcode_toolchain
  prepare_environment
  build_swift_app
  apply_plist_customizations
  bundle_runtime_tools
  package_distribution
  log "Готово: $APP_BUNDLE"
  log "Архивы: $APP_ZIP и $APP_DMG"
}

main "$@"
