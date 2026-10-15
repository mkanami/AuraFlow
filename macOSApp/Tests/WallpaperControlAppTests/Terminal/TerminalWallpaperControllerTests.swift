import AuraTerminalWallpaperCore
import Foundation
import Testing
@testable import WallpaperControlApp

private final class MockTerminalLockScreenCoordinator: TerminalLockScreenCoordinating, @unchecked Sendable {
    private(set) var activations = 0
    private(set) var restorations = 0
    var onRestore: (() throws -> Void)?
    func activate() throws { activations += 1 }
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

@Test func terminalControllerWritesOnlyItsOwnRuntimeNamespace() throws {
    let fixture = try TerminalControllerFixture("isolated-store")
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
    #expect(fixture.store.loadConfig().command.executable == "/bin/echo")
    #expect(fixture.store.loadCommand()?.action == .start)
    #expect(FileManager.default.fileExists(atPath: fixture.store.configURL.path))
    #expect(!FileManager.default.fileExists(
        atPath: fixture.store.appSupportURL.deletingLastPathComponent().appendingPathComponent("config.json").path
    ))

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
        try JSONSerialization.data(withJSONObject: ["show_on_lock_screen": enabled]).write(to: sharedConfig, options: .atomic)
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
