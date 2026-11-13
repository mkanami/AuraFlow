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

On macOS 26, effects-enabled video/photo installations select this live saver
provider instead of the Aerial video-only provider. The existing native secure
presentation bridge is retained. Complete native wallpaper choices are journaled
and restored by the same route coordinator used for terminal/web wallpapers.
Turning effects off keeps the live route, avoiding a player/provider restart.
