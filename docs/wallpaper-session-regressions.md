# Wallpaper session regression tests

These five regressions are covered by executable tests, with one test per reported issue:

| Issue | Test | Required behavior |
| --- | --- | --- |
| Repeated unwanted locks | `issue1PreparedHelperNeverRelocksAfterStaleShowsOrLateRecovery` | An already prepared helper receives a delayed assertion completion after unlock and 1,000 stale Show requests. It retains a usable surface and never starts the saver for an unlocked session. |
| Cached still frame after login | `issue2LoginStartsDecodedAnimationInsteadOfLeavingCachedStillFrame` | A fresh agent loads persisted autostart settings, an existing first-frame cache, and a stale Pause command. Its actual AVQueuePlayer decodes frames, advances time, and attaches ready AVPlayerLayers without a GUI Start action. |
| Desktop animation stops after unlock | `issue3UnlockResumesDecodedAnimationAfterSystemSuspendsDesktopPlayer` | Across five lock/unlock cycles, the real Desktop player is paused at the system boundary, resumes decoding after unlock, and retains the same player and layers. Health polling while locked never replaces the player. |
| Missing Aura on the Lock Screen | `issue4LockScreenWaitsForPreparedSecureSurfaceAfterLogin` | Both direct Show and recovery after a missed lock notification wait for the asynchronous Locked assertion before starting the saver or reporting readiness. Duplicate lock events reuse the committed surface. |
| Login checkbox stops current wallpaper | `issue5LoginCheckboxDoesNotStopRestartOrPauseCurrentWallpaper` | Toggling registration off/on retains the running player, PID, command, pause state, and prepared Lock Screen, with changing decoded frames throughout. No runtime bootout, bootstrap, or kickstart is allowed. |

The Desktop tests use a generated moving H.264 fixture and require two decoded frames with different pixels, advancing playback time, visible windows, and `AVPlayerLayer.isReadyForDisplay`. They do not treat a nonzero player rate as proof of animation.

The native tests run the production presentation queue and bridge state handling. Only the opaque system assertion creation and saver entry point are replaced with a controlled asynchronous driver. Session state and settings are isolated; the tests never lock the real Mac or change its wallpaper, login agents, or Screen Saver preferences. This proves application ordering and recovery, not the pixels drawn by Apple's secure compositor or a physical OS reboot.

The login registration is written/removed for the next login without changing the currently loaded runtime. A boot UUID plus login audit session identifies a checkbox edit: neither a recovery tick nor reopening the GUI may turn that future preference into a current-session Start. Explicit Start and reapply remain available with launch at login disabled. Separate tests cover these boundaries, registration failures, and the next-login transition.

Run the five tests on macOS with the native bridge available:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path macOSApp \
  --sdk "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path)" \
  --no-parallel --filter 'WallpaperSessionRegressionTests|NativeLockScreenSessionRegressionTests'
```

Prove that the tests detect their bugs:

```sh
AURAFLOW_DEDICATED_TEST_SESSION=1 python3 scripts/verify_session_regressions.py
```

The proof script copies the package to a temporary directory, checks a passing baseline, reintroduces each bug separately, requires a test assertion failure, restores the working code, and requires a passing final run. Build errors and crashes do not count as detecting a regression. All launchctl calls in the regression fixture are intercepted. It writes logs and `report.json` under `.build/session-regression-proof/`. The working checkout and installed application remain unchanged.

Video regression proof opens real test windows and requires a dedicated login session or CI. For a noninteractive Dock-only proof, run `python3 scripts/verify_session_regressions.py --core-only`; all process actions are recording closures and results are under `.build/session-regression-proof/core-only/`.

`DockRefreshRegressionTests` additionally requires all wallpaper refresh commands to leave Dock running. It verifies that isolated runtime stores cannot call the user's Desktop operations, while the canonical runtime can still use explicitly injected recovery operations.

`LockScreenFirstFrameHandoffTests` uses recording platform/bridge implementations without starting the application or creating windows. It requires source promotion before native Show, confirms a shield whose WindowServer state arrives slightly later without waiting for the two-second health timer, coalesces duplicate events, and preserves the disabled/unknown/unlocked safeguards.

`incompleteIsolatedGenerationRecoversWithoutRepeatingProviderRestarts` reproduces an unfinished install with stale Aura Desktop routes and a current user default. Temporary stores and recording provider actions cover Apply, health repair, and unlock rearm for both isolated Start and Lock-only. Recovery must retain the intended mode and media settings, restore the user's routes, finish the journal, and make subsequent health repairs no-ops.

The complete suite remains available through `scripts/test_macos_app.sh` in CI or with `AURAFLOW_DEDICATED_TEST_SESSION=1` in a dedicated macOS login session. It opens real AppKit windows and must not be run on an active user's desktop. Focused `DockRefreshRegressionTests` runs replace system actions with recording closures and do not open windows or restart any process.

Login restoration also covers both rendering engines:

Run the focused checks with `python3 scripts/test_login_restoration.py`.

- `LoginRestorationRegressionTests.swift` uses temporary configurations and recording launchctl operations to exercise a new login, legacy migration, one selected future login job, independent current playback, disabled startup, and bounded fallback after failure. The common `autostart` preference and `login_wallpaper_runtime` select the applied engine; preview drafts do not change that selection.
- `HiddenLoginPlaybackTests` decodes changing video pixels through the actual Desktop agent and checks late display enumeration, first-frame presentation, stale-command suppression, checkbox independence, and lock/unlock continuity. All window ordering is intercepted, so its test wallpaper never appears on the user's Desktop.
- `TerminalLoginRestorationTests` runs a real PTY/parser without display windows or secure presentation. Its startup must ignore old Stop/Restart/Update commands and keep publishing fresh frames. It also verifies that the copied login helper survives removal of the original application path, and that applying Terminal inherits the common login preference without a later checkbox edit restarting the current helper.

These focused login tests do not reboot or lock the Mac. A physical reboot remains a separate end-to-end verification on the installed application.
