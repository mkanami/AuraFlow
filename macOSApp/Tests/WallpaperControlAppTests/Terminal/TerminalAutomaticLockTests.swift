import Foundation
import Testing
@testable import AuraTerminalWallpaperAgent

@MainActor private func settleAutomaticLock() async {
    for _ in 0..<20 { await Task.yield() }
}

@Suite(.serialized)
struct TerminalAutomaticLockTests {
    @Test @MainActor
    func automaticSaverPublishesAnimationBeforePasswordLockWithoutStartingAnotherSaver() async {
        var locked = false, running = false
        var starts = 0
        var playback: [Bool] = []
        let presentation = TerminalLockScreenPresentation(sessionIsLocked: { locked }, screenSaverIsRunning: { running },
            startScreenSaver: { starts += 1; return 0 }, presentationPreparer: { _, _ in })
        presentation.onLockStateChange = { playback.append($0) }
        defer { presentation.stop() }
        presentation.start()
        await settleAutomaticLock()
        running = true
        presentation.handleScreenSaverNotification(true)
        await settleAutomaticLock()
        #expect(playback == [true], "Automatic animation begins while the OS password grace period is still unlocked")
        #expect(starts == 0)
        locked = true
        presentation.handleLockNotification(true)
        await settleAutomaticLock()
        #expect(playback == [true])
        #expect(starts == 0, "The OS already started this saver")
        running = false
        presentation.handleScreenSaverNotification(false)
        await settleAutomaticLock()
        #expect(starts == 0, "Saver stop can precede the CGSession unlock; never restart it at that edge")
        locked = false
        presentation.handleLockNotification(false)
        await settleAutomaticLock()
        #expect(playback == [true, false])
    }

    @Test @MainActor
    func missedAutomaticStartAndStopNotificationsAreReconciledByPolling() async {
        var running = false
        var now: TimeInterval = 100
        var playback: [Bool] = []
        let presentation = TerminalLockScreenPresentation(sessionIsLocked: { false }, screenSaverIsRunning: { running },
            uptime: { now }, startScreenSaver: { Issue.record("Polling an unlocked automatic saver must never lock the Mac"); return 0 },
            presentationPreparer: { _, _ in })
        presentation.onLockStateChange = { playback.append($0) }
        defer { presentation.stop() }
        presentation.start()
        await settleAutomaticLock()
        running = true
        now += 1
        presentation.pollSession()
        await settleAutomaticLock()
        #expect(playback == [true])
        running = false
        now += 1
        presentation.pollSession()
        await settleAutomaticLock()
        #expect(playback == [true, false])
        presentation.handleScreenSaverNotification(true)
        await settleAutomaticLock()
        #expect(playback == [true, false], "A stale notification cannot override the current OS state")
    }

    @Test @MainActor
    func routeRepairsAndWakeNeverRepeatedlyStartAnAlreadyRunningAutomaticSaver() async {
        var locked = false, running = false
        var starts = 0
        var now: TimeInterval = 100
        let presentation = TerminalLockScreenPresentation(sessionIsLocked: { locked }, screenSaverIsRunning: { running },
            uptime: { now }, startScreenSaver: { starts += 1; return 0 }, presentationPreparer: { _, _ in }, routeRecovery: { true })
        defer { presentation.stop() }
        presentation.start()
        await settleAutomaticLock()
        running = true
        locked = true
        presentation.handleScreenSaverNotification(true)
        presentation.handleLockNotification(true)
        await settleAutomaticLock()
        for _ in 0..<100 {
            now += 5
            presentation.pollSession()
            presentation.recoverAfterSystemChange()
            await settleAutomaticLock()
        }
        #expect(starts == 0)
    }
}
