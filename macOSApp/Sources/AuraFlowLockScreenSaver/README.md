# AuraFlow lock-screen screen saver

`AuraFlowLockScreen` is a public `ScreenSaver.framework` plug-in. The bundle
configuration is read from `Contents/Resources/AuraFlowLockScreenConfig.json`:

```json
{
  "video_file": "Media/Video/wallpaper.mp4",
  "fallback_frame_file": "Media/Fallback/wallpaper.jpg",
  "scale_mode": "fill"
}
```

Paths can be absolute or relative to the bundle's Resources directory.
`scale_mode` accepts `fill`, `fit`, or `stretch`. When readable, the plug-in
prefers `video_path` and `scale_mode` from
`~/Library/Application Support/AuraFlow/config.json`, and uses
`last_frame.png` there as its fallback.

Build the `.saver` with `scripts/build_screensaver.sh`. The script only creates
the bundle; it does not install or select it.

The bundle includes `libAuraWallpaperEffects.dylib`, built from the same Swift
target as the Desktop effects view. Parallax, lights, particles, falling rain,
glass refraction, blur and bloom use `wallpaper-effects.json` from the account's
AuraFlow support directory. The saver supplies its video, image or live frame
directly; no screen capture is used. Its actual start/stop lifecycle controls
animation, including the idle saver before password lock. Sleep, Stop and
Reduce Motion still suspend effects. Music remains muted.

On macOS 26, effects-enabled Start installations preselect this provider for
both Desktop and Idle before loginwindow resolves the manual Lock Screen.
The provider plays the original media and uses the shared interactive effects
renderer. The unlocked Desktop continues to use AuraFlow's own windows; dormant
system instances suspend video and effects. Removal restores the complete saved
native descriptors, including per-display/Space appearance and linked layouts.
Interrupted sessions suspend to those actual user choices, and resume only
choices that still match the suspension record.

The dedicated Lock-only action retains the native Aerial fallback to preserve
the user's Desktop route. That silent effects loop is cached, limited to 30
seconds and uses ambient motion. Neither renderer changes the source media.
The system host has read-only access to account media. Bounded diagnostics try
the host cache when the shared support directory is not writable; activity and
cursor changes also go to the unified log. Updating the saver refreshes both its executable and the effects dylib.
