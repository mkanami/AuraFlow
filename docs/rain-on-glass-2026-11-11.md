# Rain on Glass — implementation and verification

## Rendering

Rain on Glass and Falling Rain have independent enable flags and controls.
Glass has intensity, sliding speed, wind, blur and refraction. Existing rain
preferences retain their values; the new mode defaults off on migration.
Falling Rain also exposes its cached foreground blur amount.

The glass simulation uses stationary beads, slowly sliding larger drops,
volume-based merges, bead collection and five-second fading water trails.
Wind is independent of the cursor and of Falling Rain. A fixed simulation step
keeps its behavior consistent at different display rates. Pools are bounded at
1,000 beads, 50 moving drops and 384 trail segments.

A Metal pass accumulates the water normal/height map. A second pass samples
and blurs the wallpaper through that map; dry pixels remain transparent.
Refraction follows the source's aspect mode and parallax transform. The water
gets its color from the wallpaper, rather than a fixed tint.

Sources are the renderer's own CGImage, decoded AVPlayer video frames,
completed terminal IOSurfaces, or WKWebView snapshots. Both the installed and
local terminal previews expose their completed frame. Static images and
unchanged terminal sequences stay cached. Web snapshots are limited to one
request in flight and eight requests per second. There is no screen capture.
The shader and simulation are implemented in this repository; no external
raindrop shader source was copied.

Glass rendering is capped at 30 fps and a 1,920-pixel longest edge. One GPU
command is in flight; textures and the instance buffer are reused. Pausing,
hiding, locking, sleep, Reduce Motion, disabling the effect and removing the
view detach video outputs and release frame textures. Unavailable source
frames or Metal leave the original wallpaper visible. No window ordering,
system saver, native wallpaper descriptors or login behavior is changed.

## Verification

53 focused tests passed across WallpaperGlassRainTests, WallpaperRainTests,
WallpaperEffectsTests, TerminalPreviewAutopauseTests,
TerminalLoginLockIndependenceTests and TerminalPreviewAppearanceTests.
Tests use offscreen views and GPU textures without ordering real wallpaper
windows or invoking a system lock. They cover actual pixel displacement,
independent blur, upright image orientation, transparent dry areas, changing
source frames, bounded simulation, frame-rate consistency, independent rain
controls, source cache invalidation, replacement video layers, repeated
suspension/resume, and output detachment.

`./script/build_and_run.sh --verify` built, signed and launched the app bundle.
The settings UI showed the separate glass controls using existing glass
sliders. Falling Rain and Rain on Glass were enabled together. Installed
helper diagnostics confirmed `surface=desktop`, `glassReady=true`, 574 drops,
and approximately 28.8 completed glass frames per second with a 30 fps effect
clock. This check is independent of the app preview.

## Short performance measurements

On the development Mac (Apple M2), an offscreen Metal run at 1920×1080 with
60 changing wallpaper frames measured 0.55 ms mean GPU time and 1.04 ms maximum.
Mean CPU+GPU wall time per frame was 3.41 ms. This is the glass renderer's
command time, not total app energy use or video decoding cost.

Two 15-second live samples used the current video wallpaper and existing
parallax, lights and cyan Falling Rain. The first three samples were excluded.
CPU percentages use 100% for one core; memory is physical footprint.

| Process | Glass off CPU | Glass on CPU | Glass off memory | Glass on memory |
| --- | ---: | ---: | ---: | ---: |
| Desktop video helper | 19.2% | 31.2% | 52.1 MiB | 86.6 MiB |
| GUI with preview | 10.7% | 22.5% | 124.4 MiB | 178.4 MiB |

These short sequential samples include changing media and other system work.
They do not constitute a new 15-hour endurance or battery test. Resource usage
returned downward when glass was disabled. Fullscreen autopause was temporarily
disabled for the live helper measurement and then restored. Launch at Login and
Play AuraFlow on Lock Screen were not toggled. Final preferences have both rain
modes enabled, glass at its default values, and fullscreen autopause enabled.
