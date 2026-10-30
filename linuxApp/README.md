# AuraFlow for Linux

The Linux port lives entirely in this folder. It has a Qt control panel, a tray
menu, a local wallpaper library, and a separate playback service. It does not
depend on Swift, AppKit, or the macOS app.

This is the first Linux version, not feature parity with the macOS release.

## Available features

- Local videos, GIFs, and still images, with a separate muted preview.
- Looping desktop playback on connected displays, with audio disabled.
- Start, pause, resume, and remove, from the UI or command line.
- Fill / Fit / Stretch and playback speed from 0.1× to 4× without a restart.
- Recent media library; selecting a preview does not replace active playback.
- XDG launch at login, restoring the last successfully applied wallpaper.
- A background service that survives closing the control panel.
- Session and dependency diagnostics through `auraflow doctor`.

## Desktop compatibility

| Session | Implementation | Current scope |
| --- | --- | --- |
| X11 with an EWMH window manager | Native desktop windows + mpv | Initial backend; one player per detected monitor. |
| Sway / Hyprland and compatible Wayland compositors | mpvpaper background layer | Requires the layer-shell protocol and `mpvpaper`. |
| KDE Plasma Wayland | mpvpaper | Experimental; compositor and desktop-shell behavior needs testing on a real Plasma session. |
| GNOME Wayland (including default Ubuntu sessions) | — | Unsupported in this version; needs a GNOME Shell extension. |
| Xwayland inside Wayland | — | Not used as a fallback; an ordinary Xwayland window cannot serve as a native Wayland background. |

X11 desktop managers that paint an opaque desktop surface can cover the wallpaper
or put their icons beneath it. This version does not disable or reconfigure those
desktop managers. Xvfb regression coverage checks the native window properties
and playback, not compatibility with every desktop shell. Press Start again
after changing an X11 monitor layout.

Lock Screen playback, terminal wallpapers, the online catalog, Wallpaper Engine
projects, fullscreen auto-pause, and automatic performance policies are not ported
yet. AuraFlow does not control the screen locker, synthesize lock events, or
inhibit the screen saver. The system remains responsible for lock, sleep, and
unlock presentation.

## Install

Requirements: Linux, Python 3.10+, `venv` / `pip`, and the player for your session.
The GUI extra installs PySide6. CLI playback does not require Qt.

On Debian / Ubuntu in an **X11 session**:

```sh
sudo apt install python3-venv mpv libegl1 libopengl0 libxcb-cursor0 libxkbcommon-x11-0
cd linuxApp
./scripts/install.sh
~/.local/bin/auraflow
```

On Fedora, install `python3`, `python3-pip`, the distribution's mpv package, and Qt's
system runtime libraries before running the same installer. On Sway / Hyprland,
install `mpvpaper` as well; use the [upstream installation instructions](https://github.com/GhostNaN/mpvpaper)
when it is not packaged by your distribution.

The installer uses a private virtual environment under
`${XDG_DATA_HOME:-~/.local/share}/auraflow/venv`, installs a launcher in
`~/.local/bin`, and adds AuraFlow to the application menu. It does not enable
autostart or start playback. Run it again to update. `AURAFLOW_INSTALL_DIR` and
`AURAFLOW_BIN_DIR` override the install locations; `PYTHON` selects the interpreter.

For a development checkout:

```sh
cd linuxApp
python3 -m venv .venv
.venv/bin/python -m pip install -e '.[gui,dev]'
.venv/bin/auraflow
```

For CLI-only use, install `.` instead of `.[gui]`.

## Usage

Add a file or drop it onto the window. Check the preview, then press **Start
wallpaper**. Pause keeps the displayed frame; Remove closes AuraFlow's desktop
surfaces. Native wallpaper settings and files are never replaced, so the desktop
shell can show the user's wallpaper again as soon as those surfaces close.

Scale and speed affect the active wallpaper even when a different file is selected
in the preview. Backend selection applies to the next Start. A failed replacement
cleans up its own players and retains the previous running wallpaper.

Closing the window hides it in the tray when a tray is available. If the desktop
has no tray, closing the panel exits the panel while the playback service stays
running. Use **File → Quit AuraFlow**, the tray's Quit action, or `auraflow shutdown`
to stop the service. Shutdown keeps the choice for the next login; Remove clears
the login playback choice as well.

**Launch AuraFlow at login** only changes the XDG autostart entry. It does not
start, stop, resume, or replace current playback. Enable it and press Start once
to choose which wallpaper should return next login. It is off by default.
Compositors without an XDG autostart runner can invoke `auraflow restore` from
their session startup configuration after enabling the checkbox. Restore is a
no-op when autostart is disabled or playback is already running.

```sh
auraflow doctor
auraflow start '/home/me/Videos/wallpaper.mp4'
auraflow pause
auraflow resume
auraflow scale fit
auraflow speed 0.75
auraflow status
auraflow autostart on
auraflow remove
auraflow shutdown
```

Media paths are passed as process arguments. No shell is involved. Only local
media files are accepted; playlists, web URLs, and executable wallpapers are
outside this version's scope. Imported files are referenced in place, so keep
them accessible for future logins.

## Storage and removal

AuraFlow respects the XDG base directories:

| Data | Default |
| --- | --- |
| Settings and recent paths | `~/.config/auraflow/settings.json` |
| Autostart registration | `~/.config/autostart/io.github.mkanami.AuraFlow.desktop` |
| Application launcher | `~/.local/share/applications/io.github.mkanami.AuraFlow.desktop` |
| Logs | `~/.local/state/auraflow/daemon.log` |
| Control socket | `$XDG_RUNTIME_DIR/auraflow/<session>/control.sock` |

If `XDG_RUNTIME_DIR` is unavailable, the private socket directory uses
`$XDG_CACHE_HOME/auraflow/<session>` (default `~/.cache`). The service is scoped to
the current graphical session. Player IPC uses inherited private socket pairs;
losing the service connection ends its players. AuraFlow never uses `killall` or
terminates another application's mpv instances.

To uninstall, first run `auraflow autostart off` and `auraflow shutdown`. You can
then delete the installer-created virtual environment, launcher, and the two
AuraFlow `.desktop` files above. Original wallpaper files are not stored there.
Leave the `Hidden=true` autostart entry in place if you need to override an
administrator-installed system autostart entry.

## Development and verification

```sh
.venv/bin/python -m pytest -m 'not x11'
.venv/bin/ruff check .
.venv/bin/ruff format --check .
.venv/bin/python -m build
```

Core tests use fake surfaces and owned child processes. GUI tests force Qt's
offscreen platform. The real mpv transport test uses `--vo=null`, never a desktop
window. Login tests cover enabling and disabling registration during both paused
and playing states, through the controller and the actual GUI checkbox.

Run the real X11 integration tests only in an isolated Xvfb session:

```sh
xvfb-run -a env AURAFLOW_TEST_X11=1 LIBGL_ALWAYS_SOFTWARE=1 \
  .venv/bin/python -m pytest -m x11
```

These tests check desktop window type, input pass-through, focus behavior, actual
mpv decoding / controls / cleanup, and preservation of the root wallpaper property.
The Linux CI workflow runs core, offscreen GUI, wheel, and Xvfb checks on Ubuntu.
Wayland process arguments and session routing are covered by unit tests; real
compositor and GPU compatibility still need validation on a Linux desktop.

Implementation references: [mpv JSON IPC and embedding](https://mpv.io/manual/stable/),
[EWMH desktop window properties](https://specifications.freedesktop.org/wm/latest/ar01s05.html),
[XDG autostart](https://specifications.freedesktop.org/autostart/latest/).
