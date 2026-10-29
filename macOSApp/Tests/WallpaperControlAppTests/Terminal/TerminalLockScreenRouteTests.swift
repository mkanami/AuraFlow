import AuraWallpaperCore
import Foundation
import Testing

private struct TerminalLockRouteFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraLockRoute-\(UUID())")
    var appSupport: URL { root.appendingPathComponent("AuraFlow") }
    var store: URL { root.appendingPathComponent("Index.plist") }
    var journal: URL { appSupport.appendingPathComponent("terminal-wallpaper/screen-saver-wallpaper-store-backup.json") }
    var lockJournal: URL { journal.appendingPathExtension("lock-session") }
    var saver: URL { root.appendingPathComponent("AuraFlowLockScreen.saver") }
    var recovery: ScreenSaverRouteRecovery { ScreenSaverRouteRecovery(storeURL: store, journalURL: journal, saverURL: saver) }

    init() throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"routes\":[]}".utf8).write(to: journal)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func mode(_ provider: String, configuration: [String: Any] = [:], options: [String: Any] = ["values": [:]]) throws -> [String: Any] {
        ["Content": ["Choices": [["Provider": provider, "Files": [],
            "Configuration": try PropertyListSerialization.data(fromPropertyList: configuration, format: .binary, options: 0)]],
            "EncodedOptionValues": try PropertyListSerialization.data(fromPropertyList: options, format: .binary, options: 0)]]
    }
    func user(_ provider: String = "com.apple.wallpaper.choice.sequoia") throws -> [String: Any] { try mode(provider) }
    func aura() throws -> [String: Any] {
        try mode(WallpaperPlatformConstants.screenSaverProviderID, configuration: ["module": ["relative": saver.absoluteString]])
    }
    func save(_ value: [String: Any]) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(to: store, options: .atomic)
    }
    func load() throws -> [String: Any] { try PropertyListSerialization.propertyList(from: Data(contentsOf: store), format: nil) as! [String: Any] }
}

@Suite(.serialized)
struct TerminalLockScreenRouteTests {
    @Test func confirmedLockSelectsTheLiveProviderForLoginwindowAndRestoresCompleteUserRoutes() throws {
        let f = try TerminalLockRouteFixture()
        defer { f.cleanup() }
        let first = try f.user(), second = try f.mode("com.apple.wallpaper.choice.monterey", options: ["values": ["appearance": "dark"], "opaque": "keep"])
        let aura = try f.aura()
        let original: [String: Any] = [
            "AllSpacesAndDisplays": ["Type": "individual", "Desktop": first, "Idle": aura],
            "SystemDefault": ["Type": "individual", "Desktop": first, "Idle": aura],
            "Displays": ["external": ["Desktop": second, "Idle": aura]],
            "Spaces": ["space": ["Default": ["Idle": aura], "Displays": ["external": ["Desktop": second, "Idle": aura]]]],
        ]
        try f.save(original)
        #expect(try f.recovery.activateDesktopForLockSession(shouldProceed: { true }))
        let active = try f.load()
        #expect(((active["SystemDefault"] as? [String: Any])?["Desktop"] as? NSDictionary)?.isEqual(aura) == true)
        let displays = active["Displays"] as! [String: [String: Any]]
        #expect((displays["external"]?["Desktop"] as? NSDictionary)?.isEqual(aura) == true)
        let snapshot = try Data(contentsOf: f.lockJournal)
        #expect(try !f.recovery.activateDesktopForLockSession(shouldProceed: { true }))
        #expect(try Data(contentsOf: f.lockJournal) == snapshot)
        #expect(try f.recovery.restoreDesktopAfterLockSession())
        #expect((try f.load() as NSDictionary).isEqual(original))
        #expect(!FileManager.default.fileExists(atPath: f.lockJournal.path))
    }

    @Test(arguments: [0, 1, 2])
    func aCancelledOrUnconfirmedLockCannotChangeTheUserDesktop(allowedChecks: Int) throws {
        let f = try TerminalLockRouteFixture()
        defer { f.cleanup() }
        try f.save(["SystemDefault": ["Desktop": try f.user(), "Idle": try f.aura()]])
        let original = try Data(contentsOf: f.store)
        var checks = 0
        #expect(try !f.recovery.activateDesktopForLockSession(shouldProceed: { checks += 1; return checks <= allowedChecks }))
        #expect(try Data(contentsOf: f.store) == original)
        _ = try f.recovery.restoreDesktopAfterLockSession()
        #expect(try Data(contentsOf: f.store) == original)
    }

    @Test func rebootWithoutAPlaybackHelperRestoresUserDesktopAndLockScreenFromTheInterruptedSession() throws {
        let f = try TerminalLockRouteFixture()
        defer { f.cleanup() }
        let user = try f.user("com.apple.wallpaper.choice.sonoma")
        try f.save(["SystemDefault": ["Desktop": user, "Idle": try f.aura()]])
        #expect(try f.recovery.activateDesktopForLockSession(shouldProceed: { true }))
        let app = WallpaperRuntimeStore(appSupportURL: f.appSupport, launchAgentURL: f.root.appendingPathComponent("unused.plist"))
        try app.saveConfig(.init(video_path: "", playback_speed: 1, autostart: false))
        let recovery = WallpaperSessionRecovery(store: app, wallpaperStoreURL: f.store, runtimeIsLive: { false },
            sessionIsLocked: { false }, suspendNative: { _ in false }, refresh: { try $0() }, screenSaverURL: f.saver)
        #expect(try recovery.reconcile(autostartGracePeriod: 0, installationGracePeriod: 0) == .restored)
        let route = try f.load()["SystemDefault"] as! [String: Any]
        #expect((route["Desktop"] as? NSDictionary)?.isEqual(user) == true)
        #expect((route["Idle"] as? NSDictionary)?.isEqual(user) == true)
    }

    @Test func userChangesMadeDuringTheLockArePreservedOnUnlock() throws {
        let f = try TerminalLockRouteFixture()
        defer { f.cleanup() }
        try f.save(["SystemDefault": ["Desktop": try f.user(), "Idle": try f.aura()]])
        _ = try f.recovery.activateDesktopForLockSession(shouldProceed: { true })
        let updated = try f.mode("com.apple.wallpaper.choice.monterey", options: ["values": ["appearance": "automatic"]])
        try f.save(["SystemDefault": ["Desktop": updated, "Idle": try f.aura()]])
        let selected = try Data(contentsOf: f.store)
        #expect(try !f.recovery.restoreDesktopAfterLockSession())
        #expect(try Data(contentsOf: f.store) == selected)
    }

    @Test func aCorruptSessionSnapshotNeverClearsTheDesktopToASystemDefault() throws {
        let f = try TerminalLockRouteFixture()
        defer { f.cleanup() }
        try f.save(["SystemDefault": ["Desktop": try f.user(), "Idle": try f.aura()]])
        _ = try f.recovery.activateDesktopForLockSession(shouldProceed: { true })
        let active = try Data(contentsOf: f.store)
        try JSONSerialization.data(withJSONObject: [["path": "SystemDefault", "desktop": Data("invalid plist".utf8).base64EncodedString()]])
            .write(to: f.lockJournal)
        #expect(throws: (any Error).self) { try f.recovery.restoreDesktopAfterLockSession() }
        #expect(try Data(contentsOf: f.store) == active)
    }
}
