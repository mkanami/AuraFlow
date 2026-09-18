[![Tests](https://github.com/mkanami/AuraFlow/actions/workflows/tests.yml/badge.svg)](https://github.com/mkanami/AuraFlow/actions/workflows/tests.yml)
[![Downloads](https://img.shields.io/github/downloads/mkanami/AuraFlow/total?label=downloads&color=brightgreen)](https://github.com/mkanami/AuraFlow/releases)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

# AuraFlow

Live wallpapers for macOS. Use a video, GIF, WebM, or image from your Mac, or
pick one from the built-in catalog.

<p align="center">
  <img src="docs/aura-ui.png" width="900" alt="AuraFlow wallpaper preview and controls" />
</p>

## Features

- Animated wallpapers on the Desktop and Lock Screen
- Separate Lock Screen-only mode
- Built-in catalog with downloadable wallpapers
- Fill, Fit, and Stretch scaling
- Playback speed control
- Multi-display support
- Automatic pause while another app is fullscreen
- One-click restore of your previous macOS wallpaper

## Install

1. Download the latest [`AuraFlow.dmg`](https://github.com/mkanami/AuraFlow/releases/latest).
2. Open it and drag AuraFlow into Applications.
3. Launch AuraFlow from Applications.

AuraFlow supports macOS 13 and newer on Apple Silicon and Intel Macs. Native
animated Lock Screen wallpapers require macOS 26 or newer; earlier versions use
the included screen saver integration.

## Use

Choose a local file with **Change Wallpaper…**, or open **Wallpaper Catalog**
and select **Download** on a wallpaper. The selection appears in the main
preview before anything is applied.

- **Start** — apply to the Desktop and Lock Screen
- **Lock** — apply only to the Lock Screen
- **Stop / Play** — pause or resume animation
- **Remove** — stop AuraFlow and restore the previous wallpaper
- **Downloaded Wallpapers** — reopen wallpapers already saved on this Mac
- **Monitoring** — inspect the wallpaper process and resource usage

Pictures do not have Stop or Play controls. To switch between Desktop mode and
Lock Screen-only mode, remove the active wallpaper first.

## Catalog downloads

Catalog previews use lightweight media. Downloading fetches the original file,
stores it locally, and adds it to **Downloaded Wallpapers**. A saved wallpaper
does not need to be downloaded again.

## Build from source

The app is a Swift Package and builds with Xcode's macOS toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path macOSApp
BUILD_UNIVERSAL=1 REQUIRE_UNIVERSAL=1 scripts/build_release.sh
```

Release artifacts are written to `dist-builds/` unless
`AURAFLOW_OUTPUT_DIR` is set.

## Troubleshooting

- If Start or Lock is unavailable, remove the currently active AuraFlow wallpaper first.
- If a catalog download was interrupted, open the card and download it again.
- Check **Monitoring** if playback is not running.
- Keep enough free space for the original wallpaper and temporary video processing.

For bug reports, include the macOS version, Mac model, wallpaper format, and the
action that triggered the problem.

## License

[MIT](LICENSE)
