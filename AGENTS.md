# Working instructions

- Always commit completed changes.
- For every Lock Screen change, cover both manual user locks and OS-initiated transitions in regression tests. Include the idle screen saver before password lock, delayed or missing notifications, sleep/wake, and unlock. Keep their presentation logic shared.
- Screen-saver activity is not proof of a secure lock. Never start the system saver or lock an unlocked Mac to repair wallpaper. Tests on an active desktop must intercept window ordering and system actions.
- Preserve the user's complete native wallpaper descriptors and appearance settings. Never substitute stock previews or guessed system wallpapers. Avoid machine-specific paths, display IDs, and hardware assumptions in production fixes.
