import Foundation
import AuraTerminalWallpaperCore
import Testing
@testable import AuraWallpaperCore

private final class SessionRecoveryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperAccount-\(UUID())")
    let store: WallpaperRuntimeStore
    let index: URL
    let journal: URL
    var live = false
    var locked: Bool? = false
    var waits = 0
    var onWait: (() -> Void)?
    var refreshes = 0
    var nativeCalls = 0
    var startRequests = 0
    var onStart: (() -> Void)?

    init(runtime: String = "terminal-wallpaper") throws {
        store = WallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("AuraFlow"),
            launchAgentURL: root.appendingPathComponent("LaunchAgents/media.plist"))
        index = root.appendingPathComponent("Index.plist")
        journal = store.appSupportURL.appendingPathComponent(runtime).appendingPathComponent("screen-saver-wallpaper-store-backup.json")
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"routes\":[]}".utf8).write(to: journal)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: journal.path)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func mode(_ provider: String) -> [String: Any] {
        ["Content": ["Choices": [["Provider": provider, "Files": []]]]]
    }

    func auraMode() throws -> [String: Any] {
        let saver = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/AuraFlowLockScreen.saver")
        let config = try PropertyListSerialization.data(fromPropertyList: ["module": ["relative": saver.absoluteString]], format: .binary, options: 0)
        return ["Content": ["Choices": [["Provider": WallpaperPlatformConstants.screenSaverProviderID, "Configuration": config]]]]
    }

    func save(_ value: [String: Any]) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: index, options: .atomic)
    }

    func load() throws -> [String: Any] {
        try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: index), format: nil) as? [String: Any])
    }

    func recovery(sessionIdentifier: String? = LockScreenSession.currentIdentifier()) -> WallpaperSessionRecovery {
        WallpaperSessionRecovery(store: store, wallpaperStoreURL: index,
            runtimeIsLive: { self.live }, sessionIsLocked: { self.locked },
            wait: { _ in self.waits += 1; self.onWait?() },
            requestAutostart: { self.startRequests += 1; self.onStart?() },
            suspendNative: { proceed in self.nativeCalls += 1; #expect(proceed()); return false },
            refresh: { commit in self.refreshes += 1; try commit() },
            sessionIdentifier: { sessionIdentifier })
    }
}

@Test func loginCheckboxOnlyAffectsRecoveryInTheNextSession() throws {
    let f = try SessionRecoveryFixture()
    let desktop = f.mode("user-provider")
    try f.save(["SystemDefault": ["Desktop": desktop, "Idle": desktop]])
    let source = f.root.appendingPathComponent("source.mp4")
    try Data("video".utf8).write(to: source)
    try f.store.saveConfig(.init(video_path: source.path, playback_speed: 1, autostart: true,
        autostart_deferred_session_id: "boot-A:session-A"))
    #expect(try f.recovery(sessionIdentifier: "boot-A:session-A").reconcile() == .notNeeded)
    #expect(f.startRequests == 0)
    #expect(f.waits == 0)
    f.onStart = { [weak f] in f?.live = true }
    #expect(try f.recovery(sessionIdentifier: "boot-B:session-A").reconcile() == .runtimeActive)
    #expect(f.startRequests == 1)
    #expect(f.refreshes == 0)
}

@Test(arguments: ["terminal-wallpaper", "wallpaper-engine/runtime"])
func inactiveSessionRestoresEachUserProviderAcrossDisplaysAndSpaces(runtime: String) throws {
    let f = try SessionRecoveryFixture(runtime: runtime)
    let photo = f.mode("custom-photo-provider"), dynamic = f.mode("custom-dynamic-provider"), aura = try f.auraMode()
    try f.save([
        "AllSpacesAndDisplays": ["Idle": aura],
        "SystemDefault": ["Desktop": photo, "Idle": aura],
        "Displays": ["one": ["Desktop": photo, "Idle": aura], "two": ["Desktop": dynamic, "Idle": aura]],
        "Spaces": ["space": ["Default": ["Desktop": dynamic, "Idle": aura]]],
    ])
    #expect(try f.recovery().reconcile() == .restored)
    let root = try f.load()
    let displays = try #require(root["Displays"] as? [String: [String: Any]])
    #expect((displays["one"]?["Idle"] as? NSDictionary) == photo as NSDictionary)
    #expect((displays["two"]?["Idle"] as? NSDictionary) == dynamic as NSDictionary)
    #expect((displays["two"]?["Desktop"] as? NSDictionary) == dynamic as NSDictionary)
    let spaces = try #require(root["Spaces"] as? [String: [String: [String: Any]]])
    #expect((spaces["space"]?["Default"]?["Idle"] as? NSDictionary) == dynamic as NSDictionary)
    #expect(f.waits == 0)
    #expect(f.refreshes == 1)
    #expect(FileManager.default.fileExists(atPath: f.journal.path))
    #expect(try f.recovery().reconcile() == .notNeeded)
    #expect(f.refreshes == 1)
    // A delayed or manually started helper can reclaim only the routes that
    // are still exactly the recovery fallback; its Desktop remains untouched.
    let routes = ScreenSaverRouteRecovery(storeURL: f.index, journalURL: f.journal)
    #expect(try routes.recoverIfNeeded())
    let resumed = try #require(try f.load()["Displays"] as? [String: [String: Any]])
    #expect((resumed["two"]?["Idle"] as? NSDictionary) == aura as NSDictionary)
    #expect((resumed["two"]?["Desktop"] as? NSDictionary) == dynamic as NSDictionary)
}

@Test func loginRecoveryWaitsForEnabledAutostartAndNeverReplacesLiveWallpaper() throws {
    let f = try SessionRecoveryFixture()
    var config = f.store.loadConfig(); config.autostart = true
    try f.store.saveConfig(config)
    f.onWait = { [weak f] in f?.live = true }
    #expect(try f.recovery().reconcile() == .runtimeActive)
    #expect(f.waits == 1)
    #expect(f.nativeCalls == 0)
    #expect(f.refreshes == 0)
}

@Test func loginRecoveryStartsWaitingAutostartBeforeFallingBackWithoutGUI() throws {
    let f = try SessionRecoveryFixture()
    var config = f.store.loadConfig(); config.autostart = true
    try f.store.saveConfig(config)
    f.onStart = { [weak f] in f?.live = true }
    #expect(try f.recovery().reconcile() == .runtimeActive)
    #expect(f.startRequests == 1)
    #expect(f.waits == 0)
    #expect(f.nativeCalls == 0)
    #expect(f.refreshes == 0)
}

@Test func enabledAutostartMayStartWhileLockedWithoutChangingSystemWallpaperRoutes() throws {
    let f = try SessionRecoveryFixture()
    var config = f.store.loadConfig(); config.autostart = true
    try f.store.saveConfig(config)
    f.locked = true
    f.onStart = { [weak f] in f?.live = true }
    #expect(try f.recovery().reconcile() == .runtimeActive)
    #expect(f.startRequests == 1)
    #expect(f.nativeCalls == 0)
    #expect(f.refreshes == 0)
}

@Test func failedAutostartRestoresUserWallpaperAfterBoundedGracePeriod() throws {
    let f = try SessionRecoveryFixture()
    var config = f.store.loadConfig(); config.autostart = true
    try f.store.saveConfig(config)
    let desktop = f.mode("user-provider")
    try f.save(["SystemDefault": ["Desktop": desktop, "Idle": try f.auraMode()]])
    #expect(try f.recovery().reconcile(autostartGracePeriod: 1) == .restored)
    #expect(f.waits == 2)
    #expect(f.refreshes == 1)
}

@Test func sessionRecoveryDoesNotRaceAUserInstallationBeforeItsHelperStarts() throws {
    let f = try SessionRecoveryFixture()
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.journal.path)
    #expect(try f.recovery().reconcile() == .deferred)
    #expect(f.nativeCalls == 0)
    #expect(f.refreshes == 0)
}

@Test(arguments: [true, nil] as [Bool?])
func sessionRecoveryDefersWhileLockedOrUnknown(locked: Bool?) throws {
    let f = try SessionRecoveryFixture(); f.locked = locked
    #expect(try f.recovery().reconcile() == .deferred)
    #expect(f.nativeCalls == 0)
    #expect(f.refreshes == 0)
}

@Test func suspendedSaverPreservesNewUserChoicesAndSurvivesProviderExitRewrite() throws {
    let f = try SessionRecoveryFixture()
    let desktop = f.mode("user-desktop"), aura = try f.auraMode()
    let route: [String: Any] = ["Desktop": desktop, "Idle": aura]
    try f.save(["Displays": ["one": route, "two": route]])
    let recovery = ScreenSaverRouteRecovery(storeURL: f.index, journalURL: f.journal)
    #expect(try recovery.suspendIfNeeded { true })
    var root = try f.load()
    var displays = try #require(root["Displays"] as? [String: [String: Any]])
    displays["one"]?["Idle"] = aura // Exiting WallpaperAgent flushes one stale route.
    root["Displays"] = displays; try f.save(root)
    #expect(try recovery.suspendIfNeeded { true })
    #expect(try recovery.recoverIfNeeded())
    let resumed = try #require(try f.load()["Displays"] as? [String: [String: Any]])
    #expect((resumed["one"]?["Idle"] as? NSDictionary) == aura as NSDictionary)
    #expect((resumed["two"]?["Idle"] as? NSDictionary) == aura as NSDictionary)
    #expect(try recovery.suspendIfNeeded { true })
    root = try f.load(); displays = try #require(root["Displays"] as? [String: [String: Any]])
    let userChoice = f.mode("new-user-idle")
    displays["two"]?["Idle"] = userChoice
    root["Displays"] = displays; try f.save(root)
    #expect(try recovery.recoverIfNeeded())
    let current = try #require(try f.load()["Displays"] as? [String: [String: Any]])
    #expect((current["two"]?["Idle"] as? NSDictionary) == userChoice as NSDictionary)
}

@Test func recoveryRegistrationIsIndependentOfPlaybackAutostartAndEscapesAccountPaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Recovery <Account> & Test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let plistURL = root.appendingPathComponent("agents/recovery.plist")
    let helper = root.appendingPathComponent("AuraWallpaperAgent")
    var calls: [[String]] = []
    try WallpaperSessionRecoveryRegistration.install(helperURL: helper, launchAgentURL: plistURL, launchctl: { arguments in
        calls.append(arguments)
        return LaunchctlResult(succeeded: arguments.first != "print", output: "", terminationStatus: 0)
    })
    let plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
    #expect(plist["ProgramArguments"] as? [String] == [helper.path, "--recover-wallpaper-session"])
    #expect(plist["RunAtLoad"] as? Bool == true)
    #expect(plist["StartInterval"] as? Int == 30)
    #expect(calls.last?.first == "bootstrap")
}

@Test(arguments: [false, true])
func recoveryKeepsALiveTerminalAfterItsExecutableWasReplaced(autostart: Bool) throws {
    let f = try SessionRecoveryFixture()
    let executable = f.root.appendingPathComponent("AuraTerminalWallpaperAgent")
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
    let process = Process()
    process.executableURL = executable
    process.arguments = ["60"]
    try process.run()
    defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
    let terminal = TerminalWallpaperRuntimeStore(appSupportURL: f.journal.deletingLastPathComponent(),
        launchAgentURL: f.root.appendingPathComponent("unused-terminal.plist"))
    try terminal.savePID(process.processIdentifier)
    try terminal.saveConfig(.init(command: .init(executable: "/bin/sleep", arguments: ["60"])))
    try terminal.saveHealth(.init(available: true, running: true,
        updatedAt: Date().timeIntervalSince1970 - 172_800, agentPID: Int(process.processIdentifier)))
    try terminal.saveLockScreenHeartbeat(.init(pid: Int(process.processIdentifier), updatedAt: Date().timeIntervalSince1970 - 172_800))
    try f.store.saveConfig(.init(video_path: "", playback_speed: 1, autostart: autostart,
        show_on_lock_screen: true, login_wallpaper_runtime: .terminal))
    let user = f.mode("com.apple.wallpaper.choice.sequoia")
    try f.save(["SystemDefault": ["Desktop": user, "Idle": try f.auraMode()]])
    let original = try Data(contentsOf: f.index)
    try #require(WallpaperLoginSelection.terminalRuntimeIsLive(in: f.store))
    let replacement = f.root.appendingPathComponent("replacement")
    try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: replacement.path)
    _ = try FileManager.default.replaceItemAt(executable, withItemAt: replacement)
    try #require(terminal.processIsAlive(pid: Int(process.processIdentifier)))
    try #require(WallpaperLoginSelection.terminalRuntimeIsLive(in: f.store),
        "An atomic app update must not make recovery classify its live Terminal owner as dead")
    var starts = 0, restores = 0, refreshes = 0
    let recovery = WallpaperSessionRecovery(store: f.store, wallpaperStoreURL: f.index,
        sessionIsLocked: { false }, wait: { _ in Issue.record("A live owner needs no startup grace") },
        requestAutostart: { starts += 1 }, suspendNative: { _ in restores += 1; return false },
        refresh: { commit in refreshes += 1; try commit() })
    for _ in 0..<120 {
        #expect(try recovery.reconcile(autostartGracePeriod: 0, installationGracePeriod: 0) == .runtimeActive)
    }
    #expect(starts == 0 && restores == 0 && refreshes == 0)
    #expect(try Data(contentsOf: f.index) == original)
    #expect(!FileManager.default.fileExists(atPath: f.journal.appendingPathExtension("suspended").path))
    // A persisted PID reused after shutdown must still be rejected, even if
    // the executable path of this running generation is no longer available.
    let identity = terminal.appSupportURL.appendingPathComponent("agent-identity.json")
    try JSONSerialization.data(withJSONObject: ["pid": Int(process.processIdentifier), "startTimeMicros": 1])
        .write(to: identity, options: .atomic)
    #expect(!WallpaperLoginSelection.terminalRuntimeIsLive(in: f.store))
    #expect(try recovery.reconcile(autostartGracePeriod: 0, installationGracePeriod: 0) == .restored)
    let routes = try #require(try f.load()["SystemDefault"] as? [String: Any])
    #expect(routes["Desktop"] as? NSDictionary == user as NSDictionary)
    #expect(routes["Idle"] as? NSDictionary == user as NSDictionary)
}
