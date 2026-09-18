<p align="center">
  <img src="Resources/AppIcon.png" width="120" alt="AuraFlow icon" />
</p>

<h1 align="center">AuraFlow</h1>

<p align="center">
  Native live wallpapers for the macOS Desktop and Lock Screen.
</p>

<p align="center">
  <a href="https://github.com/mkanami/AuraFlow/actions/workflows/tests.yml"><img src="https://github.com/mkanami/AuraFlow/actions/workflows/tests.yml/badge.svg" alt="Tests" /></a>
  <a href="https://github.com/mkanami/AuraFlow/releases"><img src="https://img.shields.io/github/downloads/mkanami/AuraFlow/total?label=downloads&color=brightgreen" alt="Downloads" /></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-black" alt="macOS 13 or newer" />
  <img src="https://img.shields.io/badge/Swift-5.9-F05138" alt="Swift 5.9" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" /></a>
</p>

<p align="center">
  Use your own video, animation, or image — or download a wallpaper from the
  built-in catalog.
</p>

<p align="center">
  <img src="docs/aura-ui.png" width="900" alt="AuraFlow wallpaper preview and controls" />
</p>

## Highlights

| | |
| --- | --- |
| **Desktop playback** | Loop animated wallpapers behind desktop icons across connected displays. |
| **Lock Screen** | Use the same wallpaper everywhere or run AuraFlow on the Lock Screen only. |
| **Wallpaper Catalog** | Browse, preview, download, and reopen wallpapers without leaving the app. |
| **Local media** | Open videos, GIFs, WebM files, and still images from your Mac. |
| **Playback controls** | Change speed, pause, resume, and automatically pause for fullscreen apps. |
| **Scaling** | Switch between Fill, Fit, and Stretch while the wallpaper is running. |
| **Safe removal** | Stop AuraFlow and restore the previous macOS wallpaper with one action. |

## Installation

1. Download the latest [`AuraFlow.dmg`](https://github.com/mkanami/AuraFlow/releases/latest).
2. Open the disk image and drag **AuraFlow** into **Applications**.
3. Launch AuraFlow from Applications.

No account is required. An internet connection is only needed for the catalog.

## Getting Started

1. Select **Change Wallpaper…** to open a local file, or choose a wallpaper in
   **Wallpaper Catalog**.
2. Check the wallpaper in the main preview.
3. Select **Start** for Desktop and Lock Screen playback, or **Lock** for
   Lock Screen-only mode.
4. Use **Remove** to stop AuraFlow and restore the previous wallpaper.

### Main controls

| Control | Action |
| --- | --- |
| **Start** | Apply the selected wallpaper to the Desktop and Lock Screen. |
| **Lock** | Apply the selected wallpaper only to the Lock Screen. |
| **Stop / Play** | Pause or resume an animated wallpaper. |
| **Remove** | Stop AuraFlow and restore the previous macOS wallpaper. |
| **Change Wallpaper…** | Select media stored on this Mac. |
| **Wallpaper Catalog** | Browse online wallpapers. |
| **Downloaded Wallpapers** | Reopen previously downloaded wallpapers. |
| **Monitoring** | View playback state and resource usage. |

Still images do not show Stop or Play. Remove the active AuraFlow wallpaper
before switching between Desktop and Lock Screen-only modes.

## Wallpaper Catalog

The catalog uses lightweight media for previews and downloads the original file
only after you select **Download**. Saved files appear under **Downloaded
Wallpapers** and are reused on the next launch.

Foreground downloads take priority over preview traffic. The active card pauses
its preview while the original file is transferred, then resumes without
affecting a wallpaper already running on the Desktop.

## Compatibility

| Environment | Desktop | Lock Screen |
| --- | --- | --- |
| macOS 26 or newer | Animated playback | Native animated playback |
| macOS 13–15 | Animated playback | Included screen saver integration |
| Apple Silicon | Supported | Supported |
| Intel Mac | Supported | Supported |

Native Lock Screen integration depends on APIs available in macOS 26. AuraFlow
keeps the older screen saver path for earlier supported releases.

## Architecture

AuraFlow is a Swift Package split into small runtime components:

| Component | Responsibility |
| --- | --- |
| `WallpaperControlApp` | SwiftUI interface, previews, catalog, downloads, and user actions. |
| `AuraWallpaperAgent` | Long-running wallpaper playback and lifecycle coordination. |
| `AuraWallpaperCore` | Shared models, persistence, recovery, and platform operations. |
| `AuraWallpaperNativeBridge` | Isolated macOS 26 native wallpaper integration. |
| `AuraFlowLockScreenSaver` | Lock Screen fallback for earlier macOS versions. |

Media playback uses AVFoundation. AppKit bridges are limited to macOS window and
wallpaper behavior that SwiftUI does not expose directly. Release builds bundle
the required media tools inside the application.

## Build and Test

Requirements:

- Xcode with the macOS SDK
- Swift 5.9 or newer
- macOS 13 or newer

Run the test suite:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path macOSApp
```

Create a universal `arm64 + x86_64` release:

```sh
BUILD_UNIVERSAL=1 REQUIRE_UNIVERSAL=1 scripts/build_release.sh
```

Artifacts are written to `dist-builds/` by default. Set
`AURAFLOW_OUTPUT_DIR` to choose a different destination.

## Repository Layout

```text
macOSApp/                   Swift package, app, agents, bridges, and tests
scripts/build_release.sh   Universal release, signing, ZIP, and DMG pipeline
script/build_and_run.sh    Local debug build and launch helper
docs/                      README media
```

## Troubleshooting

- If **Start** or **Lock** is unavailable, remove the currently active AuraFlow
  wallpaper first.
- If a catalog download was interrupted, reopen the card and download it again.
- Open **Monitoring** when playback is not running as expected.
- Keep enough free storage for the original wallpaper and temporary media
  processing.

When filing an issue, include the macOS version, Mac model, wallpaper format,
and the action that triggered the problem.

## Contributing

Bug reports and focused pull requests are welcome. Keep platform changes scoped,
add regression coverage where practical, and run the test suite before opening
a pull request.

## License

AuraFlow is available under the [MIT License](LICENSE).
