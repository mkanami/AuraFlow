# Wallpaper session regression tests

These four regressions are covered by executable tests, with one test per reported issue:

| Issue | Test | Required behavior |
| --- | --- | --- |
| Repeated unwanted locks | `issue1PreparedHelperNeverRelocksAfterStaleShowsOrLateRecovery` | An already prepared helper receives a delayed assertion completion after unlock and 1,000 stale Show requests. It retains a usable surface and never starts the saver for an unlocked session. |
| Cached still frame after login | `issue2LoginStartsDecodedAnimationInsteadOfLeavingCachedStillFrame` | A fresh agent loads persisted autostart settings, an existing first-frame cache, and a stale Pause command. Its actual AVQueuePlayer decodes frames, advances time, and attaches ready AVPlayerLayers without a GUI Start action. |
| Desktop animation stops after unlock | `issue3UnlockResumesDecodedAnimationAfterSystemSuspendsDesktopPlayer` | Across five lock/unlock cycles, the real Desktop player is paused at the system boundary, resumes decoding after unlock, and retains the same player and layers. Health polling while locked never replaces the player. |
| Missing Aura on the Lock Screen | `issue4LockScreenWaitsForPreparedSecureSurfaceAfterLogin` | Both direct Show and recovery after a missed lock notification wait for the asynchronous Locked assertion before starting the saver or reporting readiness. Duplicate lock events reuse the committed surface. |

The Desktop tests use a generated moving H.264 fixture and require two decoded frames with different pixels, advancing playback time, visible windows, and `AVPlayerLayer.isReadyForDisplay`. They do not treat a nonzero player rate as proof of animation.

The native tests run the production presentation queue and bridge state handling. Only the opaque system assertion creation and saver entry point are replaced with a controlled asynchronous driver. Session state and settings are isolated; the tests never lock the real Mac or change its wallpaper, login agents, or Screen Saver preferences. This proves application ordering and recovery, not the pixels drawn by Apple's secure compositor or a physical OS reboot.

Run the four tests on macOS with the native bridge available:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path macOSApp \
  --sdk "$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path)" \
  --no-parallel --filter 'WallpaperSessionRegressionTests|NativeLockScreenSessionRegressionTests'
```

Prove that the tests detect their bugs:

```sh
python3 scripts/verify_session_regressions.py
```

The proof script copies the package to a temporary directory, checks a passing baseline, reintroduces each bug separately, requires a test assertion failure, restores the working code, and requires a passing final run. Build errors and crashes do not count as detecting a regression. It writes logs and `report.json` under `.build/session-regression-proof/`. The working checkout and installed application remain unchanged.

The complete suite, including these regressions, remains available through `scripts/test_macos_app.sh`.
