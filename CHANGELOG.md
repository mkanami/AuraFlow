# Changelog

## 1.3.4

- Keep Dock running during wallpaper recovery, prevent isolated runtime stores from changing the user's Desktop, and require a dedicated session for the full interactive test suite.
- Make Launch at Login affect only future logins: retain current playback when toggled, keep manual Start available while disabled, and prevent same-session recovery/GUI reopening from applying the new future preference immediately.
- Wait for the native Locked presentation to commit before starting its screen saver; cover all four session regressions with decoded-video tests and an isolated regression-proof runner.
- Prevent stale shield notifications and delayed native presentation recovery from starting the screen saver on an unlocked Mac and repeatedly locking the session.
- Preserve the Desktop player while the Mac is locked and send native presentation requests only after the lock is confirmed.
- Preserve the Launch at Login checkbox while its helper starts, wake waiting login jobs immediately, and clear transient startup warnings after recovery. Reuse the prepared first frame and skip commands saved by a previous helper session.
- Protect newly started login and recovery helpers during startup cleanup and application updates.
- Restore the user's native wallpaper routes after login or a playback-helper failure, independently of launch-at-login; keep saved media and resume delayed video, terminal, and web helpers without replacing newer user choices.
- Validate terminal helper process identity after reboot so a reused PID cannot falsely mark wallpaper playback as running.
- Show the user's wallpaper when a saved Lock Screen saver has no running Aura source after reboot, and resolve media settings and pause markers from the user's actual home directory.
- Repair system fallback Lock Screen routes after lid/display changes without restarting WallpaperAgent, and preserve terminal publications while the display list is empty.
- Replace outdated terminal helpers when the new app is opened, while deferring replacement during a locked or paused session.

- Preserve video, terminal, and web Lock Screen surfaces through lid sleep and wake; serialize system presentation changes and retain fallback frames until replacements are ready.

- Recover terminal wallpaper surfaces after sleep, display wake, session changes, and Spaces transitions without restarting the command or clearing manual pause.
- Retry transient Lock Screen preparation failures and reconcile missed lock/unlock notifications.

## 1.3.3

- Fixed terminal wallpapers stalling on the desktop by correctly retiring Metal drawables between frames.
- Improved scrolling in the catalog, terminal settings, and downloaded wallpapers without changing the glass appearance.
- Prefetched catalog posters and upcoming pages for faster scrolling immediately after opening the catalog.
- Restored the download-count badge with a scheduled GitHub-hosted update.

## 1.3.2

- Terminal wallpapers with live previews, local and Homebrew CLI search, guided installation, and custom commands.
- Pause and resume for terminal wallpapers, with shared playback, scaling, monitoring, and launch-at-login controls.
- Consistent Fit, Fill, and Stretch presentation across previews, the desktop, and the Lock Screen.
- Local Wallpaper Engine video and offline web project imports, including Steam library discovery.
- Functional video frame blending and clearer video optimization settings.
- Download progress and cancellation, improved catalog navigation, and adaptive glass cards.
- More reliable Lock Screen switching, wallpaper removal, restoration, and source changes.
- Reduced hidden-preview work, bounded font caches, reusable rendering resources, and cached file metadata.
- Fixed a shutdown crash when the wallpaper-store monitor stopped inside its own callback.

Source releases follow successful CI. Current distribution archives use ad-hoc signatures and are uploaded manually; they are not Apple-notarized. The optional Developer ID workflow retains signing, notarization and artifact smoke checks for future automated distribution.
