# Linux development

- Keep Linux source, assets, dependencies, tests, packaging, and development notes in `linuxApp/`. Its CI is `.github/workflows/linux.yml`.
- The macOS app, build scripts, version, and release assets are maintained separately. Linux-only work must not change them or import Swift/AppKit code.
- Use Python 3.10+ and install the development environment with `python3 -m venv .venv` and `.venv/bin/python -m pip install -e '.[gui,dev]'` from this directory.
- Run `.venv/bin/python -m pytest -m 'not x11'`, `.venv/bin/ruff check .`, `.venv/bin/ruff format --check .`, and `bash -n scripts/install.sh` before committing.
- GUI tests use Qt's offscreen platform. Run native X11 tests only inside an isolated Xvfb session with `AURAFLOW_TEST_X11=1`; see `README.md` for the command. Real Wayland desktop behavior still needs testing on Linux.
- Launch at login changes future startup registration only. Preserve the independent active wallpaper and preview states.
- Preserve the desktop's native wallpaper settings. Do not synthesize lock events, start a screen locker, or terminate unrelated players to repair playback.
- Keep supported sessions and unported features accurate in `README.md`. Do not treat passing Xvfb tests as proof of compatibility with every desktop shell.
