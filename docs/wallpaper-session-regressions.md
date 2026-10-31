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
- `terminalHelperUpdateRecognizesTheOldProcessAfterItsExecutableWasReplaced` runs a temporary copy of a command-line binary and atomically replaces its file. The production upgrade check must recognize the old process by its saved PID and start time, even when macOS can no longer resolve its removed executable path.

These focused login tests do not reboot or lock the Mac. A physical reboot remains a separate end-to-end verification on the installed application.

User wallpaper ownership is covered by the same focused runner:

- `UserWallpaperOwnershipTests.swift` requires complete native descriptors, including opaque automatic appearance options, to survive cleanup. An Aura Idle route cannot authorize rewriting a valid user Desktop. System preview files, unrelated metadata images, and missing backups cannot become wallpaper selections. A manual appearance change made while Aura is suspended remains a user change.
- `LockScreenSaverInstallerTests.swift` verifies that an absent or corrupt saved selection produces an error without choosing Ventura or changing the idle timeout. A recorded absence remains distinguishable from a missing backup.
- `TerminalScreenSaverStoreCoordinatorTests.swift` requires a new display to restore a known user Desktop; it must retain the current store and journal when no user selection is known, without restarting WallpaperAgent. Unresolved default placeholders cannot be restored as user choices.
- `terminalLockStartsAuraOnlyAfterItsLockedPresentationIsReady` holds the asynchronous Locked assertion and requires zero saver starts until readiness, followed by one start. Existing notification tests also require confirmation from WindowServer before treating the session as locked.

The focused runner skips `terminalDesktopRecoversExistingStaticWindow` and `terminalDisplayDisappearancePreservesLease`, which open real Desktop windows. They remain part of the complete suite for a dedicated session. Store and Screen Saver tests use temporary files and recording system operations.

Terminal's secure handoff has two additional suites in the focused runner:

- `TerminalNativeSurfaceHostingTests` runs the production presentation path with only opaque native assertion calls replaced. Every display's remote layer must be attached to a transparent host before the saver starts. Window ordering is intercepted. Arbitrary display arrangements, delayed display enumeration, failed replacement, unlock and Stop are covered; failed replacements retain the prior host, and late completions cannot start a saver after unlock.
- `TerminalLockScreenRouteTests` verifies the temporary live provider required by loginwindow's Desktop request. Complete user descriptors are saved before the lock-session store write and restored after unlock or interrupted login; manual user changes survive, cancellation cannot commit a promotion, and a corrupt snapshot cannot clear the Desktop to a system default. The combined native handoff test verifies route selection before both the Locked assertion and saver entry point, plus restoration on unlock and Stop.

Only a confirmed locked session with the owning Terminal helper and enabled Lock Screen playback may publish this temporary Desktop route. Its separate session journal is also consumed by source-failure recovery. The normal unlocked Desktop retains the user's native wallpaper choice underneath Aura's player; no still frame is installed as wallpaper.

Manual and automatic transitions are now paired parameters of `manualAndAutomaticLockUseTheSameLiveSourceAndRestoreUserChoices`. Automatic idle starts before CGSession's password lock: `TerminalAutomaticLockTests` requires frame publication during that grace period, no extra system saver start, polling recovery for lost start/stop notifications, and no restart when the OS saver stops just before unlock. Repeated route repairs and wake events while the saver is already active cannot start it again. Both event paths use the same reconciler and verify current loginwindow saver state rather than trusting a notification alone.

An OS saver-start notification does not prove that loginwindow has stopped requesting Desktop content. The temporary live Desktop route is retained throughout every confirmed secure lock, including an already-running automatic saver, and restored on confirmed unlock or Stop. Repeated health checks must not rewrite a current route or start another saver. The saver rendering probe also rejects stock procedural thumbnails and DefaultDesktop previews as user choices, including the automatic/dark appearance case. With no known user image, the orphaned view stays transparent while the session coordinator restores the real native provider. All probe paths and settings are isolated, and no test starts the real system saver.

`repairingTheStoreDoesNotReplaceALiveLockedPresentationEverySecond` reproduces repeated WallpaperAgent store flushes after both lock paths. Store repair and saver-start/stop notifications retain the same secure presentation, including an acquisition still in flight. `aSlowLockedPresentationSurvivesRouteFlushesAndStillRetriesFailure` requires the normal five-second retry after a failed acquisition, and resets request ownership across Stop/Start. Genuine wake or provider reconstruction can still replace the assertion. The native handoff matrix also writes the original user route back repeatedly and requires repair without detaching or replacing the hosted live layer, with login registration independently ON and OFF.

Terminal also receives the actual Darwin `sessionagent.shieldWindowRaised` signal, as the video agent does. A shield may precede WindowServer's locked flag; `anEarlyShieldSignalConfirmsTheSameLockBeforeTheSlowFallbackPoll` requires confirmation and presentation within 60 ms after that flag changes, without an explicit session poll. It covers direct lock and an already-running automatic saver. `darwinShieldSignalsUseTheSameConfirmedPresentationAndStopWithThePresenter` posts a unique test-only Darwin name through the real notification service and verifies both routes and cancellation. `anUnconfirmedShieldCannotSurviveUnlockOrStop` rejects delayed confirmation after either cancellation. No shield hint alone may start the saver, and confirmation is bounded to one second. These tests intercept presentation and system actions and never post real lock notifications.

The manual/automatic and login ON/OFF native matrix requires the confirmed lock to reuse the same prewarmed Idle display layer. Temporary Desktop promotion cannot retire that host or force a new display acquisition before starting the saver. A genuine wake or explicit source update still rebuilds the native display and releases the old host only after readiness.

`TerminalLoginLockIndependenceTests` runs a real PTY and PNG publisher with window creation disabled. Changing login registration in both directions must leave the pending command, prepared saver seed, frame bytes, child PID and Lock Screen preference intact. Compatibility metadata updates must also retain the seed. A Lock Screen sync reads the shared flag without carrying another terminal configuration. It is sent as `update` with no configuration so a helper from the previous app version also understands it; the agent still accepts `sync_lock_screen` from the intervening version. Ordinary updates carrying configuration do not reseed the source. The native handoff test covers the manual/automatic × login-enabled/disabled matrix, and the saver rendering probe checks all four combinations of the independent login and Lock Screen preferences.

`TerminalLockScreenToggleTests` uses an actual IOSurface to require repeated OFF/ON to reuse completed GPU pixels without waiting for PNG encoding. OFF revokes the publication immediately; ON republishes the verified live owner's lease. Unavailable surfaces, mismatched dimensions and foreign owners still require a prepared frame. Disabling during locked capture must reset that capture mode so enabling on the Desktop can seed again. The real-PTY test also exercises rapid OFF/ON with no intervening command restart or PNG. Paired native tests repeat the same transitions through direct lock, automatic saver/password grace, polling after missing notifications and wake, while retaining the user's full native wallpaper descriptors. UI tests require the latest requested toggle state to survive status polling and delayed provider responses; video and dedicated Lock Screen runtimes retain their selections across OFF/ON.

The unified fullscreen-control tests require the shared switch to read and update the applied engine, even when a different wallpaper is previewed or Terminal fields contain unapplied edits. An inactive Terminal preview can save that preference without starting anything; failed updates retain the confirmed state. `TerminalFullscreenRuntimeTests` runs a real PTY with window creation disabled and window metadata passed through the production geometry detector. Both native fullscreen and a maximized window leaving the menu bar, Dock and a small resize border must produce actual SIGSTOP/SIGCONT states. The test also requires animation to resume for Lock Screen capture, pause again on return to the covering app, resume when the window shrinks, and retain an explicit Stop when the checkbox is disabled. The same child PID, command launch count, prepared PNG and separate login/Lock Screen preferences must survive every policy change. Existing paired manual/automatic presentation tests verify the common capture callback. No test changes the user's foreground app or enters real fullscreen.

`FullscreenApplicationDetectorTests` exercises the shared video/Terminal detector with real WindowServer dictionary shapes. It covers native fullscreen, maximized working-area coverage, small resize gaps, non-covering large windows, background/transparent/overlay windows, invalid geometry, screens above and beside the main screen, side Dock insets and differing coordinate scales. Each screen's AppKit working area is converted to WindowServer coordinates; production contains no fixed display size, identifier or device assumption.

Coverage is independent of focus: all onscreen windows of visible regular applications are considered, while hidden applications and explicitly offscreen windows cannot hold the pause. `aCoveringWindowBehindTheFocusedAppStillPauses` requires both fullscreen and maximized background windows to keep the pause with either WindowServer stacking order. The real-PTY test places a small focused window ahead of the covering window, then requires resume when that covering window goes offscreen and pause when it returns. Existing Lock Screen resume, checkbox OFF/ON, resize, manual Stop, PID continuity and saved frame checks run through the same scenario.

Long-session and interrupted-login recovery has additional regressions:

- `recoveryKeepsALiveTerminalAfterItsExecutableWasReplaced` runs a temporary helper, atomically replaces its executable and uses the real saved PID/start identity. Background recovery must retain its Aura Idle routes across repeated checks, with autostart both ON and OFF and two-day-old publication timestamps. A mismatched identity from a previous process must still restore the recorded user routes. A missing `proc_pidpath` after replacement must never classify the verified live owner as dead.
- The Objective-C saver probe validates the same identity contract for fresh and reused saver views, unavailable executable paths, stale leases, malformed identities and legacy helpers. The saver and session recovery must agree about ownership; otherwise recovery repeatedly removes the route that the still-running helper repairs.
- `TerminalAutomaticLockTests` restores helpers when the session is already locked or WindowServer is not ready. The first confirmed assertion must use the real locked state immediately, with the same reconciler for manual lock, automatic password grace, lost notifications, wake and a two-day uptime gap. Unknown state cannot create an unconfirmed idle assertion or start the system saver.
- Deferred-upgrade tests require a GUI left open while locked/paused to finish its update after unlock/resume, including a missed wake notification. Healthy polling does not rearm providers. Missing startup health is deferred, a late first frame or provider failure retains pending rearm work without another helper replacement, and in-flight Stopped status snapshots cannot trigger a second provider restart after the upgrade.

All of these regressions run through `scripts/test_login_restoration.py` with temporary stores and intercepted platform operations. They simulate the lifecycle boundaries without locking, rebooting, or changing the active user's wallpaper settings. A physical shutdown/reboot and the secure compositor's displayed pixels remain separate end-to-end checks on the installed application.
