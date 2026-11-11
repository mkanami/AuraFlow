# Rain on Glass — implementation and verification

## Rendering

Rain on Glass and Falling Rain have independent enable flags and controls.
Glass has intensity, sliding speed, wind, blur and refraction. Existing rain
preferences retain their values; the new mode defaults off on migration.
Falling Rain also exposes its cached optical blur amount at each depth.

The glass simulation uses stationary beads, volume-based merges, bead
collection and five-second fading water trails. The independent Sliding drops
switch freezes the pane, clears trails and preserves the other rain settings.
When enabled, contact-line adhesion, inertia and gravity produce pinning,
release and acceleration. Drop elongation follows speed. Distance-sampled
capsules join into continuous, curved rivulets rather than separate ellipses.
Wind is independent of the cursor and of Falling Rain. A fixed simulation step
keeps its behavior consistent at different display rates. Pools are bounded at
1,000 beads, 50 moving drops and 768 trail segments.

A Metal pass renders the current Falling Rain state into a transparent
texture. A second accumulates the water normal/height map. The final pass
samples the wallpaper and airborne rain together at the refracted coordinates.
Dry pixels retain the same rain. The layer representation is hidden only while
the glass compositor is available, with a fallback when frames are missing.
There is one falling-rain simulation, without CALayer readback or duplicate
rain. Refraction follows the source's aspect mode and parallax transform.
Surface-height derivatives give compact curved highlights, avoiding a white
triangular sector from normalizing only the horizontal normal direction.
The water gets its color from the scene, rather than a fixed tint.

Falling Rain uses the same soft cross-section and tapered exposure profile in
both renderers. Widths preserve visibility; a mildly desaturated lit core and
restrained depth-specific softness replace hard bars and round particle heads.

Sources are the renderer's own CGImage, decoded AVPlayer video frames,
completed terminal IOSurfaces, or WKWebView snapshots. Both the installed and
local terminal previews expose their completed frame. Static images and
unchanged terminal sequences stay cached. Web snapshots are limited to one
request in flight and eight requests per second. There is no screen capture.
The shader and simulation are implemented in this repository; no external
raindrop shader source was copied.

Glass rendering uses the shared display-link target timestamp, avoiding
frame skips caused by main-thread callback-time jitter. It is capped at 30 fps
and a 1,920-pixel longest edge. One GPU
command is in flight; textures and the instance buffer are reused. Pausing,
hiding, locking, sleep, Reduce Motion, disabling the effect and removing the
view detach video outputs and release frame textures. Unavailable source
frames or Metal leave the original wallpaper visible. No window ordering,
system saver, native wallpaper descriptors or login behavior is changed.

## Verification

56 focused tests passed across WallpaperGlassRainTests, WallpaperRainTests,
WallpaperEffectsTests, TerminalPreviewAutopauseTests,
TerminalLoginLockIndependenceTests and TerminalPreviewAppearanceTests.
Tests use offscreen views and GPU textures without ordering real wallpaper
windows or invoking a system lock. They cover actual pixel displacement,
independent blur, upright image orientation, transparent dry areas, changing
source frames, bounded simulation, frame-rate consistency, independent rain
controls, source cache invalidation, replacement video layers, repeated
suspension/resume, and output detachment. Additional regressions verify rain
pixel displacement exclusively on wet areas, preservation of dry rain,
compositor handoff and fallback, compact specular highlights, and the independent
sliding switch (including a frozen pane and acceleration after resuming).

`./script/build_and_run.sh --verify` built, signed and launched the app bundle.
The settings UI showed the separate glass controls using existing glass
sliders. Falling Rain and Rain on Glass were enabled together. Installed
helper diagnostics confirmed `surface=desktop`, `glassReady=true`, 574 drops,
and approximately 28.8 completed glass frames per second with a 30 fps effect
clock. This check is independent of the app preview.

The revised UI switch was also toggled independently in the running app:
Falling Rain and Rain on Glass remained enabled. Installed desktop diagnostics
confirmed `glassAirRainCount=429`, `glassDropCount=574`, `glassReady=true` while
sliding was off. The user's current rain density, speed, wind, color and
refraction settings were preserved; fullscreen autopause was restored.

## Short performance measurements

The measurements below describe the initial glass implementation before the
shared Falling Rain pass. Subsequent offscreen combined-scene measurements
under concurrent preview load ranged from 0.86 to 2.77 ms mean GPU command time
(maxima 6.08 and 10.62 ms) and 4.03 to 9.12 ms mean CPU+GPU wall time at 1920×1080.
These are short command-buffer samples, with the same 30 fps cap and one frame
in flight; they do not measure total application power or battery life.


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
Play AuraFlow on Lock Screen were not toggled. After the current revision, both rain modes and sliding are enabled, the
user-selected effect values are preserved, and fullscreen autopause is enabled.


## Final display-cadence check

After using the display-link target timestamp instead of callback wall time,
the installed desktop completed 851 glass frames during 873 effect updates
(97.5% of the 30 Hz clock, approximately 29.2 fps). Diagnostics retained 429
airborne particles and 574 glass drops in the combined renderer.

A separate final 10-second resource sample used the user's current 82% rain
density, 89% speed, 77% wind and 73% refraction. The helper averaged 43.1% of one
CPU core with 95.4–104.6 MiB physical footprint; the GUI with preview averaged
31.2% with 148.7–157.5 MiB. This differs from the initial settings and is not a
like-for-like performance comparison or an endurance test.

The Mac locked after the measurement. Fullscreen autopause was restored via
WallpaperRuntimeStore and its normal update-command channel. A configuration
diff confirmed that only pause_on_fullscreen changed. Login, Lock Screen and
all user-chosen rain values were preserved; no system lock or saver was invoked.

## Glass-drop visibility adjustment

The optical footprint of stationary beads is now 1.8 times larger, and moving
drops 1.35 times larger. Stationary coverage is stronger, with a bright upper
meniscus and a shaded lower rim so drops remain readable against both dark
and bright artwork. Physical masses, trajectories, collection and pool limits
are preserved. Water trails keep their restrained lighting.

Nine focused glass regressions passed. GPU exports were visually checked on
Night Train and Summer Mountain at the normal 45% glass intensity, with Falling
Rain enabled. The export helper now uses this default intensity rather than 70%.


## Individual contact patches and fluid body motion

Stationary drops now have independently seeded aspect ratios, rotation, shear
and smooth irregular contours. Their contact patches stay fixed, rather than
wobbling over time. The normal-map shader uses the same deformed surface for
silhouette, refraction and lighting, with padding around the full outline.

Flowing drops use damped body responses for elongation and tilt, and continuous
neck deformation. Per-drop surface variation curves the trajectory through
filtered lateral velocity. Added volume grows the visible body gradually;
weighted centers retain their visual position and ease into the merged center.
Collected beads and secondary drops shrink and converge over 0.22 seconds,
reusing their existing pool slots. The Sliding drops switch also freezes these
transitions. Pool limits and the shared Falling Rain compositor are preserved.

59 focused regressions passed, including stable shape diversity, actual GPU
silhouette differences, bounded per-step deformation, curved trajectories,
multi-frame bead collection and coalescence, and existing suspension and
preference independence checks. Optional artifact export writes a four-second,
30 fps H.264 clip and sampled frames from the real shader without capturing a
screen or creating a presentation window. These are local build artifacts.

The latest 1920×1080 offscreen combined-scene sample averaged 0.88 ms per GPU
command (2.80 ms maximum) and 3.85 ms CPU+GPU wall time. As before, this is a
short renderer sample, not a total power or endurance measurement.


## Capillary suction and variable volume

Bead collection now starts at the visible contact patch. A short attachment
phase stretches the bead and forms a tapered water bridge; volume then moves
progressively into the live receiving drop over 0.46–0.64 seconds. The rear
contact remains anchored as the neck extends inward. The receiving body reacts
to added water and the side of impact. Receiver identity is checked across
coalescence and slot recycling, so an attached lobe cannot jump to a new drop.

Water deposited along the traversed path is deducted from the moving drop's
volume. Its radius and speed can decrease, its contact line can pin, and a
course bias from collection or a sticky patch bends the next run. Lost or
excess volume is accounted as deposited film. Water bridges reuse the existing
normal-map pass, with a maximum of 64 extra instances; particle pools remain
bounded. Sliding drops freezes the suction phase and its geometry as well.

63 focused regressions passed. New controlled cases cover gradual transfer
and volume accounting, visible connected GPU necks, shrinkage from film loss,
course changes after side collection, a frozen suction phase and recycled
receiver identity. The optional exporter also creates an eight-second,
four-times magnified real-time suction clip in addition to the full scene.
The latest offscreen sample averaged 0.88 ms GPU command time (4.59 ms maximum)
and 3.92 ms CPU+GPU wall time; this remains a short renderer measurement.
