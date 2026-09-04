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
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
export MACOSX_DEPLOYMENT_TARGET
APP_BUNDLE="$DIST_DIR/${APP_DISPLAY_NAME}.app"
APP_ZIP="$DIST_DIR/${APP_DISPLAY_NAME}.zip"
APP_DMG="$DIST_DIR/${APP_DISPLAY_NAME}.dmg"
SWIFT_BIN="${AURAFLOW_SWIFT_BIN:-swift}"
SDKROOT="${SDKROOT:-}"
SWIFT_SDK_ARGS=()
SDK_VERSION=""
SDK_PATH=""
SDK_MAJOR=""
ICON_PNG="$ROOT_DIR/Resources/AppIcon.png"
ICON_ICNS="$ROOT_DIR/Resources/AppIcon.icns"
BUILD_UNIVERSAL="${BUILD_UNIVERSAL:-1}"
REQUIRE_UNIVERSAL="${REQUIRE_UNIVERSAL:-0}"
BUILD_NATIVE_BRIDGE="${BUILD_NATIVE_BRIDGE:-${AURAFLOW_NATIVE_BRIDGE:-auto}}"
REQUIRE_NATIVE_BRIDGE="${REQUIRE_NATIVE_BRIDGE:-0}"
NATIVE_BRIDGE_ENABLED="0"
PRIVATE_FRAMEWORKS_DIR="/System/Library/PrivateFrameworks"
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

resolve_macos_sdk() {
  if [[ -n "$SDKROOT" && -f "$SDKROOT/SDKSettings.plist" ]]; then
    SDK_PATH="$SDKROOT"
    SDK_VERSION="$(plutil -extract Version raw "$SDKROOT/SDKSettings.plist" 2>/dev/null || true)"
  else
    require_command xcrun
    SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
    SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
  fi

  if [[ ! -d "$SDK_PATH" || -z "$SDK_VERSION" ]]; then
    log "Unable to resolve a usable macOS SDK (path: ${SDK_PATH:-unknown}, version: ${SDK_VERSION:-unknown})."
    exit 1
  fi

  SWIFT_SDK_ARGS=(--sdk "$SDK_PATH")

  if [[ ! -x "$SWIFT_BIN" ]]; then
    require_command "$SWIFT_BIN"
  fi

  SDK_MAJOR="${SDK_VERSION%%.*}"
  if [[ ! "$SDK_MAJOR" =~ ^[0-9]+$ ]]; then
    log "Unable to determine macOS SDK major version from '$SDK_VERSION'."
    exit 1
  fi

  local minimum_macos_major="${MACOSX_DEPLOYMENT_TARGET%%.*}"
  if [[ ! "$minimum_macos_major" =~ ^[0-9]+$ || "$minimum_macos_major" -lt 13 ]]; then
    log "MACOSX_DEPLOYMENT_TARGET must be macOS 13.0 or newer (got '$MACOSX_DEPLOYMENT_TARGET')."
    exit 1
  fi

  if [[ "$SDK_MAJOR" -lt 26 ]]; then
    log "Using macOS SDK $SDK_VERSION ($SDK_PATH); native bridge disabled, legacy fallback will be packaged."
  else
    log "Using macOS SDK $SDK_VERSION ($SDK_PATH)"
  fi
  log "Using Swift: $SWIFT_BIN"
}

private_frameworks_available() {
  [[ -e "$PRIVATE_FRAMEWORKS_DIR/Wallpaper.framework/Wallpaper" ]] || return 1
  [[ -e "$PRIVATE_FRAMEWORKS_DIR/WallpaperTypes.framework/WallpaperTypes" ]] || return 1
}

configure_native_bridge() {
  case "$BUILD_NATIVE_BRIDGE" in
    auto)
      ;;
    0 | false | no | off)
      if [[ "$REQUIRE_NATIVE_BRIDGE" == "1" ]]; then
        log "REQUIRE_NATIVE_BRIDGE=1 conflicts with BUILD_NATIVE_BRIDGE=$BUILD_NATIVE_BRIDGE."
        exit 1
      fi
      NATIVE_BRIDGE_ENABLED="0"
      log "Native bridge disabled by BUILD_NATIVE_BRIDGE=$BUILD_NATIVE_BRIDGE."
      return
      ;;
    1 | true | yes | on)
      ;;
    *)
      log "BUILD_NATIVE_BRIDGE must be auto, 0, or 1 (got '$BUILD_NATIVE_BRIDGE')."
      exit 1
      ;;
  esac

  if [[ "$SDK_MAJOR" -lt 26 ]]; then
    if [[ "$BUILD_NATIVE_BRIDGE" != "auto" || "$REQUIRE_NATIVE_BRIDGE" == "1" ]]; then
      log "Native bridge requested, but SDK 26+ is unavailable (current SDK: $SDK_VERSION)."
      exit 1
    fi
    NATIVE_BRIDGE_ENABLED="0"
    return
  fi

  if ! private_frameworks_available; then
    if [[ "$BUILD_NATIVE_BRIDGE" != "auto" || "$REQUIRE_NATIVE_BRIDGE" == "1" ]]; then
      log "Native bridge requested, but Wallpaper.framework and/or WallpaperTypes.framework is unavailable."
      exit 1
    fi
    NATIVE_BRIDGE_ENABLED="0"
    log "Private Wallpaper frameworks unavailable; native bridge omitted and legacy fallback will be packaged."
    return
  fi

  NATIVE_BRIDGE_ENABLED="1"
  log "Native bridge enabled (SDK $SDK_VERSION and private Wallpaper frameworks available)."
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

swift_build_product() {
  local architecture="$1"
  local product="$2"
  local -a swift_command=("$SWIFT_BIN" build -c release "${SWIFT_SDK_ARGS[@]}" --product "$product")

  if [[ "$architecture" != "$(uname -m)" ]]; then
    swift_command=(arch "-$architecture" "${swift_command[@]}")
  fi
  "${swift_command[@]}"
}

swift_show_bin_path() {
  local architecture="$1"
  local product="$2"
  local -a swift_command=("$SWIFT_BIN" build -c release "${SWIFT_SDK_ARGS[@]}" --product "$product" --show-bin-path)

  if [[ "$architecture" != "$(uname -m)" ]]; then
    swift_command=(arch "-$architecture" "${swift_command[@]}")
  fi
  "${swift_command[@]}"
}

build_swift_architecture() {
  local architecture="$1"
  log "Building app and agent for $architecture"
  if ! swift_build_product "$architecture" "$APP_TARGET"; then
    log "Failed to build ${APP_TARGET} for $architecture."
    return 1
  fi
  if ! swift_build_product "$architecture" "$HELPER_TARGET"; then
    log "Failed to build ${HELPER_TARGET} for $architecture."
    return 1
  fi

  if [[ "$NATIVE_BRIDGE_ENABLED" == "1" ]]; then
    log "Building native bridge for $architecture"
    if ! swift_build_product "$architecture" "$NATIVE_BRIDGE_TARGET"; then
      if [[ "$REQUIRE_NATIVE_BRIDGE" == "1" || "$BUILD_NATIVE_BRIDGE" != "auto" ]]; then
        log "Native bridge build failed and is required by the current configuration."
        return 1
      fi
      NATIVE_BRIDGE_ENABLED="0"
      log "[warn] Native bridge build failed for $architecture. Continuing with the legacy fallback only."
    fi
  fi
}

build_swift_app() {
  local host_arch
  host_arch="$(uname -m)"
  case "$host_arch" in
    arm64 | x86_64) ;;
    *)
      log "Unsupported host architecture: $host_arch"
      exit 1
      ;;
  esac

  pushd "$SWIFT_DIR" >/dev/null
  build_swift_architecture "$host_arch"

  local secondary_arch=""
  local built_secondary="0"
  if [[ "$BUILD_UNIVERSAL" == "1" ]]; then
    if [[ "$host_arch" == "arm64" ]]; then
      secondary_arch="x86_64"
    else
      secondary_arch="arm64"
    fi

    if command -v arch >/dev/null 2>&1; then
      log "Building $secondary_arch slice (Rosetta may be required)"
      if build_swift_architecture "$secondary_arch"; then
        log "Built $secondary_arch slice"
        built_secondary="1"
      else
        if [[ "$REQUIRE_NATIVE_BRIDGE" == "1" || "$BUILD_NATIVE_BRIDGE" != "auto" ]]; then
          log "Failed to build the required $secondary_arch slice."
          exit 1
        fi
        if [[ "$REQUIRE_UNIVERSAL" == "1" ]]; then
          log "Failed to build $secondary_arch slice and REQUIRE_UNIVERSAL=1 is set."
          exit 1
        fi
        log "[warn] Failed to build $secondary_arch slice. Using $host_arch only."
      fi
    else
      if [[ "$REQUIRE_UNIVERSAL" == "1" ]]; then
        log "'arch' command not found and REQUIRE_UNIVERSAL=1 is set."
        exit 1
      fi
      log "[warn] 'arch' command not found; building $host_arch slice only."
    fi
  else
    log "Skipping secondary architecture build (BUILD_UNIVERSAL=$BUILD_UNIVERSAL)"
  fi

  local host_bin_path secondary_bin_path
  host_bin_path="$(swift_show_bin_path "$host_arch" "$APP_TARGET")"
  if [[ "$built_secondary" == "1" ]]; then
    secondary_bin_path="$(swift_show_bin_path "$secondary_arch" "$APP_TARGET")"
  else
    secondary_bin_path=""
  fi

  local bin_path="$host_bin_path"
  local resources_bundle="$host_bin_path/${APP_TARGET}_${APP_TARGET}.bundle"
  if [[ "$built_secondary" == "1" ]]; then
    local universal_dir="$SWIFT_DIR/.build/universal"
    require_command lipo
    mkdir -p "$universal_dir"
    lipo -create -output "$universal_dir/${APP_TARGET}" \
      "$host_bin_path/${APP_TARGET}" "$secondary_bin_path/${APP_TARGET}"
    lipo -create -output "$universal_dir/${HELPER_TARGET}" \
      "$host_bin_path/${HELPER_TARGET}" "$secondary_bin_path/${HELPER_TARGET}"
    if [[ "$NATIVE_BRIDGE_ENABLED" == "1" ]]; then
      lipo -create -output "$universal_dir/${NATIVE_BRIDGE_TARGET}" \
        "$host_bin_path/${NATIVE_BRIDGE_TARGET}" "$secondary_bin_path/${NATIVE_BRIDGE_TARGET}"
    fi
    bin_path="$universal_dir"
    log "Created universal app and agent binaries"
  fi
  popd >/dev/null

  local binary="$bin_path/${APP_TARGET}"
  local helper_path="$bin_path/${HELPER_TARGET}"
  local native_bridge_path=""
  if [[ "$NATIVE_BRIDGE_ENABLED" == "1" ]]; then
    native_bridge_path="$bin_path/${NATIVE_BRIDGE_TARGET}"
  fi

  if [[ ! -x "$binary" ]]; then
    log "Binary not found: $binary"
    exit 1
  fi
  if [[ ! -x "$helper_path" ]]; then
    log "Helper binary not found: $helper_path"
    exit 1
  fi
  if [[ "$NATIVE_BRIDGE_ENABLED" == "1" && ! -x "$native_bridge_path" ]]; then
    log "Native bridge binary not found: $native_bridge_path"
    exit 1
  fi

  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_BUNDLE/Contents/MacOS"
  mkdir -p "$APP_BUNDLE/Contents/Resources"

  cp "$binary" "$APP_BUNDLE/Contents/MacOS/${APP_TARGET}"
  cp "$helper_path" "$APP_BUNDLE/Contents/MacOS/${HELPER_TARGET}"
  chmod +x "$APP_BUNDLE/Contents/MacOS/${APP_TARGET}"
  chmod +x "$APP_BUNDLE/Contents/MacOS/${HELPER_TARGET}"
  if [[ "$NATIVE_BRIDGE_ENABLED" == "1" ]]; then
    cp "$native_bridge_path" "$APP_BUNDLE/Contents/MacOS/${NATIVE_BRIDGE_TARGET}"
    chmod +x "$APP_BUNDLE/Contents/MacOS/${NATIVE_BRIDGE_TARGET}"
  fi

  if [[ "$REQUIRE_UNIVERSAL" == "1" ]]; then
    local app_archs helper_archs
    app_archs="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/${APP_TARGET}" 2>/dev/null || true)"
    helper_archs="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/${HELPER_TARGET}" 2>/dev/null || true)"
    if [[ "$app_archs" != *"arm64"* || "$app_archs" != *"x86_64"* ]]; then
      log "Universal app binary required, produced: ${app_archs:-unknown}"
      exit 1
    fi
    if [[ "$helper_archs" != *"arm64"* || "$helper_archs" != *"x86_64"* ]]; then
      log "Universal helper binary required, produced: ${helper_archs:-unknown}"
      exit 1
    fi
    if [[ "$NATIVE_BRIDGE_ENABLED" == "1" ]]; then
      local native_bridge_archs
      native_bridge_archs="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/${NATIVE_BRIDGE_TARGET}" 2>/dev/null || true)"
      if [[ "$native_bridge_archs" != *"arm64"* || "$native_bridge_archs" != *"x86_64"* ]]; then
        log "Universal native bridge binary required, produced: ${native_bridge_archs:-unknown}"
        exit 1
      fi
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
  plist_set_string "$plist" LSMinimumSystemVersion "$MACOSX_DEPLOYMENT_TARGET"
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

verify_private_framework_isolation() {
  require_command otool

  local app_binary="$APP_BUNDLE/Contents/MacOS/${APP_TARGET}"
  local helper_binary="$APP_BUNDLE/Contents/MacOS/${HELPER_TARGET}"
  local bridge_binary="$APP_BUNDLE/Contents/MacOS/${NATIVE_BRIDGE_TARGET}"
  local saver_binary="$APP_BUNDLE/Contents/PlugIns/AuraFlowLockScreen.saver/Contents/MacOS/AuraFlowLockScreen"
  local portable_binary

  for portable_binary in "$app_binary" "$helper_binary" "$saver_binary"; do
    if [[ ! -f "$portable_binary" ]]; then
      log "Portable target is missing from the staged app bundle: $portable_binary"
      exit 1
    fi
    if otool -L "$portable_binary" | grep -Eq '/(Wallpaper|WallpaperTypes)\.framework'; then
      log "Private Wallpaper framework leaked into portable target: $portable_binary"
      exit 1
    fi
  done

  if [[ "$NATIVE_BRIDGE_ENABLED" != "1" ]]; then
    log "Native bridge omitted; private Wallpaper framework linkage is absent and legacy fallback is active."
    return
  fi

  if [[ ! -f "$bridge_binary" ]]; then
    log "Native bridge binary is missing from the staged app bundle."
    exit 1
  fi
  if ! otool -L "$bridge_binary" | grep -Eq '/Wallpaper\.framework'; then
    log "Native bridge is not linked with Wallpaper.framework."
    exit 1
  fi
  if ! otool -L "$bridge_binary" | grep -Eq '/WallpaperTypes\.framework'; then
    log "Native bridge is not linked with WallpaperTypes.framework."
    exit 1
  fi
  log "Private framework linkage is isolated to ${NATIVE_BRIDGE_TARGET}"
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
  resolve_macos_sdk
  configure_native_bridge
  prepare_environment
  build_swift_app
  apply_plist_customizations
  bundle_runtime_tools
  bundle_lock_screen_saver
  verify_private_framework_isolation
  sign_app_bundle
  package_distribution
  log "Done: $APP_BUNDLE"
  log "Artifacts: $APP_ZIP and $APP_DMG"
}

main "$@"
