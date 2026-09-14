import Testing
@testable import AuraWallpaperAgent

@MainActor
@Test func lockOnlyResumeKeepsPausedFrameUntilAnimatedGenerationIsReady() async throws {
    var events: [String] = []

    let restored = try await LockScreenPlaybackResumeHandoff.complete {
        events.append("restore-animation")
        return true
    } isCurrent: {
        events.append("validate-resume")
        return true
    } revealAnimatedSurface: {
        events.append("reveal-animation")
    }

    #expect(restored)
    #expect(
        events == [
            "restore-animation",
            "validate-resume",
            "reveal-animation",
        ]
    )
}

@MainActor
@Test func supersededLockOnlyResumeNeverRevealsTransitionFrame() async throws {
    var revealed = false

    await #expect(throws: CancellationError.self) {
        _ = try await LockScreenPlaybackResumeHandoff.complete {
            true
        } isCurrent: {
            false
        } revealAnimatedSurface: {
            revealed = true
        }
    }

    #expect(!revealed)
}

@MainActor
@Test func failedLockOnlyRestoreKeepsPausedFrameVisible() async throws {
    struct RestoreFailure: Error {}
    var revealed = false

    await #expect(throws: RestoreFailure.self) {
        _ = try await LockScreenPlaybackResumeHandoff.complete {
            throw RestoreFailure()
        } isCurrent: {
            true
        } revealAnimatedSurface: {
            revealed = true
        }
    }

    #expect(!revealed)
}
