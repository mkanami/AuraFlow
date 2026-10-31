import Foundation
import Testing
@testable import AuraTerminalWallpaperAgent

@MainActor private func settleAutomaticLock() async {
    for _ in 0..<20 { await Task.yield() }
}

@Suite(.serialized)
struct TerminalAutomaticLockTests {
    @Test(arguments: [false, true, nil] as [Bool?]) @MainActor
    func restoredHelperStartsWithTheConfirmedLockedPresentation(saverRunning: Bool?) async {
        var preparations: [Bool] = []
        var playback: [Bool] = []
        var starts = 0
        let presentation = TerminalLockScreenPresentation(sessionIsLocked: { true }, screenSaverIsRunning: { saverRunning },
            startScreenSaver: { starts += 1; return 0 }, presentationPreparer: { locked, _ in preparations.append(locked) })
        presentation.onLockStateChange = { playback.append($0) }
        defer { presentation.stop() }
        presentation.start()
        await settleAutomaticLock()
        #expect(preparations == [true], "A helper restored while locked must not first create an idle assertion")
        #expect(playback == [true], "The restored source must publish animation before another session notification or timer tick")
        #expect(starts == (saverRunning == true ? 0 : 1))
    }

    @Test(arguments: [false, true]) @MainActor
    func restoredHelperDefersUnknownSessionAndSharesRecoveryForManualAndAutomaticLocks(automatic: Bool) async {
        var locked: Bool?
        var running = automatic
        var now: TimeInterval = 100
        var preparations: [Bool] = []
        var playback: [Bool] = []
        var starts = 0
        let presentation = TerminalLockScreenPresentation(sessionIsLocked: { locked }, screenSaverIsRunning: { running },
            uptime: { now }, startScreenSaver: { starts += 1; running = true; return 0 },
            presentationPreparer: { locked, _ in preparations.append(locked) })
        presentation.onLockStateChange = { playback.append($0) }
        defer { presentation.stop() }
        presentation.start()
        await settleAutomaticLock()
        #expect(preparations.isEmpty && starts == 0, "An unknown session cannot authorize even an idle native assertion")
        #expect(playback == (automatic ? [true] : []))
        // Full power loss/login can lose every lock notification. A large
        // uptime gap and polling must recover the same locked source.
        now += 2 * 24 * 60 * 60
        locked = true
        presentation.pollSession()
        await settleAutomaticLock()
        #expect(preparations == [true])
        #expect(playback == [true])
        #expect(starts == (automatic ? 0 : 1))
        let count = preparations.count
        locked = nil
        presentation.recoverAfterSystemChange()
        await settleAutomaticLock()
        #expect(preparations.count == count)
        locked = true
        now += 1
        presentation.pollSession()
        await settleAutomaticLock()
        #expect(preparations.last == true)
        #expect(starts == (automatic ? 0 : 1), "Waking an existing saver must not start another one")
        locked = false
        running = false
        now += 2
        presentation.pollSession()
        await settleAutomaticLock()
        #expect(playback == [true, false])
        #expect(preparations.last == false)
    }

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

    @Test(arguments: [false, true]) @MainActor
    func repairingTheStoreDoesNotReplaceALiveLockedPresentationEverySecond(automatic: Bool) async {
        var locked = false, running = false, drift = false
        var now: TimeInterval = 100
        var starts = 0
        var lockedPreparations = 0
        let presentation = TerminalLockScreenPresentation(sessionIsLocked: { locked }, screenSaverIsRunning: { running },
            uptime: { now }, startScreenSaver: { starts += 1; running = true; return 0 },
            presentationPreparer: { locked, _ in if locked { lockedPreparations += 1 } }, routeRecovery: { drift })
        defer { presentation.stop() }
        presentation.start()
        await settleAutomaticLock()
        if automatic {
            running = true
            presentation.handleScreenSaverNotification(true)
            await settleAutomaticLock()
        }
        locked = true
        presentation.handleLockNotification(true)
        await settleAutomaticLock()
        presentation.handleScreenSaverNotification(true)
        await settleAutomaticLock()
        let prepared = lockedPreparations
        #expect(prepared == 1, "A saver-start event must retain the same locked presentation")
        // WallpaperAgent can flush its saved selection after the lock edge.
        // Repairing that file must not retire the live secure layer each tick.
        drift = true
        for _ in 0..<10 {
            now += 1
            presentation.pollSession()
            await settleAutomaticLock()
        }
        #expect(lockedPreparations == prepared)
        #expect(starts == (automatic ? 0 : 1))
        running = false
        presentation.handleScreenSaverNotification(false)
        await settleAutomaticLock()
        #expect(lockedPreparations == prepared && starts == (automatic ? 0 : 1),
            "An authentication-edge saver stop must not retire the secure presentation or start another saver")
        running = true
        presentation.handleScreenSaverNotification(true)
        await settleAutomaticLock()
        #expect(lockedPreparations == prepared)
        // A genuine wake/provider reconstruction still needs a new assertion.
        presentation.recoverAfterSystemChange()
        await settleAutomaticLock()
        #expect(lockedPreparations == prepared + 1)
        #expect(starts == (automatic ? 0 : 1))
    }

    @Test(arguments: [false, true]) @MainActor
    func aSlowLockedPresentationSurvivesRouteFlushesAndStillRetriesFailure(automatic: Bool) async {
        var locked = false, running = automatic
        var now: TimeInterval = 100
        var starts = 0, lockedPreparations = 0
        var held: CheckedContinuation<Void, Error>?
        let presentation = TerminalLockScreenPresentation(sessionIsLocked: { locked }, screenSaverIsRunning: { running },
            uptime: { now }, startScreenSaver: { starts += 1; running = true; return 0 },
            presentationPreparer: { locked, _ in
                if locked {
                    lockedPreparations += 1
                    if lockedPreparations == 1 { try await withCheckedThrowingContinuation { held = $0 } }
                }
            }, routeRecovery: { true })
        defer { presentation.stop() }
        presentation.start()
        await settleAutomaticLock()
        locked = true
        presentation.handleLockNotification(true)
        await settleAutomaticLock()
        #expect(held != nil)
        for _ in 0..<10 {
            now += 1
            presentation.pollSession()
            await settleAutomaticLock()
        }
        #expect(lockedPreparations == 1 && starts == 0)
        held?.resume(throwing: CocoaError(.fileReadUnknown))
        await settleAutomaticLock()
        now += 4
        presentation.pollSession()
        await settleAutomaticLock()
        #expect(lockedPreparations == 1 && starts == 0, "Store repairs must not bypass the failure backoff")
        now += 1
        presentation.pollSession()
        await settleAutomaticLock()
        #expect(lockedPreparations == 2)
        #expect(starts == (automatic ? 0 : 1))
        locked = false
        running = false
        presentation.handleLockNotification(false)
        await settleAutomaticLock()
        presentation.stop()
        presentation.start()
        await settleAutomaticLock()
        locked = true
        presentation.pollSession()
        await settleAutomaticLock()
        #expect(lockedPreparations == 3, "A stopped presenter must not retain the previous session request")
    }
}
