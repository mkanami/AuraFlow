@testable import AuraTerminalWallpaperAgent
import Testing

@Test func terminalFullscreenResumesOnFirstUncoveredSampleWithoutClearingManualStop() {
    var policy = TerminalFullscreenPausePolicy()
    policy.manuallyPaused = true
    _ = policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: true)
    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: true) == true)
    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: false) == false)
    #expect(!policy.isPaused && policy.playbackIsPaused)
}

@Test func terminalFullscreenPauseDebouncesAndResumesForLockScreen() {
    var policy = TerminalFullscreenPausePolicy()

    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: true) == nil)
    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: true) == true)
    #expect(policy.isPaused)

    // Lock Screen presentation must keep the same child animated.
    #expect(policy.update(enabled: true, screenLocked: true, foregroundIsFullscreen: true) == false)
    #expect(!policy.isPaused)

    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: true) == nil)
    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: true) == true)
    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: false) == false)
    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: false) == nil)
}

@Test func terminalFullscreenPauseCanBeDisabledWithoutLosingPauseState() {
    var policy = TerminalFullscreenPausePolicy()
    _ = policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: true)
    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: true) == true)
    #expect(policy.update(enabled: false, screenLocked: false, foregroundIsFullscreen: true) == false)
    #expect(!policy.isPaused)
}

@Test func terminalFullscreenPauseCanRetryAfterAProcessSignalFails() {
    var policy = TerminalFullscreenPausePolicy()
    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: true) == nil)
    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: true) == true)

    policy.restoreAfterFailedProcessSignal(to: false)
    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: true) == nil)
    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: true) == true)
}
