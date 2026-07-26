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
