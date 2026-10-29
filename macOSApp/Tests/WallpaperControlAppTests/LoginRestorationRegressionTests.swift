import Foundation
import AppKit
import AuraTerminalWallpaperCore
import Testing
@testable import AuraWallpaperCore

private final class LoginRestorationFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraLogin-\(UUID())")
    var calls: [[String]] = []
    lazy var store = WallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("support"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/com.andrijvergeles.auraflow.plist"),
        launchctlRunner: { [unowned self] args in
            calls.append(args)
            return .init(succeeded: args.first != "print", output: "not loaded")
        })
    func terminal(enabled: Bool = false) throws {
        let url = store.appSupportURL.appendingPathComponent("terminal-wallpaper/config.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["command": ["executable": "/bin/echo", "arguments": ["saved wallpaper"]],
            "behavior": ["launchAtLogin": enabled], "render": ["fontSize": 23]]).write(to: url)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@Test(arguments: [false, true])
func nextLoginRestoresSavedTerminalWhenTheApplicationPreferenceIsEnabled(explicitMode: Bool) throws {
    let f = LoginRestorationFixture()
    try f.terminal()
    try f.store.saveConfig(.init(video_path: "", playback_speed: 1, autostart: true,
        autostart_deferred_session_id: "previous-boot", login_wallpaper_runtime: explicitMode ? .terminal : nil))
    try AutostartManager(store: f.store, helperURL: f.root.appendingPathComponent("Runtime/AuraWallpaperAgent"),
        sessionIdentifier: { "new-boot" }).migrateExistingLaunchAgentIfNeeded()
    let terminalPlist = WallpaperLoginSelection.terminalLaunchAgentURL(in: f.store)
    #expect(FileManager.default.fileExists(atPath: terminalPlist.path))
    #expect(!f.store.launchAgentPlistExists())
    #expect(f.calls.contains { $0.first == "bootstrap" && $0.last == terminalPlist.path })
    #expect(f.store.loadConfig().login_wallpaper_runtime == .terminal)
    #expect(WallpaperLoginSelection.terminalConfiguration(in: f.store)?["render"] as? [String: Int] == ["fontSize": 23])
}

@Test(arguments: [false, true])
func terminalLoginPreferenceNeverStartsPlaybackInTheEditedSession(enabled: Bool) throws {
    let f = LoginRestorationFixture()
    try f.terminal(enabled: true)
    try f.store.saveConfig(.init(video_path: "", playback_speed: 1, autostart: enabled,
        autostart_deferred_session_id: "this-session", login_wallpaper_runtime: .terminal))
    try AutostartManager(store: f.store, helperURL: f.root.appendingPathComponent("helper"),
        sessionIdentifier: { "this-session" }).migrateExistingLaunchAgentIfNeeded()
    #expect(f.calls.isEmpty)
}

@Test func terminalLoginRecoveryDoesNotRequireAnOldLockScreenInstallation() throws {
    let f = LoginRestorationFixture()
    try f.terminal()
    try f.store.saveConfig(.init(video_path: "", playback_speed: 1, autostart: true,
        login_wallpaper_runtime: .terminal))
    var live = false
    var starts = 0
    let recovery = WallpaperSessionRecovery(store: f.store, wallpaperStoreURL: f.root.appendingPathComponent("unused.plist"),
        runtimeIsLive: { live }, sessionIsLocked: { false }, wait: { _ in },
        requestAutostart: { starts += 1; live = true }, suspendNative: { _ in
            Issue.record("A selected wallpaper must be started before fallback"); return false
        }, refresh: { _ in Issue.record("No system process should be restarted") }, sessionIdentifier: { "new-boot" })
    #expect(try recovery.reconcile() == .runtimeActive)
    #expect(starts == 1)
}

@Test func cachedFrameMustNeverBeInstalledAsTheUsersSystemWallpaper() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraNoStill-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let png = root.appendingPathComponent("source.png")
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
    memset(try #require(bitmap.bitmapData), 255, 16)
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: png)
    var applications = 0
    let recovery = DesktopWallpaperRecovery(appSupportURL: WallpaperRuntimeStore.defaultAppSupportURL(),
        stillFrameService: StillFrameService(appSupportURL: root), applyDesktop: { _ in applications += 1; return true })
    #expect(recovery.applyStillWallpaper(from: png.path) == nil)
    #expect(applications == 0)
}

@Test func appliedRuntimeSwitchKeepsOneLoginJobAndNeverTouchesCurrentPlayback() throws {
    let f = LoginRestorationFixture()
    try f.terminal(enabled: true)
    let movie = f.root.appendingPathComponent("source.mp4")
    try Data("source".utf8).write(to: movie)
    try f.store.saveConfig(.init(video_path: movie.path, playback_speed: 0.75, autostart: true,
        scale_mode: "fit", login_wallpaper_runtime: .video))
    try f.store.saveCommand(.init(action: .reload, config: f.store.loadConfig()))
    let command = f.store.loadCommand()
    let manager = AutostartManager(store: f.store, helperURL: f.root.appendingPathComponent("Runtime/AuraWallpaperAgent"),
        sessionIdentifier: { "same-login" })
    for mode in [WallpaperLoginRuntime.terminal, .video, .terminal] {
        try manager.selectRuntime(mode)
        #expect(f.store.launchAgentPlistExists() == (mode == .video))
        #expect(FileManager.default.fileExists(atPath: WallpaperLoginSelection.terminalLaunchAgentURL(in: f.store).path) == (mode == .terminal))
        #expect(f.store.loadCommand() == command)
        #expect(f.store.loadConfig().playback_speed == 0.75)
        #expect(f.store.loadConfig().scale_mode == "fit")
        #expect(f.calls.isEmpty)
    }
    _ = try manager.setEnabled(false, runtime: .terminal)
    f.calls.removeAll()
    try manager.migrateExistingLaunchAgentIfNeeded()
    #expect(f.calls.isEmpty)
    #expect(!WallpaperLoginSelection.enabled(in: f.store))
    #expect(!FileManager.default.fileExists(atPath: WallpaperLoginSelection.terminalLaunchAgentURL(in: f.store).path))
}

@Test func nextLoginRestoresVideoSourceAndSettingsAndDoesNotLaunchTerminal() throws {
    let f = LoginRestorationFixture()
    try f.terminal(enabled: true)
    let movie = f.root.appendingPathComponent("source.mp4")
    try Data("source".utf8).write(to: movie)
    try f.store.saveConfig(.init(video_path: movie.path, playback_speed: 0.75, autostart: true,
        scale_mode: "fit", autostart_deferred_session_id: "old-login", login_wallpaper_runtime: .video))
    let config = f.store.loadConfig()
    try AutostartManager(store: f.store, helperURL: f.root.appendingPathComponent("Runtime/AuraWallpaperAgent"),
        sessionIdentifier: { "new-login" }).migrateExistingLaunchAgentIfNeeded()
    #expect(f.store.loadConfig() == config)
    #expect(f.calls.contains { $0.first == "bootstrap" && $0.last == f.store.launchAgentURL.path })
    #expect(!FileManager.default.fileExists(atPath: WallpaperLoginSelection.terminalLaunchAgentURL(in: f.store).path))
}

@Test func failedLoginFallsBackToUserWallpaperWithoutDisablingFutureAutostart() throws {
    let f = LoginRestorationFixture()
    try f.terminal()
    try f.store.saveConfig(.init(video_path: "", playback_speed: 1, autostart: true, login_wallpaper_runtime: .terminal))
    var starts = 0, suspensions = 0
    let recovery = WallpaperSessionRecovery(store: f.store, wallpaperStoreURL: f.root.appendingPathComponent("unused.plist"),
        runtimeIsLive: { false }, sessionIsLocked: { false }, wait: { _ in }, requestAutostart: { starts += 1 },
        suspendNative: { proceed in #expect(proceed()); suspensions += 1; return true },
        refresh: { commit in try commit() }, sessionIdentifier: { "new-login" })
    #expect(try recovery.reconcile(autostartGracePeriod: 0) == .restored)
    #expect(starts == 1 && suspensions >= 1)
    #expect(f.store.loadConfig().autostart == true)
}

@Test func terminalLoginStatusReportsTheSelectedServiceInsteadOfAMissingVideoJob() throws {
    let f = LoginRestorationFixture()
    try f.terminal()
    let store = WallpaperRuntimeStore(appSupportURL: f.store.appSupportURL, launchAgentURL: f.store.launchAgentURL,
        launchctlRunner: { args in
            .init(succeeded: args.last?.hasSuffix(WallpaperLoginSelection.terminalLabel) == true,
                  output: "state = running\npid = 123")
        })
    try store.saveConfig(.init(video_path: "", playback_speed: 1, autostart: true, login_wallpaper_runtime: .terminal))
    try WallpaperLoginSelection.registerTerminal(in: store, helperURL: f.root.appendingPathComponent("Runtime/helper"))
    let status = store.status()
    #expect(status.autostart == true)
    #expect(status.autostart_plist_exists == true && status.autostart_service_running == true)
    #expect(!store.launchAgentPlistExists())
}

@Test func legacyInactiveTerminalLoginFlagDoesNotEnableAVideoTheUserDisabled() throws {
    let f = LoginRestorationFixture()
    try f.terminal(enabled: true)
    let movie = f.root.appendingPathComponent("source.mp4")
    try Data("source".utf8).write(to: movie)
    try f.store.saveConfig(.init(video_path: movie.path, playback_speed: 1, autostart: false))
    try AutostartManager(store: f.store, helperURL: f.root.appendingPathComponent("helper"),
        sessionIdentifier: { "new-login" }).migrateExistingLaunchAgentIfNeeded()
    #expect(!WallpaperLoginSelection.enabled(in: f.store))
    #expect(f.calls.isEmpty)
}

@Test(arguments: [false, true])
func reopeningAppDoesNotDuplicateAnOwnedTerminalButAReusedPIDCannotBlockLogin(staleIdentity: Bool) throws {
    let f = LoginRestorationFixture()
    try f.terminal()
    try f.store.saveConfig(.init(video_path: "", playback_speed: 1, autostart: true, login_wallpaper_runtime: .terminal))
    let helper = f.root.appendingPathComponent("AuraTerminalWallpaperAgent")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: helper)
    let process = Process(); process.executableURL = helper; process.arguments = ["30"]
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    let terminal = TerminalWallpaperRuntimeStore(appSupportURL: f.store.appSupportURL.appendingPathComponent("terminal-wallpaper"),
        launchAgentURL: WallpaperLoginSelection.terminalLaunchAgentURL(in: f.store))
    try terminal.savePID(process.processIdentifier)
    if staleIdentity {
        let identityURL = terminal.appSupportURL.appendingPathComponent("agent-identity.json")
        try JSONSerialization.data(withJSONObject: ["pid": Int(process.processIdentifier), "startTimeMicros": 0])
            .write(to: identityURL, options: .atomic)
    }
    try AutostartManager(store: f.store, helperURL: f.root.appendingPathComponent("Runtime/AuraWallpaperAgent"),
        sessionIdentifier: { "new-login" }).migrateExistingLaunchAgentIfNeeded()
    #expect(f.calls.contains { $0.first == "bootstrap" } == staleIdentity)
    #expect(process.isRunning)
}
