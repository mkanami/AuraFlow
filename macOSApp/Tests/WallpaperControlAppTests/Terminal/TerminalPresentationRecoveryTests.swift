import AppKit
import AuraTerminalWallpaperCore
import Foundation
import Testing
@testable import AuraTerminalWallpaperAgent

@MainActor
private final class PresentationRecoveryFixture {
    var locked: Bool? = false
    var now: TimeInterval = 100
    var starts = 0
    var startResult: Int32 = 0
    var failures = 0
    var preparations: [(locked: Bool, reload: Bool)] = []
    var transitions: [Bool] = []

    lazy var presentation: TerminalLockScreenPresentation = {
        let presentation = TerminalLockScreenPresentation(
            sessionIsLocked: { [unowned self] in locked },
            uptime: { [unowned self] in now },
            startScreenSaver: { [unowned self] in starts += 1; return startResult },
            presentationPreparer: { [unowned self] locked, reload in
                preparations.append((locked, reload))
                if failures > 0 {
                    failures -= 1
                    throw CocoaError(.fileReadUnknown)
                }
            }
        )
        presentation.onLockStateChange = { [unowned self] in transitions.append($0) }
        return presentation
    }()

    func settle() async {
        // All injected operations are immediate, but preparation runs in a Task.
        for _ in 0..<10 { await Task.yield() }
    }
}

@Suite(.serialized)
struct TerminalPresentationRecoveryTests {
    @Test @MainActor func terminalPresentationRecoversAfterDaysOfLockedSleepWithoutAnotherLockTransition() async {
        let fixture = PresentationRecoveryFixture()
        let presentation = fixture.presentation
        defer { presentation.stop() }
        presentation.start()
        await fixture.settle()
        fixture.locked = true
        presentation.handleLockNotification(true)
        await fixture.settle()
        #expect(fixture.starts == 1)
        #expect(fixture.transitions == [true])

        fixture.now += 3 * 24 * 60 * 60
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        await fixture.settle()
        #expect(fixture.starts == 2)
        #expect(fixture.transitions == [true])
        #expect(fixture.preparations.last?.locked == true)
        #expect(fixture.preparations.last?.reload == true)

        presentation.stop()
        let preparations = fixture.preparations.count
        fixture.now += 100
        presentation.recoverAfterSystemChange()
        presentation.pollSession()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fixture.settle()
        #expect(fixture.starts == 2)
        #expect(fixture.preparations.count == preparations)
    }

    @Test @MainActor func terminalPresentationWakeNeverStartsSaverForUnlockedOrUnknownSession() async {
        let fixture = PresentationRecoveryFixture()
        let presentation = fixture.presentation
        defer { presentation.stop() }
        presentation.start()
        await fixture.settle()
        presentation.recoverAfterSystemChange()
        await fixture.settle()
        fixture.locked = nil
        presentation.recoverAfterSystemChange()
        await fixture.settle()
        #expect(fixture.starts == 0)
        #expect(fixture.transitions.isEmpty)
    }

    @Test @MainActor func terminalPresentationRetriesTransientFailureWithFreshSystemAssertions() async {
        let fixture = PresentationRecoveryFixture()
        let presentation = fixture.presentation
        defer { presentation.stop() }
        fixture.failures = 2
        presentation.start()
        await fixture.settle()
        #expect(fixture.preparations.count == 1)
        fixture.now += 4
        presentation.pollSession()
        await fixture.settle()
        #expect(fixture.preparations.count == 1)
        fixture.now += 1
        presentation.pollSession()
        await fixture.settle()
        #expect(fixture.preparations.count == 2)
        #expect(fixture.preparations.last?.reload == true)
        fixture.now += 5
        presentation.pollSession()
        await fixture.settle()
        #expect(fixture.preparations.count == 3)
        fixture.now += 24 * 60 * 60
        presentation.pollSession()
        await fixture.settle()
        #expect(fixture.preparations.count == 3)
        #expect(fixture.starts == 0)
    }

    @Test @MainActor func terminalPresentationRetriesFailedSaverStartAndStopsRetryingAfterSuccess() async {
        let fixture = PresentationRecoveryFixture()
        let presentation = fixture.presentation
        defer { presentation.stop() }
        presentation.start()
        await fixture.settle()
        fixture.locked = true
        fixture.startResult = 1
        presentation.handleLockNotification(true)
        await fixture.settle()
        #expect(fixture.starts == 1)
        fixture.startResult = 0
        fixture.now += 5
        presentation.pollSession()
        await fixture.settle()
        #expect(fixture.starts == 2)
        fixture.now += 100
        presentation.pollSession()
        await fixture.settle()
        #expect(fixture.starts == 2)
    }

    @Test @MainActor func terminalPresentationReconcilesMissedUnlockAfterNotificationGracePeriod() async {
        let fixture = PresentationRecoveryFixture()
        let presentation = fixture.presentation
        defer { presentation.stop() }
        presentation.start()
        await fixture.settle()
        fixture.locked = true
        presentation.handleLockNotification(true)
        await fixture.settle()
        fixture.locked = false
        presentation.pollSession()
        #expect(fixture.transitions == [true])
        fixture.now += 1.1
        presentation.pollSession()
        await fixture.settle()
        #expect(fixture.transitions == [true, false])
        #expect(fixture.preparations.last?.locked == false)
        #expect(fixture.starts == 1)
    }

    @Test(arguments: [false, true]) @MainActor
    func terminalPresentationLateRecoveryCannotRestartSaverAfterUnlockOrStop(stop: Bool) async {
        var locked = false
        var starts = 0
        var continuation: CheckedContinuation<Void, Error>?
        let presentation = TerminalLockScreenPresentation(
            sessionIsLocked: { locked }, startScreenSaver: { starts += 1; return 0 },
            presentationPreparer: { _, reload in
                if reload { try await withCheckedThrowingContinuation { continuation = $0 } }
            }
        )
        defer { presentation.stop() }
        presentation.start()
        for _ in 0..<10 { await Task.yield() }
        locked = true
        presentation.recoverAfterSystemChange()
        for _ in 0..<10 { await Task.yield() }
        #expect(continuation != nil)
        if stop { presentation.stop() }
        else {
            locked = false
            presentation.handleLockNotification(false)
        }
        continuation?.resume()
        for _ in 0..<10 { await Task.yield() }
        #expect(starts == 0)
    }

    @Test @MainActor func terminalWakeDefersUnknownSessionWithoutReplacingItsSurface() async {
        let fixture = PresentationRecoveryFixture()
        let presentation = fixture.presentation
        defer { presentation.stop() }
        presentation.start()
        await fixture.settle()
        fixture.locked = true
        presentation.handleLockNotification(true)
        await fixture.settle()
        let count = fixture.preparations.count
        fixture.locked = nil
        presentation.recoverAfterSystemChange()
        presentation.handleLockNotification(false)
        await fixture.settle()
        #expect(fixture.preparations.count == count)
        #expect(fixture.transitions == [true])
        fixture.locked = true
        presentation.pollSession()
        await fixture.settle()
        #expect(fixture.preparations.count == count + 1)
        #expect(fixture.preparations.last?.locked == true)
        #expect(fixture.preparations.last?.reload == true)
        #expect(fixture.starts == 2)
    }

    @Test @MainActor func terminalUnlockNotificationCannotReleaseStillLockedSurface() async {
        let fixture = PresentationRecoveryFixture()
        let presentation = fixture.presentation
        defer { presentation.stop() }
        presentation.start()
        await fixture.settle()
        fixture.locked = true
        presentation.handleLockNotification(true)
        await fixture.settle()
        let count = fixture.preparations.count
        presentation.handleLockNotification(false)
        presentation.pollSession()
        await fixture.settle()
        #expect(fixture.preparations.count == count)
        #expect(fixture.transitions == [true])
        fixture.locked = false
        presentation.pollSession()
        await fixture.settle()
        #expect(fixture.transitions == [true, false])
    }

    @Test @MainActor func terminalWakeDoesNotOverrideShieldWhileWindowServerLockStateLags() async {
        let fixture = PresentationRecoveryFixture()
        let presentation = fixture.presentation
        defer { presentation.stop() }
        presentation.start()
        await fixture.settle()
        // The secure shield notification leads CGSession at the lid edge.
        presentation.handleLockNotification(true)
        await fixture.settle()
        let count = fixture.preparations.count
        presentation.recoverAfterSystemChange()
        presentation.pollSession()
        await fixture.settle()
        #expect(fixture.preparations.count == count)
        #expect(fixture.transitions.isEmpty)
        #expect(fixture.starts == 0)
        fixture.locked = true
        presentation.pollSession()
        await fixture.settle()
        #expect(fixture.transitions == [true])
        #expect(fixture.preparations.last?.locked == true)
        #expect(fixture.starts == 1)
    }

    @Test(arguments: [false, nil] as [Bool?]) @MainActor
    func terminalStaleLockNotificationsNeverStartSaverOnActiveOrUnknownSession(locked: Bool?) async {
        let fixture = PresentationRecoveryFixture()
        fixture.locked = locked
        let presentation = fixture.presentation
        defer { presentation.stop() }
        presentation.start()
        await fixture.settle()
        for _ in 0..<100 {
            presentation.handleLockNotification(true)
            fixture.now += 5
            presentation.pollSession()
            await fixture.settle()
        }
        #expect(fixture.starts == 0)
    }

    @Test @MainActor func terminalDesktopRecoversExistingStaticWindowAfterSpaceAndWakeWithoutRerunningCommand() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraPresentationRecovery-\(UUID())")
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("launch.plist"))
        let config = TerminalWallpaperConfig(
            command: .init(executable: "/bin/sh", arguments: ["-c", "printf x >> '\(root.path)/launches'; printf 'retained wallpaper'"]),
            render: .init(pixelMode: .fixed, fixedWidth: 320, fixedHeight: 240, columns: 30, rows: 4),
            behavior: .init(allDisplays: false, pauseOnFullscreen: false)
        )
        try store.saveConfig(config)
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let delegate = TerminalWallpaperAgentDelegate(configurationURL: store.configURL, managesLockScreenPresentation: false)
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            try? FileManager.default.removeItem(at: root)
        }
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let window = try #require(NSApp.windows.first { $0 is TerminalWallpaperWindow && !previousWindows.contains(ObjectIdentifier($0)) })
        let deadline = Date().addingTimeInterval(5)
        while store.loadHealth()?.childRunning != false || store.loadSharedFrameDescriptor() == nil {
            try #require(Date() < deadline)
            pumpPresentationRecoveryAppKit()
            try await Task.sleep(for: .milliseconds(10))
        }
        let surface = try #require(store.loadSharedFrameDescriptor())
        try store.setPlaybackPaused(true)
        try store.saveCommand(.init(action: .pause, config: config))
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            window.orderOut(nil)
            #expect(!window.isVisible)
            NSWorkspace.shared.notificationCenter.post(name: name, object: nil)
            pumpPresentationRecoveryAppKit()
            #expect(window.isVisible)
            #expect(store.loadSharedFrameDescriptor() == surface)
            #expect(store.isPlaybackPaused)
        }
        #expect(try String(contentsOf: root.appendingPathComponent("launches")) == "x")
    }

    @Test(arguments: [false, true]) @MainActor
    func terminalRouteDriftRebindsPresentationWithoutAnotherSessionEvent(locked: Bool) async {
        var now: TimeInterval = 100
        var sessionLocked = false
        var drifted = false
        var repairs = 0
        var starts = 0
        var preparations: [(Bool, Bool)] = []
        let presentation = TerminalLockScreenPresentation(sessionIsLocked: { sessionLocked },
            uptime: { now },
            startScreenSaver: { starts += 1; return 0 },
            presentationPreparer: { preparations.append(($0, $1)) },
            routeRecovery: {
                guard drifted else { return false }
                drifted = false
                repairs += 1
                return true
            })
        defer { presentation.stop() }
        presentation.start()
        for _ in 0..<20 { await Task.yield() }
        if locked {
            sessionLocked = true
            presentation.handleLockNotification(true)
            for _ in 0..<20 { await Task.yield() }
        }
        let previousStarts = starts
        drifted = true
        now += 1
        presentation.pollSession()
        for _ in 0..<20 { await Task.yield() }
        #expect(repairs == 1)
        #expect(preparations.last?.0 == locked)
        #expect(preparations.last?.1 == true)
        #expect(starts == previousStarts, "A repaired route must not restart the saver repeatedly in the same lock session")
    }

    @Test(arguments: [false, true]) @MainActor
    func terminalDisplayDisappearancePreservesLeaseAndSurfaceUntilReplacementCompletes(staticCommand: Bool) async throws {
        _ = NSApplication.shared
        let actualScreens = NSScreen.screens
        try #require(!actualScreens.isEmpty)
        var screens = actualScreens
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraLidFrame-\(UUID())")
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("launch.plist"))
        let command = staticCommand ? "printf 'retained still'" : "while :; do printf '\\033[Hretained live'; sleep 0.05; done"
        let config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh", arguments: ["-c", command]),
            render: .init(pixelMode: .fixed, fixedWidth: 320, fixedHeight: 240, columns: 30, rows: 4),
            behavior: .init(allDisplays: false, pauseOnFullscreen: false))
        try store.saveConfig(config)
        let delegate = TerminalWallpaperAgentDelegate(configurationURL: store.configURL,
            managesLockScreenPresentation: false, screensProvider: { screens })
        defer {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            try? FileManager.default.removeItem(at: root)
        }
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let deadline = Date().addingTimeInterval(5)
        while store.loadSharedFrameDescriptor() == nil || store.loadLockScreenHeartbeat() == nil {
            try #require(Date() < deadline)
            pumpPresentationRecoveryAppKit()
            try await Task.sleep(for: .milliseconds(10))
        }
        let surface = try #require(store.loadSharedFrameDescriptor())
        let child = store.loadHealth()?.childPID
        screens = []
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(store.loadSharedFrameDescriptor() == surface)
        #expect(store.loadLockScreenHeartbeat()?.pid == Int(getpid()))
        #expect(FileManager.default.fileExists(atPath: store.lockScreenFrameURL.path))
        screens = actualScreens
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // No new GPU callback has run yet. The old cross-process source must
        // still be published and retained, including for a completed command.
        #expect(store.loadSharedFrameDescriptor() == surface)
        let replacementDeadline = Date().addingTimeInterval(5)
        while store.loadSharedFrameDescriptor() == surface {
            try #require(Date() < replacementDeadline)
            pumpPresentationRecoveryAppKit()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.loadLockScreenHeartbeat()?.pid == Int(getpid()))
        if !staticCommand { #expect(store.loadHealth()?.childPID == child) }
    }

}

@MainActor private func pumpPresentationRecoveryAppKit() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}

@Test @MainActor
func terminalLockStartsAuraOnlyAfterItsLockedPresentationIsReady() async {
    var locked = false
    var starts = 0
    var held: CheckedContinuation<Void, Never>?
    let presentation = TerminalLockScreenPresentation(sessionIsLocked: { locked },
        startScreenSaver: { starts += 1; return 0 }, presentationPreparer: { isLocked, _ in
            if isLocked { await withCheckedContinuation { held = $0 } }
        })
    defer { presentation.stop() }
    presentation.start()
    for _ in 0..<10 { await Task.yield() }
    locked = true
    presentation.handleLockNotification(true)
    for _ in 0..<10 { await Task.yield() }
    #expect(held != nil)
    #expect(starts == 0, "Starting the saver against Idle can display the system wallpaper instead of Aura")
    held?.resume()
    for _ in 0..<10 { await Task.yield() }
    #expect(starts == 1)
}
