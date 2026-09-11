[![Tests](https://github.com/mkanami/AuraFlow/actions/workflows/tests.yml/badge.svg)](https://github.com/mkanami/AuraFlow/actions/workflows/tests.yml)
[![Downloads](https://img.shields.io/github/downloads/mkanami/AuraFlow/total?label=downloads&color=brightgreen)](https://github.com/mkanami/AuraFlow/releases)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

# AuraFlow

AuraFlow is a native live wallpaper app for macOS. It supports local media and
downloadable wallpapers, keeps playback outside the control app, and can present
the same wallpaper on the Desktop and the real macOS Lock Screen.

<p align="center">
  <img src="docs/aura-ui.png" width="900" alt="AuraFlow interface preview" />
</p>

## Highlights

- Live wallpapers from local video, GIF, WebM, and supported image files
- One wallpaper window per display with Fill, Fit, and Stretch scaling
- Shared Desktop + Lock Screen playback through **Start**
- Dedicated Lock Screen-only playback through **Lock**, without changing Desktop
- Persistent **Stop / Play** toggle for video, including repeated Lock Screen sessions
- Playback-speed changes synchronized with Desktop and Lock Screen playback
- Safe **Remove** flow that restores the latest user wallpaper across Spaces and displays
- Built-in catalog backed by MoeWalls, MotionBGS, and Dareful
- Resilient downloads with source resolution, retry, validation, and a local library
- Optional media optimization using bundled `ffmpeg` and `ffprobe` in release builds
- Auto-pause while another application is fullscreen
- Runtime monitoring for process state, resource use, screens, windows, and player rate
- Adaptive black-or-white text and restrained Liquid Glass contrast based on the preview

## Controls

| Control | Behavior |
| --- | --- |
| **Start** | Starts the selected wallpaper on Desktop and Lock Screen |
| **Lock** | Applies the selected wallpaper only to Lock Screen |
| **Stop** | Freezes video on its current frame on every active surface |
| **Play** | Resumes a wallpaper previously frozen with Stop |
| **Remove** | Stops AuraFlow, removes its Lock Screen route, and restores user wallpaper state |

Static images do not expose Stop/Play because there is no playback to pause. Start
and Lock remain unavailable while an AuraFlow wallpaper session is installed,
including while video is paused; use Remove before starting another route.

## Lock Screen

On macOS 26 and newer, AuraFlow uses Apple's native Aerial wallpaper provider as
the transport for real Lock Screen playback. The selected media is prepared in a
reserved Aerial asset, while the native bridge handles the secure Lock Screen
session. The Desktop route is kept separate when **Lock** is used.

On macOS versions where the native route is unavailable, AuraFlow falls back to
its bundled legacy Screen Saver component. Capability checks fail closed: native
mode is enabled only when the bridge is executable, correctly signed, compatible
with the current architecture and protocol, and able to load the required system
frameworks and symbols.

AuraFlow journals every Lock Screen mutation before changing system state. The
original asset, thumbnail, wallpaper store, system wallpaper URL, Spaces, displays,
and process identity are tracked for rollback and recovery. Remove clears the
managed marker only after the agent is gone, the managed Lock Screen route is
disabled, and restoration has been confirmed.

`Wallpaper.framework` and `WallpaperTypes.framework` are private Apple frameworks.
They are linked only by the isolated `AuraWallpaperNativeBridge` executable; the
control app, wallpaper agent, shared core, and legacy Screen Saver do not link
them. A future macOS update can disable native Lock Screen support until
compatibility is updated. This is why the native build is distributed directly
and not through the Mac App Store.

## Wallpaper Restoration

Before Start takes ownership of Desktop, AuraFlow records the current wallpaper
configuration. It also watches for changes made by the user while live wallpaper
is active. Remove restores the latest valid non-AuraFlow route, including custom
PNG, JPEG, and HEIC files as well as built-in macOS wallpaper providers.

Restoration is serialized and verified across current Spaces and displays. Backup,
marker, and recovery files remain available if macOS does not confirm a change,
allowing the next launch to recover instead of reporting a false success or
leaving an orphan wallpaper process.

## System Requirements

- macOS 13 or later
- Apple Silicon or Intel Mac
- Internet connection for catalog browsing and downloads
- macOS 26 or later for the native Aerial Lock Screen route

## Install

Download `AuraFlow.dmg` from [GitHub Releases](https://github.com/mkanami/AuraFlow/releases),
open it, and drag `AuraFlow.app` into `/Applications`.

Published release artifacts must be Developer ID signed and notarized. Local
development builds are ad-hoc signed and may show a Gatekeeper warning on another
Mac.

## Build

The default release build is universal (`arm64` + `x86_64`):

```bash
./scripts/build_release.sh
```

`./build_app.sh` is a compatibility entry point for the same workflow. Artifacts
are written to:

```text
dist/AuraFlow.app
dist/AuraFlow.zip
dist/AuraFlow.dmg
```

Useful build options:

```bash
# Require both universal slices
REQUIRE_UNIVERSAL=1 ./scripts/build_release.sh

# Require the macOS 26 native Lock Screen bridge
REQUIRE_NATIVE_BRIDGE=1 ./scripts/build_release.sh

# Developer ID signing
CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
  ./scripts/build_release.sh
```

If SDK 26 or the private Wallpaper frameworks are unavailable, the normal build
omits the native bridge and packages the legacy Lock Screen fallback. Set
`REQUIRE_NATIVE_BRIDGE=1` when that fallback-only result is not acceptable.

## Test

```bash
cd macOSApp
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The test suite covers lifecycle races, PID and process identity, rollback,
multi-Space restoration, native bridge handshakes, Lock Screen pause/resume,
media preparation, adaptive appearance, catalog parsing, and download smoke
scenarios. Live catalog smoke tests are opt-in in GitHub Actions.

## Runtime Architecture

- `WallpaperControlApp` — SwiftUI control app, preview, catalog, settings, and monitoring
- `AuraWallpaperAgent` — AppKit/AVFoundation Desktop wallpaper windows and playback
- `AuraWallpaperNativeBridge` — isolated native macOS 26 Lock Screen bridge
- `AuraWallpaperCore` — shared contracts, state, transactions, recovery, and process safety
- `AuraFlowLockScreen.saver` — bundled fallback for older macOS versions

Runtime state is stored in:

```text
~/Library/Application Support/AuraFlow
```

## Project Layout

- `macOSApp/Package.swift` — SwiftPM package definition
- `macOSApp/Sources/WallpaperControlApp` — control app and UI
- `macOSApp/Sources/AuraWallpaperAgent` — Desktop wallpaper agent
- `macOSApp/Sources/AuraWallpaperNativeBridge` — native Lock Screen bridge
- `macOSApp/Sources/AuraWallpaperCore` — shared runtime and recovery code
- `macOSApp/Sources/AuraFlowLockScreenSaver` — legacy Screen Saver fallback
- `macOSApp/Tests/WallpaperControlAppTests` — Swift tests
- `scripts/build_release.sh` — universal build, signing, and packaging
- `.github/workflows` — CI tests and release publishing

## License

AuraFlow is available under the [MIT License](LICENSE).
