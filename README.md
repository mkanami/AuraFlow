# AuraFlow

AuraFlow is a macOS live wallpaper app built on a native Swift runtime.

The app no longer depends on Python or PyObjC for wallpaper playback. The release build contains:

- `WallpaperControlApp` — the SwiftUI control application
- `AuraWallpaperAgent` — the AppKit + AVFoundation wallpaper helper
- bundled app resources
- bundled `ffmpeg` and `ffprobe` when they are available on the build machine

## Runtime

AuraFlow uses a split native runtime:

- `WallpaperControlApp` manages UI, settings, catalog, downloads, preview, and control commands.
- `AuraWallpaperAgent` runs as a separate executable and renders looping desktop wallpaper windows per display.
- `AuraWallpaperCore` stores shared models, JSON state, metrics, commands, and wallpaper backup data.

Control and agent state are stored in `~/Library/Application Support/AuraFlow`.

## Features

- local video wallpaper preview and playback
- multi-display wallpaper playback
- start, stop, and remove wallpaper actions
- restore the latest non-AuraFlow wallpaper on remove
- playback speed control
- fill, fit, and stretch scale modes
- auto-pause when fullscreen apps are active
- launch at login
- built-in wallpaper catalog
- downloaded wallpaper library
- optional video optimization paths

## UI

- native Liquid Glass path on macOS 26+
- fallback blur-based UI path on older supported macOS versions
- native window controls
- native window drag and resize handling

## System Requirements

- macOS 13 or later
- Apple Silicon or Intel Mac
- internet connection for catalog downloads

## Release Package

Release builds are produced by `./build_app.sh` and exported to `dist/`:

- `AuraFlow.app`
- `AuraFlow.zip`
- `AuraFlow.dmg`

The app bundle includes the native wallpaper helper. If `ffmpeg` and `ffprobe` are present on the build machine, they are copied into the app bundle so users do not need to install them separately for compatibility transcode paths.

## Build From Source

```bash
./build_app.sh
```

Universal build:

```bash
BUILD_UNIVERSAL=1 ./build_app.sh
```

Tests:

```bash
cd macOSApp
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Project Layout

- `macOSApp/` — app, helper, shared core, tests
- `scripts/build_release.sh` — release build and packaging
- `Resources/` — app icon and packaging assets
- `docs/` — screenshots and documentation assets

## Notes

- Wallpaper restore is based on the user's latest non-AuraFlow wallpaper snapshot.
- Liquid Glass availability depends on the macOS runtime version.
- Video optimization can run without external tools for common paths; bundled or system `ffmpeg` is used only when needed.

## License

MIT
