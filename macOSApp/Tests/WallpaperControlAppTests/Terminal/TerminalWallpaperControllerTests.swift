import AuraTerminalWallpaperCore
import AuraWallpaperCore
import Foundation
import Testing
@testable import WallpaperControlApp

private final class MockTerminalLockScreenCoordinator: TerminalLockScreenCoordinating, @unchecked Sendable {
    private(set) var activations = 0
    private(set) var restorations = 0
    var onActivate: (() throws -> Void)?
    var onRestore: (() throws -> Void)?
    func activate() throws { activations += 1; try onActivate?() }
    func restore() throws { restorations += 1; try onRestore?() }
}

private struct TerminalControllerFixture {
    let root: URL
    let store: TerminalWallpaperRuntimeStore
    let helperURL: URL

    init(_ name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraFlowTerminalTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = TerminalWallpaperRuntimeStore(
            appSupportURL: root.appendingPathComponent("terminal-wallpaper", isDirectory: true),
            launchAgentURL: root.appendingPathComponent("LaunchAgents/terminal.plist")
        )
        helperURL = root.appendingPathComponent("mock-terminal-agent.sh")
        try "#!/bin/sh\nexec sleep 60\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
    }

    func cleanup() {
        store.disableLaunchAgent()
        _ = store.terminateAgent(timeout: 0.2)
        try? FileManager.default.removeItem(at: root)
    }
}

@Test func terminalHelperUsesItsOwnNestedAppBundle() {
    let appURL = URL(fileURLWithPath: "/tmp/AuraFlow.app")
    #expect(
        NativeTerminalWallpaperController.bundledHelperURL(in: appURL).path ==
        "/tmp/AuraFlow.app/Contents/Helpers/AuraTerminalWallpaperAgent.app/Contents/MacOS/AuraTerminalWallpaperAgent"
    )
}

@Test(arguments: [false, true])
func terminalControllerKeepsRuntimeConfigSeparateFromSharedLoginSelection(existingVideoConfig: Bool) throws {
    let fixture = try TerminalControllerFixture("isolated-store")
    defer { fixture.cleanup() }
    let applicationStore = WallpaperRuntimeStore(appSupportURL: fixture.root,
        launchAgentURL: fixture.root.appendingPathComponent("LaunchAgents/video.plist"))
    var expectedSharedConfig = applicationStore.loadConfig()
    if existingVideoConfig {
        expectedSharedConfig = .init(video_path: "/fixtures/previous-video.mp4", playback_speed: 1.25,
            volume: 0.4, autostart: false, blend_interpolation: true, pause_on_fullscreen: false,
            show_on_lock_screen: true, scale_mode: "fit", login_wallpaper_runtime: .video)
        try applicationStore.saveConfig(expectedSharedConfig)
    }
    let controller = try NativeTerminalWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false },
        lockScreenVideoIsActive: { false },
        lockScreenCoordinator: MockTerminalLockScreenCoordinator(),
        lockScreenFrameReadinessWaiter: { _, _ in true }
    )
    let config = TerminalWallpaperConfig(
        command: TerminalCommandConfiguration(executable: "/bin/echo", arguments: ["hello"])
    )

    _ = try controller.start(config: config)
    #expect(fixture.store.loadConfig().command.executable == "/bin/echo")
    #expect(fixture.store.loadCommand()?.action == .start)
    #expect(FileManager.default.fileExists(atPath: fixture.store.configURL.path))
    expectedSharedConfig.login_wallpaper_runtime = .terminal
    #expect(applicationStore.loadConfig() == expectedSharedConfig,
        "Only the applied login engine may change in the shared configuration; preserve all video preferences")
    #expect(!FileManager.default.fileExists(atPath: applicationStore.commandURL.path),
        "Terminal commands must stay in the Terminal runtime namespace")

    _ = try controller.stop()
    #expect(fixture.store.processIsAlive(pid: fixture.store.loadPID()) == false)
}

@Test func terminalControllerUpdatesWithoutTouchingVideoRuntime() throws {
    let fixture = try TerminalControllerFixture("update-terminate")
    defer { fixture.cleanup() }
    let controller = try NativeTerminalWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false },
        lockScreenVideoIsActive: { false },
        lockScreenCoordinator: MockTerminalLockScreenCoordinator(),
        lockScreenFrameReadinessWaiter: { _, _ in true }
    )
    let config = TerminalWallpaperConfig(
        command: TerminalCommandConfiguration(executable: "/bin/echo", arguments: ["hello"])
    )

    _ = try controller.start(config: config)

    var renderOnlyUpdate = config
    renderOnlyUpdate.render.maxFPS = 60
    _ = try controller.update(config: renderOnlyUpdate)
    #expect(fixture.store.loadCommand()?.action == .update)

    var commandUpdate = renderOnlyUpdate
    commandUpdate.command.arguments = ["changed"]
    _ = try controller.update(config: commandUpdate)
    #expect(fixture.store.loadCommand()?.action == .restart)

    _ = try controller.terminate()
    #expect(fixture.store.processIsAlive(pid: fixture.store.loadPID()) == false)
    #expect(fixture.store.loadCommand() == nil)
}

@Test(arguments: [false, true])
func terminalRemovalKeepsRendererUntilSystemWallpaperIsRestored(terminate: Bool) throws {
    let fixture = try TerminalControllerFixture("covered-removal")
    defer { fixture.cleanup() }
    let lockScreen = MockTerminalLockScreenCoordinator()
    let controller = try NativeTerminalWallpaperController(
        store: fixture.store, helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false }, lockScreenVideoIsActive: { false },
        lockScreenCoordinator: lockScreen, lockScreenFrameReadinessWaiter: { _, _ in true }
    )
    _ = try controller.start(config: .init(command: .init(executable: "/bin/echo")))
    let pid = try #require(fixture.store.loadPID())
    try fixture.store.saveLockScreenHeartbeat(.init(pid: Int(getpid())))
    lockScreen.onRestore = {
        #expect(fixture.store.processIsAlive(pid: pid))
        #expect(fixture.store.loadCommand()?.action == .start)
        #expect(fixture.store.loadLockScreenHeartbeat() != nil)
    }
    _ = try terminate ? controller.terminate() : controller.stop()
    #expect(lockScreen.restorations == 1)
    #expect(!fixture.store.processIsAlive(pid: pid))
    #expect(fixture.store.loadLockScreenHeartbeat() == nil)
    #expect(fixture.store.loadCommand() == nil)
}

@Test(arguments: [false, true])
func terminalRemovalFailureKeepsExistingRendererAndFrame(terminate: Bool) throws {
    let fixture = try TerminalControllerFixture("removal-restore-failure")
    defer { fixture.cleanup() }
    let lockScreen = MockTerminalLockScreenCoordinator()
    let controller = try NativeTerminalWallpaperController(
        store: fixture.store, helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false }, lockScreenVideoIsActive: { false },
        lockScreenCoordinator: lockScreen, lockScreenFrameReadinessWaiter: { _, _ in true }
    )
    _ = try controller.start(config: .init(command: .init(executable: "/bin/echo")))
    let pid = try #require(fixture.store.loadPID())
    try fixture.store.saveLockScreenHeartbeat(.init(pid: Int(getpid())))
    lockScreen.onRestore = { throw TerminalScreenSaverStoreCoordinator.StoreError.wallpaperAgentUnavailable }
    #expect(throws: TerminalScreenSaverStoreCoordinator.StoreError.self) {
        _ = try terminate ? controller.terminate() : controller.stop()
    }
    #expect(fixture.store.processIsAlive(pid: pid))
    #expect(fixture.store.loadLockScreenHeartbeat() != nil)
    #expect(fixture.store.loadCommand()?.action == .start)
}

@Test func terminalControllerAppliesLaunchAtLoginFromStartConfig() throws {
    let fixture = try TerminalControllerFixture("launch-at-login")
    defer { fixture.cleanup() }
    let controller = try NativeTerminalWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false },
        lockScreenVideoIsActive: { false },
        lockScreenCoordinator: MockTerminalLockScreenCoordinator(),
        lockScreenFrameReadinessWaiter: { _, _ in true }
    )
    var config = TerminalWallpaperConfig(
        command: TerminalCommandConfiguration(executable: "/bin/echo")
    )
    config.behavior.launchAtLogin = true

    _ = try controller.start(config: config)
    #expect(fixture.store.launchAgentEnabled())
    #expect(fixture.store.loadConfig().behavior.launchAtLogin)
    _ = try controller.stop()
}

@Test func terminalControllerRefusesToStartAlongsideVideoWallpaper() throws {
    let fixture = try TerminalControllerFixture("video-conflict")
    defer { fixture.cleanup() }
    let controller = try NativeTerminalWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { true },
        lockScreenVideoIsActive: { false },
        lockScreenCoordinator: MockTerminalLockScreenCoordinator()
    )

    #expect(throws: TerminalWallpaperControllerError.videoWallpaperAlreadyRunning) {
        _ = try controller.start(
            config: TerminalWallpaperConfig(
                command: TerminalCommandConfiguration(executable: "/bin/echo")
            )
        )
    }
    #expect(fixture.store.loadCommand() == nil)
}

@Test func terminalControllerRejectsGuiApplicationBundles() throws {
    let fixture = try TerminalControllerFixture("gui-app")
    defer { fixture.cleanup() }
    let controller = try NativeTerminalWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false },
        lockScreenVideoIsActive: { false },
        lockScreenCoordinator: MockTerminalLockScreenCoordinator()
    )

    #expect(throws: TerminalWallpaperControllerError.guiApplicationNotSupported) {
        _ = try controller.start(
            config: TerminalWallpaperConfig(
                command: TerminalCommandConfiguration(executable: "/Applications/Docker.app")
            )
        )
    }
}

@Test func terminalControllerActivatesAndRestoresLockScreenSaver() throws {
    let fixture = try TerminalControllerFixture("lock-saver-lifecycle")
    defer { fixture.cleanup() }
    let lockScreen = MockTerminalLockScreenCoordinator()
    let controller = try NativeTerminalWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false },
        lockScreenVideoIsActive: { false },
        lockScreenCoordinator: lockScreen,
        lockScreenFrameReadinessWaiter: { _, _ in true }
    )
    let config = TerminalWallpaperConfig(command: .init(executable: "/bin/echo"))

    try controller.reconcileLockScreenIfRunning()
    #expect(lockScreen.activations == 0)
    _ = try controller.start(config: config)
    #expect(lockScreen.activations == 1)
    try controller.reconcileLockScreenIfRunning()
    #expect(lockScreen.activations == 2)
    try fixture.store.saveLockScreenHeartbeat(.init(pid: Int(getpid())))
    _ = try controller.restart(config: config)
    #expect(lockScreen.activations == 3)
    _ = try controller.stop()
    #expect(lockScreen.restorations == 1)
    #expect(fixture.store.loadLockScreenHeartbeat() == nil)
}

@Test func terminalControllerDoesNotSelectLockScreenBeforeFreshFrameIsAvailable() throws {
    let fixture = try TerminalControllerFixture("lock-frame-not-ready")
    defer { fixture.cleanup() }
    let lockScreen = MockTerminalLockScreenCoordinator()
    let controller = try NativeTerminalWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false },
        lockScreenVideoIsActive: { false },
        lockScreenCoordinator: lockScreen,
        lockScreenFrameReadinessWaiter: { _, _ in false }
    )

    #expect(throws: TerminalWallpaperControllerError.lockScreenFrameNotReady) {
        _ = try controller.start(config: .init(command: .init(executable: "/bin/echo")))
    }
    #expect(lockScreen.activations == 0)
    #expect(fixture.store.loadCommand()?.action == .start)
    #expect(fixture.store.processIsAlive(pid: fixture.store.loadPID()))
}

@Test func terminalControllerRefusesActiveLockScreenOnlyVideoBeforeSelectingSaver() throws {
    let fixture = try TerminalControllerFixture("lock-video-conflict")
    defer { fixture.cleanup() }
    let lockScreen = MockTerminalLockScreenCoordinator()
    let controller = try NativeTerminalWallpaperController(
        store: fixture.store,
        helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false },
        lockScreenVideoIsActive: { true },
        lockScreenCoordinator: lockScreen
    )

    #expect(throws: TerminalWallpaperControllerError.lockScreenVideoAlreadyRunning) {
        _ = try controller.start(config: .init(command: .init(executable: "/bin/echo")))
    }
    #expect(lockScreen.activations == 0)
    #expect(fixture.store.loadCommand() == nil)
}

@Test func terminalLockScreenOffOnPreservesDesktopProcessAndRefreshesFrame() throws {
    let fixture = try TerminalControllerFixture("lock-checkbox-cycle")
    defer { fixture.cleanup() }
    let coordinator = MockTerminalLockScreenCoordinator()
    let sharedConfig = fixture.root.appendingPathComponent("config.json")
    func setEnabled(_ enabled: Bool) throws {
        try JSONSerialization.data(withJSONObject: ["video_path": "", "playback_speed": 1,
            "show_on_lock_screen": enabled]).write(to: sharedConfig, options: .atomic)
    }
    try setEnabled(false)
    var readinessChecks = 0
    let controller = try NativeTerminalWallpaperController(store: fixture.store, helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false }, lockScreenVideoIsActive: { false }, lockScreenCoordinator: coordinator,
        lockScreenFrameReadinessWaiter: { _, _ in readinessChecks += 1; return true })
    _ = try controller.start(config: TerminalWallpaperConfig(command: TerminalCommandConfiguration(executable: "/bin/echo", arguments: ["static wallpaper"])))
    let pid = try #require(fixture.store.loadPID())
    #expect(readinessChecks == 0)
    #expect(coordinator.activations == 0)
    try controller.reconcileLockScreenIfRunning()
    #expect(coordinator.activations == 0)
    try setEnabled(true)
    try controller.setShowOnLockScreen(true)
    #expect(readinessChecks == 1)
    #expect(coordinator.activations == 1)
    try setEnabled(false)
    try controller.setShowOnLockScreen(false)
    #expect(coordinator.restorations == 1)
    #expect(fixture.store.processIsAlive(pid: pid))
    #expect(fixture.store.loadPID() == pid)
    #expect(fixture.store.loadCommand()?.action == .update)
    #expect(fixture.store.loadCommand()?.config == nil)
    try controller.reconcileLockScreenIfRunning()
    #expect(coordinator.activations == 1)
    try setEnabled(true)
    try controller.setShowOnLockScreen(true)
    #expect(readinessChecks == 2)
    #expect(coordinator.activations == 2)
    #expect(fixture.store.loadPID() == pid)
}

@Test func terminalLockScreenDoesNotActivateWithoutFreshFrame() throws {
    let fixture = try TerminalControllerFixture("lock-checkbox-unready")
    defer { fixture.cleanup() }
    let coordinator = MockTerminalLockScreenCoordinator()
    let task = Process()
    task.executableURL = fixture.helperURL
    try task.run()
    try fixture.store.savePID(task.processIdentifier)
    let controller = try NativeTerminalWallpaperController(store: fixture.store, helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false }, lockScreenVideoIsActive: { false }, lockScreenCoordinator: coordinator,
        lockScreenFrameReadinessWaiter: { _, _ in false })
    #expect(throws: TerminalWallpaperControllerError.lockScreenFrameNotReady) {
        try controller.setShowOnLockScreen(true)
    }
    #expect(coordinator.activations == 0)
    #expect(task.isRunning)
}

@Test func terminalNewAppReplacesAnOldHelperInsteadOfSendingItAnotherRestartCommand() throws {
    let fixture = try TerminalControllerFixture("helper-upgrade")
    defer { fixture.cleanup() }
    let coordinator = MockTerminalLockScreenCoordinator()
    var needsReplacement = false
    let controller = try NativeTerminalWallpaperController(store: fixture.store, helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false }, lockScreenVideoIsActive: { false }, lockScreenCoordinator: coordinator,
        lockScreenFrameReadinessWaiter: { _, _ in true }, runningAgentNeedsReplacement: { needsReplacement },
        sessionIsLocked: { false })
    let config = TerminalWallpaperConfig(command: .init(executable: "/bin/echo", arguments: ["same configuration"]))
    _ = try controller.start(config: config)
    let original = try #require(fixture.store.loadPID())
    needsReplacement = true
    try controller.reconcileLockScreenIfRunning()
    let replacement = try #require(fixture.store.loadPID())
    #expect(replacement != original)
    #expect(!fixture.store.processIsAlive(pid: original))
    #expect(fixture.store.processIsAlive(pid: replacement))
    #expect(fixture.store.loadConfig() == config.normalized())
    #expect(fixture.store.loadCommand()?.action == .start)
    needsReplacement = false
    try controller.reconcileLockScreenIfRunning()
    #expect(fixture.store.loadPID() == replacement)
}

@Test(arguments: [false, true])
func terminalHelperUpgradeDoesNotDropTheSurfaceOfALockedOrPausedSession(paused: Bool) throws {
    let fixture = try TerminalControllerFixture("covered-upgrade")
    defer { fixture.cleanup() }
    var needsReplacement = false
    let controller = try NativeTerminalWallpaperController(store: fixture.store, helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false }, lockScreenVideoIsActive: { false },
        lockScreenCoordinator: MockTerminalLockScreenCoordinator(), lockScreenFrameReadinessWaiter: { _, _ in true },
        runningAgentNeedsReplacement: { needsReplacement }, sessionIsLocked: { !paused })
    _ = try controller.start(config: .init(command: .init(executable: "/bin/echo")))
    let original = try #require(fixture.store.loadPID())
    try fixture.store.setPlaybackPaused(paused)
    needsReplacement = true
    try controller.reconcileLockScreenIfRunning()
    #expect(fixture.store.loadPID() == original)
    #expect(fixture.store.processIsAlive(pid: original))
    #expect(fixture.store.isPlaybackPaused == paused)
}

@Test(arguments: [false, true], [false, true])
func terminalDeferredHelperUpgradeRetriesAfterUnlockOrResumeOnlyOnce(lockScreenEnabled: Bool, paused: Bool) throws {
    let fixture = try TerminalControllerFixture("deferred-helper-upgrade")
    defer { fixture.cleanup() }
    try fixture.store.ensureDirectories()
    try JSONSerialization.data(withJSONObject: ["video_path": "", "playback_speed": 1,
        "show_on_lock_screen": lockScreenEnabled, "autostart": false])
        .write(to: fixture.root.appendingPathComponent("config.json"))
    let coordinator = MockTerminalLockScreenCoordinator()
    var needsReplacement = false
    var locked: Bool? = false
    let controller = try NativeTerminalWallpaperController(store: fixture.store, helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false }, lockScreenVideoIsActive: { false }, lockScreenCoordinator: coordinator,
        lockScreenFrameReadinessWaiter: { _, _ in needsReplacement = false; return true },
        runningAgentNeedsReplacement: { needsReplacement }, sessionIsLocked: { locked })
    let config = TerminalWallpaperConfig(command: .init(executable: "/bin/echo", arguments: ["retained source"]),
        render: .init(columns: 80, rows: 24, fontSize: 14))
    _ = try controller.start(config: config)
    let original = try #require(fixture.store.loadPID())
    let originalConfig = fixture.store.loadConfig()
    let initialActivations = coordinator.activations
    try fixture.store.saveHealth(.init(agentPID: original, executableFingerprint: "old-helper"))
    needsReplacement = true
    locked = paused ? false : true
    try fixture.store.setPlaybackPaused(paused)
    #expect(try !controller.reconcileDeferredRuntimeUpdateIfRunning())
    #expect(fixture.store.loadPID() == original && coordinator.activations == initialActivations)
    locked = nil
    #expect(try !controller.reconcileDeferredRuntimeUpdateIfRunning())
    #expect(fixture.store.loadPID() == original)
    locked = false
    try fixture.store.setPlaybackPaused(false)
    #expect(try controller.reconcileDeferredRuntimeUpdateIfRunning())
    let replacement = try #require(fixture.store.loadPID())
    #expect(replacement != original && fixture.store.processIsAlive(pid: replacement))
    #expect(fixture.store.loadConfig() == originalConfig)
    #expect(!fixture.store.launchAgentEnabled())
    // The disabled route has no frame waiter; emulate its new helper health.
    needsReplacement = false
    let afterUpgrade = coordinator.activations
    for _ in 0..<5 { #expect(try !controller.reconcileDeferredRuntimeUpdateIfRunning()) }
    #expect(fixture.store.loadPID() == replacement && coordinator.activations == afterUpgrade)
    #expect(afterUpgrade == initialActivations + (lockScreenEnabled ? 1 : 0))
}

@Test(arguments: ["missing", "wrong-owner", "missing-fingerprint"])
func terminalDeferredUpgradeWaitsForOwnedStartupHealth(invalid: String) throws {
    let fixture = try TerminalControllerFixture("unknown-upgrade-health")
    defer { fixture.cleanup() }
    try fixture.store.ensureDirectories()
    try JSONSerialization.data(withJSONObject: ["video_path": "", "playback_speed": 1, "show_on_lock_screen": false])
        .write(to: fixture.root.appendingPathComponent("config.json"))
    var needsReplacement = false
    var checks = 0
    let coordinator = MockTerminalLockScreenCoordinator()
    let controller = try NativeTerminalWallpaperController(store: fixture.store, helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false }, lockScreenVideoIsActive: { false }, lockScreenCoordinator: coordinator,
        runningAgentNeedsReplacement: { checks += 1; return needsReplacement }, sessionIsLocked: { false })
    _ = try controller.start(config: .init(command: .init(executable: "/bin/echo")))
    let original = try #require(fixture.store.loadPID())
    needsReplacement = true
    if invalid != "missing" {
        try fixture.store.saveHealth(.init(agentPID: invalid == "wrong-owner" ? original + 1 : original,
            executableFingerprint: invalid == "missing-fingerprint" ? nil : "old-helper"))
    }
    for _ in 0..<3 { #expect(try !controller.reconcileDeferredRuntimeUpdateIfRunning()) }
    #expect(checks == 0 && fixture.store.loadPID() == original)
    try fixture.store.saveHealth(.init(agentPID: original, executableFingerprint: "old-helper"))
    #expect(try controller.reconcileDeferredRuntimeUpdateIfRunning())
    let replacement = try #require(fixture.store.loadPID())
    #expect(replacement != original && checks == 1)
    needsReplacement = false
    for _ in 0..<3 { #expect(try !controller.reconcileDeferredRuntimeUpdateIfRunning()) }
    #expect(fixture.store.loadPID() == replacement && coordinator.activations == 0)
}

@Test func terminalDeferredUpgradeRetainsRearmUntilItsLateFrameAndProviderAreReady() throws {
    let fixture = try TerminalControllerFixture("late-upgrade-rearm")
    defer { fixture.cleanup() }
    var needsReplacement = false
    var frameReady = true
    var locked = false
    let coordinator = MockTerminalLockScreenCoordinator()
    let controller = try NativeTerminalWallpaperController(store: fixture.store, helperURL: fixture.helperURL,
        videoRuntimeIsRunning: { false }, lockScreenVideoIsActive: { false }, lockScreenCoordinator: coordinator,
        lockScreenFrameReadinessWaiter: { _, _ in frameReady },
        runningAgentNeedsReplacement: { needsReplacement }, sessionIsLocked: { locked })
    _ = try controller.start(config: .init(command: .init(executable: "/bin/echo", arguments: ["same source"])))
    let original = try #require(fixture.store.loadPID())
    try fixture.store.saveHealth(.init(agentPID: original, executableFingerprint: "old-helper"))
    let initialActivations = coordinator.activations
    needsReplacement = true
    frameReady = false
    #expect(throws: TerminalWallpaperControllerError.lockScreenFrameNotReady) {
        try controller.reconcileDeferredRuntimeUpdateIfRunning()
    }
    let replacement = try #require(fixture.store.loadPID())
    #expect(replacement != original && coordinator.activations == initialActivations)
    needsReplacement = false
    try fixture.store.saveHealth(.init(agentPID: replacement, executableFingerprint: "current-helper"))
    // A matching fingerprint must not lose the pending presentation work.
    frameReady = true
    locked = true
    #expect(try !controller.reconcileDeferredRuntimeUpdateIfRunning())
    #expect(fixture.store.loadPID() == replacement && coordinator.activations == initialActivations)
    locked = false
    coordinator.onActivate = { throw CocoaError(.fileWriteUnknown) }
    #expect(throws: CocoaError.self) { try controller.reconcileDeferredRuntimeUpdateIfRunning() }
    #expect(fixture.store.loadPID() == replacement)
    coordinator.onActivate = nil
    #expect(try controller.reconcileDeferredRuntimeUpdateIfRunning())
    let completedActivations = coordinator.activations
    for _ in 0..<5 { #expect(try !controller.reconcileDeferredRuntimeUpdateIfRunning()) }
    #expect(fixture.store.loadPID() == replacement && coordinator.activations == completedActivations)
    #expect(fixture.store.loadConfig().command.arguments == ["same source"])
}
