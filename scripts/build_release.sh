#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_DIR="$ROOT_DIR/macOSApp"
DIST_DIR="$ROOT_DIR/dist"
APP_TARGET="WallpaperControlApp"
HELPER_TARGET="AuraWallpaperAgent"
NATIVE_BRIDGE_TARGET="AuraWallpaperNativeBridge"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-AuraFlow}"
APP_VERSION="${AURAFLOW_VERSION:-1.3.1}"
APP_BUILD="${AURAFLOW_BUILD:-10}"
APP_BUNDLE="$DIST_DIR/${APP_DISPLAY_NAME}.app"
APP_ZIP="$DIST_DIR/${APP_DISPLAY_NAME}.zip"
APP_DMG="$DIST_DIR/${APP_DISPLAY_NAME}.dmg"
SWIFT_BIN="${AURAFLOW_SWIFT_BIN:-swift}"
SDKROOT="${SDKROOT:-}"
SWIFT_SDK_ARGS=()
ICON_PNG="$ROOT_DIR/Resources/AppIcon.png"
ICON_ICNS="$ROOT_DIR/Resources/AppIcon.icns"
BUILD_UNIVERSAL="${BUILD_UNIVERSAL:-1}"
REQUIRE_UNIVERSAL="${REQUIRE_UNIVERSAL:-0}"
FFMPEG_RUNTIME_BUNDLING="${FFMPEG_RUNTIME_BUNDLING:-1}"
REQUIRE_FFMPEG_RUNTIME="${REQUIRE_FFMPEG_RUNTIME:-0}"
FFMPEG_BIN="${AURAFLOW_FFMPEG_BIN:-}"
FFPROBE_BIN="${AURAFLOW_FFPROBE_BIN:-}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
CODESIGN_KEYCHAIN_PATH="${CODESIGN_KEYCHAIN_PATH:-}"
REQUIRE_CODESIGN="${REQUIRE_CODESIGN:-0}"
LOCK_DIR="$ROOT_DIR/.build-lock"
BUNDLED_TOOLS_DIR="$APP_BUNDLE/Contents/Resources/BundledTools"

log() {
  printf '[build] %s\n' "$1"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Required command not found: $1"
    exit 1
  fi
}

configure_developer_dir() {
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    log "Using DEVELOPER_DIR=$DEVELOPER_DIR"
    return
  fi

  local bundled_xcode="/Applications/Xcode.app/Contents/Developer"
  if [[ -d "$bundled_xcode" ]]; then
    local bundled_sdk="$bundled_xcode/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    local bundled_swift="$bundled_xcode/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
    local xcode_sdk_version=""
    if [[ -f "$bundled_sdk/SDKSettings.plist" ]]; then
      xcode_sdk_version="$(plutil -extract Version raw "$bundled_sdk/SDKSettings.plist" 2>/dev/null || true)"
    fi
    local xcode_sdk_major="${xcode_sdk_version%%.*}"
    if [[ "$xcode_sdk_major" =~ ^[0-9]+$ && "$xcode_sdk_major" -ge 26 ]]; then
      export SDKROOT="$bundled_sdk"
      if [[ -x "$bundled_swift" && "$SWIFT_BIN" == "swift" ]]; then
        SWIFT_BIN="$bundled_swift"
      fi
      log "Using Xcode SDK $xcode_sdk_version from $SDKROOT"
      return
    fi
  fi
}

require_macos_sdk() {
  local sdk_version=""
  local sdk_path=""

  if [[ -n "$SDKROOT" && -f "$SDKROOT/SDKSettings.plist" ]]; then
    sdk_path="$SDKROOT"
    sdk_version="$(plutil -extract Version raw "$SDKROOT/SDKSettings.plist" 2>/dev/null || true)"
    SWIFT_SDK_ARGS=(--sdk "$SDKROOT")
  else
    require_command xcrun
    sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
    sdk_path="$(xcrun --show-sdk-path --sdk macosx)"
  fi

  if [[ ! -x "$SWIFT_BIN" ]]; then
    require_command "$SWIFT_BIN"
  fi

  local sdk_major="${sdk_version%%.*}"
  if [[ ! "$sdk_major" =~ ^[0-9]+$ || "$sdk_major" -lt 26 ]]; then
    log "macOS SDK 26+ is required for native Liquid Glass. Current SDK: $sdk_version ($sdk_path)"
    log "Install/use Xcode 26+ or set DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"
    exit 1
  fi
  log "Using Swift: $SWIFT_BIN"
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

ensure_icon() {
  if [[ -f "$ICON_ICNS" ]]; then
    return
  fi

  if [[ ! -f "$ICON_PNG" ]]; then
    log "Icon not found. Place AppIcon.png or AppIcon.icns under Resources/ before building."
    exit 1
  fi

  require_command iconutil

  local tmpdir
  tmpdir="$(mktemp -d)"
  local iconset="$tmpdir/AppIcon.iconset"
  mkdir -p "$iconset"

  for size in 16 32 64 128 256 512; do
    for scale in 1 2; do
      local scaled=$((size * scale))
      local name="icon_${size}x${size}"
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
  local env_override="$1"
  local tool_name="$2"

  if [[ -n "$env_override" && -x "$env_override" ]]; then
    printf '%s\n' "$env_override"
    return 0
  fi

  local candidate=""
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
  "$SWIFT_BIN" build -c release "${SWIFT_SDK_ARGS[@]}"

  local arm_binary="$SWIFT_DIR/.build/arm64-apple-macosx/release/${APP_TARGET}"
  local arm_helper="$SWIFT_DIR/.build/arm64-apple-macosx/release/${HELPER_TARGET}"
  local arm_native_bridge="$SWIFT_DIR/.build/arm64-apple-macosx/release/${NATIVE_BRIDGE_TARGET}"
  local x86_binary="$SWIFT_DIR/.build/x86_64-apple-macosx/release/${APP_TARGET}"
  local x86_helper="$SWIFT_DIR/.build/x86_64-apple-macosx/release/${HELPER_TARGET}"
  local x86_native_bridge="$SWIFT_DIR/.build/x86_64-apple-macosx/release/${NATIVE_BRIDGE_TARGET}"
  local universal_dir="$SWIFT_DIR/.build/universal"
  local built_x86="0"

  if [[ "$BUILD_UNIVERSAL" == "1" ]] && command -v arch >/dev/null 2>&1; then
    log "Building x86_64 slice (Rosetta may be required)"
    if arch -x86_64 "$SWIFT_BIN" build -c release "${SWIFT_SDK_ARGS[@]}"; then
      log "Built x86_64 slice"
      built_x86="1"
    else
      if [[ "$REQUIRE_UNIVERSAL" == "1" ]]; then
        log "Failed to build x86_64 slice and REQUIRE_UNIVERSAL=1 is set."
        exit 1
      fi
      log "[warn] Failed to build x86_64 slice. Using arm64 only."
    fi
  elif [[ "$BUILD_UNIVERSAL" != "1" ]]; then
    log "Skipping x86_64 build (BUILD_UNIVERSAL=$BUILD_UNIVERSAL)"
  else
    if [[ "$REQUIRE_UNIVERSAL" == "1" ]]; then
      log "'arch' command not found and REQUIRE_UNIVERSAL=1 is set."
      exit 1
    fi
    log "[warn] 'arch' command not found; building arm64 slice only."
  fi

  local bin_path=""
  local helper_path=""
  local native_bridge_path=""
  if [[ "$built_x86" == "1" && -f "$arm_binary" && -f "$x86_binary" && -f "$arm_helper" && -f "$x86_helper" && -f "$arm_native_bridge" && -f "$x86_native_bridge" ]]; then
    mkdir -p "$universal_dir"
    lipo -create -output "$universal_dir/${APP_TARGET}" "$arm_binary" "$x86_binary"
    lipo -create -output "$universal_dir/${HELPER_TARGET}" "$arm_helper" "$x86_helper"
    lipo -create -output "$universal_dir/${NATIVE_BRIDGE_TARGET}" "$arm_native_bridge" "$x86_native_bridge"
    bin_path="$universal_dir"
    helper_path="$universal_dir/${HELPER_TARGET}"
    native_bridge_path="$universal_dir/${NATIVE_BRIDGE_TARGET}"
    log "Created universal binary"
  elif [[ -f "$arm_binary" && -f "$arm_helper" && -f "$arm_native_bridge" ]]; then
    bin_path="$(dirname "$arm_binary")"
    helper_path="$arm_helper"
    native_bridge_path="$arm_native_bridge"
  else
    bin_path="$("$SWIFT_BIN" build -c release "${SWIFT_SDK_ARGS[@]}" --show-bin-path)"
    helper_path="$bin_path/${HELPER_TARGET}"
    native_bridge_path="$bin_path/${NATIVE_BRIDGE_TARGET}"
  fi
  popd >/dev/null

  local binary="$bin_path/${APP_TARGET}"
  local resources_bundle="$bin_path/${APP_TARGET}_${APP_TARGET}.bundle"
  if [[ ! -d "$resources_bundle" ]]; then
    local arm_resources_bundle="$SWIFT_DIR/.build/arm64-apple-macosx/release/${APP_TARGET}_${APP_TARGET}.bundle"
    local x86_resources_bundle="$SWIFT_DIR/.build/x86_64-apple-macosx/release/${APP_TARGET}_${APP_TARGET}.bundle"
    if [[ -d "$arm_resources_bundle" ]]; then
      resources_bundle="$arm_resources_bundle"
    elif [[ -d "$x86_resources_bundle" ]]; then
      resources_bundle="$x86_resources_bundle"
    fi
  fi

  if [[ ! -x "$binary" ]]; then
    log "Binary not found: $binary"
    exit 1
  fi
  if [[ ! -x "$helper_path" ]]; then
    log "Helper binary not found: $helper_path"
    exit 1
  fi
  if [[ ! -x "$native_bridge_path" ]]; then
    log "Native bridge binary not found: $native_bridge_path"
    exit 1
  fi

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_BUNDLE/Contents/MacOS"
  mkdir -p "$APP_BUNDLE/Contents/Resources"

  cp "$binary" "$APP_BUNDLE/Contents/MacOS/${APP_TARGET}"
  cp "$helper_path" "$APP_BUNDLE/Contents/MacOS/${HELPER_TARGET}"
  cp "$native_bridge_path" "$APP_BUNDLE/Contents/MacOS/${NATIVE_BRIDGE_TARGET}"
  chmod +x "$APP_BUNDLE/Contents/MacOS/${APP_TARGET}"
  chmod +x "$APP_BUNDLE/Contents/MacOS/${HELPER_TARGET}"
  chmod +x "$APP_BUNDLE/Contents/MacOS/${NATIVE_BRIDGE_TARGET}"

  if [[ "$REQUIRE_UNIVERSAL" == "1" ]]; then
    local app_archs helper_archs native_bridge_archs
    app_archs="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/${APP_TARGET}" 2>/dev/null || true)"
    helper_archs="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/${HELPER_TARGET}" 2>/dev/null || true)"
    native_bridge_archs="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/${NATIVE_BRIDGE_TARGET}" 2>/dev/null || true)"
    if [[ "$app_archs" != *"arm64"* || "$app_archs" != *"x86_64"* ]]; then
      log "Universal app binary required, produced: ${app_archs:-unknown}"
      exit 1
    fi
    if [[ "$helper_archs" != *"arm64"* || "$helper_archs" != *"x86_64"* ]]; then
      log "Universal helper binary required, produced: ${helper_archs:-unknown}"
      exit 1
    fi
    if [[ "$native_bridge_archs" != *"arm64"* || "$native_bridge_archs" != *"x86_64"* ]]; then
      log "Universal native bridge binary required, produced: ${native_bridge_archs:-unknown}"
      exit 1
    fi
  fi

  if [[ -d "$resources_bundle" ]]; then
    cp -R "$resources_bundle" "$APP_BUNDLE/Contents/Resources/$(basename "$resources_bundle")"
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
  if [[ "$FFMPEG_RUNTIME_BUNDLING" != "1" ]]; then
    log "Skipping bundled ffmpeg runtime (FFMPEG_RUNTIME_BUNDLING=$FFMPEG_RUNTIME_BUNDLING)"
    return
  fi

  mkdir -p "$BUNDLED_TOOLS_DIR"

  local ffmpeg_path=""
  local ffprobe_path=""

  ffmpeg_path="$(resolve_tool_path "$FFMPEG_BIN" ffmpeg 2>/dev/null || true)"
  ffprobe_path="$(resolve_tool_path "$FFPROBE_BIN" ffprobe 2>/dev/null || true)"

  if [[ -z "$ffmpeg_path" || -z "$ffprobe_path" ]]; then
    if [[ "$REQUIRE_FFMPEG_RUNTIME" == "1" ]]; then
      log "Bundled ffmpeg runtime not found."
      log "Set AURAFLOW_FFMPEG_BIN and AURAFLOW_FFPROBE_BIN or install ffmpeg locally."
      exit 1
    fi
    log "[warn] Bundled ffmpeg runtime not found. Build will fall back to system ffmpeg if available on the user's Mac."
    rmdir "$BUNDLED_TOOLS_DIR" 2>/dev/null || true
    return
  fi

  cp "$ffmpeg_path" "$BUNDLED_TOOLS_DIR/ffmpeg"
  cp "$ffprobe_path" "$BUNDLED_TOOLS_DIR/ffprobe"
  chmod +x "$BUNDLED_TOOLS_DIR/ffmpeg" "$BUNDLED_TOOLS_DIR/ffprobe"
  log "Bundled ffmpeg from $ffmpeg_path"
  log "Bundled ffprobe from $ffprobe_path"
}

bundle_lock_screen_saver() {
  local plugins_dir="$APP_BUNDLE/Contents/PlugIns"
  mkdir -p "$plugins_dir"
  log "Building AuraFlow Lock Screen screen saver"
  AURAFLOW_VERSION="$APP_VERSION" \
    AURAFLOW_BUILD="$APP_BUILD" \
    BUILD_UNIVERSAL="$BUILD_UNIVERSAL" \
    REQUIRE_UNIVERSAL="$REQUIRE_UNIVERSAL" \
    "$ROOT_DIR/scripts/build_screensaver.sh" "$plugins_dir"

  if [[ "$REQUIRE_UNIVERSAL" == "1" ]]; then
    local saver_binary saver_archs
    saver_binary="$plugins_dir/AuraFlowLockScreen.saver/Contents/MacOS/AuraFlowLockScreen"
    saver_archs="$(lipo -archs "$saver_binary" 2>/dev/null || true)"
    if [[ "$saver_archs" != *"arm64"* || "$saver_archs" != *"x86_64"* ]]; then
      log "Universal screen saver required, produced: ${saver_archs:-unknown}"
      exit 1
    fi
  fi
}

codesign_args() {
  local identity="${CODESIGN_IDENTITY:--}"
  local args=(
    --force
    --sign "$identity"
  )
  if [[ "$identity" != "-" ]]; then
    args+=(--timestamp)
  fi
  if [[ -n "$CODESIGN_KEYCHAIN_PATH" ]]; then
    args+=(--keychain "$CODESIGN_KEYCHAIN_PATH")
  fi
  printf '%s\n' "${args[@]}"
}

prepare_bundle_for_codesign() {
  if [[ -z "$CODESIGN_IDENTITY" && "$REQUIRE_CODESIGN" == "1" ]]; then
    log "REQUIRE_CODESIGN=1 but CODESIGN_IDENTITY is not set."
    exit 1
  fi

  require_command codesign
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true
  fi
  find "$APP_BUNDLE" -type d -name "_CodeSignature" -prune -exec rm -rf {} +
}

find_macho_files() {
  while IFS= read -r -d '' candidate; do
    if /usr/bin/file -b "$candidate" 2>/dev/null | grep -q "Mach-O"; then
      printf '%s\n' "$candidate"
    fi
  done < <(find "$APP_BUNDLE" -type f -print0)
}

codesign_target() {
  local target="$1"
  shift || true
  local args=()
  while IFS= read -r arg; do
    args+=("$arg")
  done < <(codesign_args)
  if [[ "$#" -gt 0 ]]; then
    args+=("$@")
  fi
  codesign "${args[@]}" "$target"
}

sign_app_bundle() {
  prepare_bundle_for_codesign

  log "Signing app bundle"
  while IFS= read -r target; do
    codesign_target "$target"
  done < <(find_macho_files)

  if [[ -d "$APP_BUNDLE/Contents/Frameworks" ]]; then
    while IFS= read -r framework; do
      codesign_target "$framework"
    done < <(find "$APP_BUNDLE/Contents/Frameworks" -mindepth 1 -maxdepth 1 -type d \( -name "*.framework" -o -name "*.bundle" \) | sort)
  fi

  if [[ -d "$APP_BUNDLE/Contents/PlugIns" ]]; then
    while IFS= read -r plugin; do
      codesign_target "$plugin"
    done < <(
      find "$APP_BUNDLE/Contents/PlugIns" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        \( -name "*.saver" -o -name "*.bundle" \) \
        | sort
    )
  fi

  if [[ -n "$CODESIGN_IDENTITY" ]]; then
    codesign_target "$APP_BUNDLE" --options runtime
  else
    codesign_target "$APP_BUNDLE"
  fi
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
}

sign_disk_image() {
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    return 0
  fi

  log "Signing DMG"
  codesign_target "$APP_DMG"
}

package_distribution() {
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$APP_BUNDLE" >/dev/null 2>&1 || true
  fi

  log "Creating ZIP archive"
  pushd "$DIST_DIR" >/dev/null
  COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "${APP_DISPLAY_NAME}.app" "$(basename "$APP_ZIP")"
  popd >/dev/null

  log "Creating DMG"
  local dmg_stage="$DIST_DIR/.dmg-stage"
  rm -rf "$dmg_stage"
  mkdir -p "$dmg_stage"
  COPYFILE_DISABLE=1 cp -R "$APP_BUNDLE" "$dmg_stage/${APP_DISPLAY_NAME}.app"
  if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$dmg_stage/${APP_DISPLAY_NAME}.app" >/dev/null 2>&1 || true
  fi
  ln -s /Applications "$dmg_stage/Applications"

  hdiutil create \
    -volname "$APP_DISPLAY_NAME" \
    -srcfolder "$dmg_stage" \
    -ov \
    -format UDZO \
    "$APP_DMG" >/dev/null

  rm -rf "$dmg_stage"
  sign_disk_image
  log "DMG ready: $APP_DMG"
}

main() {
  acquire_lock
  configure_developer_dir
  require_macos_sdk
  prepare_environment
  build_swift_app
  apply_plist_customizations
  bundle_runtime_tools
  bundle_lock_screen_saver
  sign_app_bundle
  package_distribution
  log "Done: $APP_BUNDLE"
  log "Artifacts: $APP_ZIP and $APP_DMG"
}

main "$@"
