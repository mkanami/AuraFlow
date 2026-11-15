import AppKit
import AuraTerminalWallpaperCore
import Foundation
import ImageIO
import Testing
@testable import AuraTerminalWallpaperAgent

@Test func terminalLockOnlyConfigurationMigratesOldPresetsAndSurvivesRelaunch() throws {
    let old = Data(#"{"launchAtLogin":false,"allDisplays":true,"pauseOnFullscreen":true}"#.utf8)
    let behavior = try JSONDecoder().decode(TerminalWallpaperBehavior.self, from: old)
    #expect(!behavior.lockScreenOnly)
    var config = TerminalWallpaperConfig.defaultConfig
    config.behavior.lockScreenOnly = true
    let restored = try JSONDecoder().decode(TerminalWallpaperConfig.self, from: JSONEncoder().encode(config))
    #expect(restored.normalized().behavior.lockScreenOnly)
}

@Suite(.serialized)
struct TerminalLockOnlyTests {
    @Test(arguments: ["manual", "os-idle", "missing-notification", "delayed-notification"])
    @MainActor func hiddenProducerPublishesThroughLocksSleepWakeAndUnlock(scenario: String) async throws {
        _ = NSApplication.shared
        let screens = NSScreen.screens
        try #require(!screens.isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalLockOnly-\(UUID())")
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal-wallpaper"),
            launchAgentURL: root.appendingPathComponent("LaunchAgents/test.plist"))
        let config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh", arguments: ["-c",
            "printf x >> starts; n=0; while :; do printf '\\033[44m\\033[Hframe %s' \"$n\"; n=$((n+1)); sleep 0.05; done"],
            workingDirectory: root.path),
            render: .init(pixelMode: .fixed, fixedWidth: 320, fixedHeight: 240, columns: 20, rows: 4, maxFPS: 15),
            behavior: .init(allDisplays: false, pauseOnFullscreen: false, lockScreenOnly: true))
        try store.saveConfig(config)
        var availableScreens = screens
        var desktopOrders = 0
        let agent = TerminalWallpaperAgentDelegate(configurationURL: store.configURL, managesLockScreenPresentation: false,
            screensProvider: { availableScreens }, desktopWindowPresenter: { _ in desktopOrders += 1 })
        var locked: Bool? = false
        var saverRunning = false
        var saverStarts = 0
        var preparations: [Bool] = []
        var playbackActivity: [Bool] = []
        let presentation = TerminalLockScreenPresentation(sessionIsLocked: { locked }, screenSaverIsRunning: { saverRunning },
            startScreenSaver: { saverStarts += 1; return 0 }, presentationPreparer: { active, _ in preparations.append(active) },
            routeRecovery: { false }, restoreUserDesktop: {})
        presentation.onLockStateChange = {
            playbackActivity.append($0)
            agent.lockScreenStateChanged($0)
        }
        defer {
            presentation.stop()
            agent.applicationWillTerminate(.init(name: NSApplication.willTerminateNotification))
            try? FileManager.default.removeItem(at: root)
        }
        agent.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        presentation.start()
        func until(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() {
                try #require(Date() < deadline)
                pumpLockOnlyAppKit()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await until { store.loadSharedFrameDescriptor() != nil && store.loadLockScreenHeartbeat() != nil }
        let child = try #require(store.loadHealth()?.childPID)
        #expect(desktopOrders == 0)
        if scenario == "os-idle" {
            saverRunning = true
            presentation.handleScreenSaverNotification(true)
            try await until { playbackActivity.last == true }
            #expect(preparations.last == false, "The idle saver is still an unlocked presentation")
            #expect(saverStarts == 0, "An idle saver never authorizes locking an unlocked Mac")
        }
        locked = true
        if scenario == "manual" || scenario == "os-idle" { presentation.handleLockNotification(true) }
        else { presentation.pollSession() }
        try await until { preparations.last == true }
        if scenario == "delayed-notification" { presentation.handleLockNotification(true) }
        let source = try #require(CGImageSourceCreateWithURL(store.lockScreenFrameURL as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 320 && image.height == 240)
        availableScreens = []
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(store.loadSharedFrameDescriptor() != nil)
        let previousSurface = store.loadSharedFrameDescriptor()
        availableScreens = screens
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await until { store.loadSharedFrameDescriptor() != previousSurface }
        saverRunning = false
        locked = false
        presentation.handleLockNotification(false)
        presentation.handleScreenSaverNotification(false)
        presentation.pollSession()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try await until { preparations.last == false }
        #expect(store.loadHealth()?.childPID == child)
        #expect(desktopOrders == 0, "Lock-only must never order Desktop windows, including after wake/unlock")
        #expect(try String(contentsOf: root.appendingPathComponent("starts"), encoding: .utf8) == "x")
    }
}

@MainActor private func pumpLockOnlyAppKit() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
