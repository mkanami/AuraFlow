[![Tests](https://github.com/mkanami/AuraFlow/actions/workflows/tests.yml/badge.svg)](https://github.com/mkanami/AuraFlow/actions/workflows/tests.yml)
[![Downloads](https://img.shields.io/github/downloads/mkanami/AuraFlow/total?label=downloads&color=brightgreen)](https://github.com/mkanami/AuraFlow/releases)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

# AuraFlow

AuraFlow turns videos, animated files, and pictures into wallpapers on macOS.
You can use a wallpaper on the Desktop and Lock Screen together, or apply it
only to the Lock Screen without changing your Desktop.

<p align="center">
  <img src="docs/aura-ui.png" width="900" alt="AuraFlow app showing a live wallpaper preview" />
</p>

## What you can do

- Use your own videos, GIFs, WebM files, and pictures as wallpapers
- Browse and download wallpapers from the built-in catalog
- Apply one wallpaper to all connected displays
- Choose how the wallpaper fits the screen: Fill, Fit, or Stretch
- Change the playback speed of animated wallpapers
- Pause and continue playback with Stop and Play
- Use a wallpaper on the Lock Screen only
- Automatically pause animated wallpapers while another app is fullscreen
- Restore your previous macOS wallpaper with Remove

## Requirements

- macOS 13 or later
- Apple Silicon or Intel Mac
- An internet connection only when browsing or downloading from the catalog

The native animated Lock Screen experience requires macOS 26 or later. On
older supported macOS versions, AuraFlow uses its included Screen Saver mode
for Lock Screen playback.

## Installation

1. Download the latest `AuraFlow.dmg` from
   [GitHub Releases](https://github.com/mkanami/AuraFlow/releases/latest)
2. Open the downloaded DMG
3. Drag `AuraFlow.app` into the Applications folder
4. Open AuraFlow from Applications

## Quick start

1. Open AuraFlow
2. Click **Change Wallpaper…** to choose a file from your Mac, or open
   **Wallpaper Catalog** to find one online
3. Check the wallpaper in the preview
4. Click **Start** to use it on the Desktop and Lock Screen, or **Lock** to use
   it only on the Lock Screen
5. Use the speed slider if you want to change animation speed
6. Click **Remove** when you want AuraFlow to stop and restore your regular
   macOS wallpaper

## Controls

| Button | What it does |
| --- | --- |
| **Start** | Applies the selected wallpaper to the Desktop and Lock Screen |
| **Lock** | Applies the selected wallpaper only to the Lock Screen |
| **Stop** | Freezes an animated wallpaper on its current frame |
| **Play** | Continues a wallpaper previously frozen with Stop |
| **Remove** | Removes the AuraFlow wallpaper and restores your regular wallpaper |
| **Change Wallpaper…** | Selects a video, animation, or picture from your Mac |
| **Wallpaper Catalog** | Opens the online wallpaper collection |
| **Downloaded Wallpapers** | Shows wallpapers already saved to your Mac |
| **Monitoring** | Shows whether the wallpaper process is running correctly |

Stop and Play are unavailable for pictures because a still image has no
playback to pause. Start and Lock remain unavailable while an AuraFlow
wallpaper is active; click Remove before applying a different mode.

## Using the wallpaper catalog

Open **Wallpaper Catalog**, select a wallpaper, and click **Download to
Preview**. After the download finishes, the wallpaper appears in the main
preview. It is not applied until you click Start or Lock.

Downloaded wallpapers remain available under **Downloaded Wallpapers**, so you
do not need to download them again.

## Restoring your normal wallpaper

Click **Remove** to stop AuraFlow and return to your regular macOS wallpaper.
AuraFlow remembers the most recent wallpaper you selected in macOS, including
your own pictures and Apple's built-in wallpapers.

If macOS needs extra time to update multiple displays or Spaces, leave AuraFlow
open until Remove finishes.

## If something does not work

- Make sure there is enough free storage for wallpaper downloads and temporary
  video processing
- Use **Monitoring** to check whether the wallpaper process is running
- If a download was interrupted, try it again from the catalog
- If Start or Lock is unavailable, click Remove first and then select the
  wallpaper again
- After updating macOS, install the latest AuraFlow release for the best Lock
  Screen compatibility

When reporting a problem, include your macOS version, Mac model, wallpaper file
type, and the exact button you pressed.

## License

AuraFlow is available under the [MIT License](LICENSE).
