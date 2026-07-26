[![downloads](https://img.shields.io/github/downloads/mkanami/AuraFlow/total?label=downloads&color=brightgreen)](https://github.com/mkanami/AuraFlow/releases)

# AuraFlow

AuraFlow is a native macOS live wallpaper app. It uses a Swift control app, a separate AppKit + AVFoundation wallpaper agent, and a small Objective-C bridge for the Liquid Glass layer.

<p align="center">
  <img src="docs/aura-ui.png" width="900" alt="AuraFlow interface preview" />
</p>

## Current Runtime

AuraFlow uses a native split runtime built from these macOS targets:

- `WallpaperControlApp`: SwiftUI control app for preview, catalog, downloads, settings, and playback controls.
- `AuraWallpaperAgent`: helper executable that owns desktop wallpaper windows and AVFoundation playback.
- `AuraWallpaperCore`: shared Swift models, JSON runtime state, command files, metrics, and wallpaper backup/restore logic.
- `AuraGlassBridgeKit`: small Objective-C/AppKit bridge used only for the glass visual layer.

Runtime state is stored in:

```text
~/Library/Application Support/AuraFlow
```

## Features

- local video wallpaper preview and playback
- one wallpaper window per display
- start, stop, and remove wallpaper actions
- restore the latest non-AuraFlow wallpaper when live wallpaper is removed
- playback speed control
- fill, fit, and stretch scale modes
- auto-pause while fullscreen apps are active
- matching live system screen saver with a direct Start button
- launch at login through a LaunchAgent
- built-in wallpaper catalog
- downloaded wallpaper library
- optional video compatibility optimization

## UI

- native Liquid Glass path on macOS 26 and newer
- blur-based fallback UI on older supported macOS versions
- native window controls
- optimized window drag and resize handling
- preview playback handled independently from wallpaper playback

## System Requirements

- macOS 13 or later
- Apple Silicon or Intel Mac
- internet connection for catalog downloads

## Lock Screen

Enable **Play AuraFlow on Lock Screen** in Playback Settings to keep the current
video playing through macOS's modern lock-screen wallpaper engine. Because Apple
does not publish its wallpaper-extension API, AuraFlow temporarily reserves one
already-downloaded Apple Aerial cache slot. The original Aerial asset and the
complete wallpaper configuration are backed up before the first change and are
restored when the feature is disabled.

The current video, thumbnail, active Spaces, and displays are synchronized each
time the wallpaper starts. Deleted Space records and old AuraFlow
`last_frame.png` references are removed during the transaction. On macOS
versions without the modern Aerial store, AuraFlow falls back to its bundled
legacy Screen Saver module.

**Remove** stops the wallpaper agent, restores the reserved Aerial asset and
wallpaper configuration, clears the selected video, restores the original
desktop on every current Space, and restarts the macOS wallpaper presenters so
no managed stop frame is left behind.

This integration is intentionally reversible but uses an undocumented macOS
cache format. A macOS update or an Aerial re-download can temporarily replace
the reserved asset; launching AuraFlow synchronizes it again.

For release builds, `ffmpeg` and `ffprobe` are bundled when available on the build machine. They are used only for compatibility conversion paths, not for normal AVFoundation playback.

## Install

Download `AuraFlow.dmg` from GitHub Releases, open it, and drag `AuraFlow.app` into `/Applications`.

If the release is not Developer ID notarized, macOS may block the first launch with a security warning. In that case, open System Settings, go to Privacy & Security, and allow AuraFlow from the blocked app section.

## Build

Build the app and release artifacts:

```bash
./build_app.sh
```

Universal build:

```bash
BUILD_UNIVERSAL=1 ./build_app.sh
```

The build output is written to:

```text
dist/AuraFlow.app
dist/AuraFlow.zip
dist/AuraFlow.dmg
```

## Test

```bash
cd macOSApp
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Release Packaging

`scripts/build_release.sh` builds the Swift targets, stages the app bundle, signs nested Mach-O binaries, signs the app bundle, and packages ZIP and DMG artifacts.

When `CODESIGN_IDENTITY` is set to a Developer ID Application certificate, release builds can be notarized by the GitHub Actions release workflow. Without Developer ID credentials, the build falls back to valid ad-hoc signing so the bundle is structurally valid, but macOS will still show an unknown-developer warning.

## Project Layout

- `macOSApp/Package.swift`: SwiftPM package definition
- `macOSApp/Sources/WallpaperControlApp`: SwiftUI control app
- `macOSApp/Sources/AuraWallpaperAgent`: native wallpaper helper process
- `macOSApp/Sources/AuraWallpaperCore`: shared runtime models and storage
- `macOSApp/Sources/AuraGlassBridgeKit`: Objective-C glass bridge
- `macOSApp/Tests`: Swift tests
- `scripts/build_release.sh`: build, signing, and packaging script
- `Resources`: app icon assets
- `docs`: README images

## License

MIT
