import AppKit
import AuraTerminalWallpaperCore
import Foundation
import Testing
@testable import AuraTerminalWallpaperAgent
@testable import WallpaperControlApp

private final class PlaybackTerminalController: TerminalWallpaperControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var value = TerminalWallpaperStatus(running: true, pid: 123,
        config: .init(command: .init(executable: "/bin/echo", arguments: ["installed"])))
    var fail = false
    private(set) var pauseRequests: [Bool] = []
    func status() throws -> TerminalWallpaperStatus { lock.withLock { value } }
    func setPlaybackPaused(_ paused: Bool) throws -> TerminalWallpaperStatus {
        try lock.withLock {
            pauseRequests.append(paused)
            if fail { throw TerminalWallpaperControllerError.unavailable("signal failed") }
            if value.running { value.paused = paused }
            return value
        }
    }
    func stop() throws -> TerminalWallpaperStatus {
        lock.withLock { value.running = false; value.paused = false; value.pid = nil; return value }
    }
    func terminate() throws -> TerminalWallpaperStatus { try stop() }
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Pause must not start") }
    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Pause must not restart") }
    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Pause must not apply drafts") }
    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Pause must not resize") }
    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError() }
}

@MainActor private func awaitPlayback(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@Test @MainActor func terminalPlaybackControlsTargetInstalledCLIAndKeepRemoveSeparate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("preview.json"))
    selection.selectVideo()
    let controller = PlaybackTerminalController()
    let terminal = TerminalWallpaperViewModel(controller: controller, previewSelectionStore: selection)
    let video = MockNativeWallpaperController()
    let app = AppViewModel(controller: video, appSupportDirectoryURL: root, previewSelectionStore: selection)
    app.connectTerminalScaleControls(terminal)
    app.terminalIsActive = { terminal.status.running }
    let original = terminal.status.config
    #expect(app.canTogglePlayback)
    #expect(!app.canStart)
    app.togglePlayback()
    try await awaitPlayback { !terminal.isBusy && terminal.status.paused }
    #expect(app.isPlaybackPausedForControls)
    #expect(app.playbackButtonTitle == "Play")
    #expect(terminal.statusTitle == "Paused")
    #expect(terminal.status.pid == 123 && terminal.status.config == original)
    app.togglePlayback()
    try await awaitPlayback { !terminal.isBusy && !terminal.status.paused }
    #expect(app.playbackButtonTitle == "Stop")
    #expect(controller.pauseRequests == [true, false])
    #expect(video.stopCallCount == 0 && video.resumeCallCount == 0)
    controller.fail = true
    app.togglePlayback()
    try await awaitPlayback { !terminal.isBusy && terminal.errorMessage != nil }
    #expect(!terminal.status.paused && terminal.status.running)
    #expect(app.alertMessage?.contains("signal failed") == true)
    controller.fail = false
    app.togglePlayback()
    try await awaitPlayback { !terminal.isBusy && terminal.status.paused }
    terminal.stop()
    try await awaitPlayback { !terminal.isBusy && !terminal.status.running }
    terminal.togglePlayback()
    #expect(controller.pauseRequests == [true, false, true, true])
    #expect(!terminal.status.paused && terminal.status.pid == nil)
}

private struct PlaybackLockScreen: TerminalLockScreenCoordinating {
    func activate() throws { Issue.record("Pause must not replace the Lock Screen route") }
    func restore() throws { Issue.record("Pause must not restore the Lock Screen route") }
}

@Test func terminalPlaybackControllerPersistsIntentWithoutReplacingConfigAndRollsBackFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = TerminalWallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("launch.plist"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    defer {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }
    let config = TerminalWallpaperConfig(command: .init(executable: "/bin/echo", arguments: ["active"]))
    try store.saveConfig(config)
    try store.savePID(process.processIdentifier)
    let controller = try NativeTerminalWallpaperController(store: store,
        helperURL: URL(fileURLWithPath: "/usr/bin/true"), videoRuntimeIsRunning: { false },
        lockScreenVideoIsActive: { false }, lockScreenCoordinator: PlaybackLockScreen())
    for paused in [true, false, true] {
        let status = try controller.setPlaybackPaused(paused)
        #expect(status.running && status.paused == paused)
        #expect(status.pid == Int(process.processIdentifier) && status.config == config)
        #expect(store.loadCommand()?.action == (paused ? .pause : .resume))
        #expect(store.loadCommand()?.config == config)
        #expect(TerminalWallpaperRuntimeStore(appSupportURL: root).isPlaybackPaused == paused)
    }
    store.removeCommand()
    try FileManager.default.createDirectory(at: store.commandURL, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) { try controller.setPlaybackPaused(false) }
    #expect(store.isPlaybackPaused)
    try FileManager.default.removeItem(at: store.commandURL)
    process.terminate(); process.waitUntilExit()
    store.removePID()
    let stopped = try controller.setPlaybackPaused(false)
    #expect(!stopped.running && !stopped.paused)
    #expect(store.loadCommand() == nil)
}

@Test func terminalManualPauseSurvivesFullscreenAndLockTransitions() {
    var policy = TerminalFullscreenPausePolicy()
    policy.manuallyPaused = true
    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: true) == nil)
    #expect(policy.update(enabled: true, screenLocked: false, foregroundIsFullscreen: true) == true)
    policy.manuallyPaused = false
    #expect(policy.playbackIsPaused) // Resume cannot override an active fullscreen pause.
    policy.manuallyPaused = true
    #expect(policy.update(enabled: true, screenLocked: true, foregroundIsFullscreen: false) == false)
    #expect(policy.playbackIsPaused) // Lock/unlock must not undo the explicit Stop.
    #expect(policy.update(enabled: false, screenLocked: false, foregroundIsFullscreen: false) == nil)
    #expect(policy.playbackIsPaused)
    policy.manuallyPaused = false
    #expect(!policy.playbackIsPaused)
}

@MainActor private func pumpPlayback(for duration: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        pumpPlaybackAppKit()
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor private func pumpPlaybackAppKit() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}

@Test @MainActor func terminalPlaybackRealPTYRetainsPIDFrameAndLeaseThenResumes() async throws {
    try await checkRealTerminalPlayback(staticOutput: false)
}

@Test @MainActor func terminalPlaybackStaticFrameIsRetainedWithoutRerunningCommand() async throws {
    try await checkRealTerminalPlayback(staticOutput: true)
}

@MainActor private func checkRealTerminalPlayback(staticOutput: Bool) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = TerminalWallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("launch.plist"))
    let script = staticOutput
        ? "printf x >> '\(root.path)/launches'; printf '\\033[41mSTATIC FRAME'"
        : "while :; do printf '\\033[Hframe %s' \"$(date +%s)\"; sleep 0.05; done"
    let config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh", arguments: ["-c", script]),
        render: .init(pixelMode: .fixed, fixedWidth: 320, fixedHeight: 240, columns: 20, rows: 4, fontSize: 18),
        behavior: .init(allDisplays: false, pauseOnFullscreen: false))
    try store.saveConfig(config)
    let delegate = TerminalWallpaperAgentDelegate(configurationURL: store.configURL, managesLockScreenPresentation: false)
    var terminated = false
    defer {
        if !terminated {
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }
        try? FileManager.default.removeItem(at: root)
    }
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    try await pumpPlayback(for: 2.5)
    let original = try #require(store.loadHealth())
    #expect(original.running && original.childRunning == !staticOutput)
    #expect(store.loadSharedFrameDescriptor() != nil)
    try store.setPlaybackPaused(true)
    try store.saveCommand(.init(action: .pause, config: config))
    // Health is published every two seconds. Wait for the first periodic
    // sample after the last in-flight frame completes before comparing it.
    try await pumpPlayback(for: 2.5)
    let paused = try #require(store.loadHealth())
    let heartbeat = try #require(store.loadLockScreenHeartbeat())
    let frame = try Data(contentsOf: store.lockScreenFrameURL)
    let sharedFrame = store.loadSharedFrameDescriptor()
    try await pumpPlayback(for: 2.5)
    let settled = try #require(store.loadHealth())
    #expect(settled.frames == paused.frames)
    #expect(settled.renderedFrames == paused.renderedFrames)
    #expect(settled.childPID == original.childPID)
    #expect(settled.columns == original.columns && settled.rows == original.rows)
    #expect(settled.lastError == nil)
    #expect(try Data(contentsOf: store.lockScreenFrameURL) == frame)
    #expect(store.loadSharedFrameDescriptor() == sharedFrame)
    #expect((store.loadLockScreenHeartbeat()?.updatedAt ?? 0) > heartbeat.updatedAt)
    // A presentation update may supersede Pause in command.json; the persisted
    // manual intent must remain effective, also for completed static commands.
    var updated = config
    updated.render.scaleMode = .stretch
    try store.saveCommand(.init(action: .update, config: updated))
    try await pumpPlayback(for: 1)
    #expect(store.isPlaybackPaused)
    #expect(store.loadHealth()?.childPID == original.childPID)
    #expect(store.loadHealth()?.columns == original.columns)
    try store.setPlaybackPaused(false)
    try store.saveCommand(.init(action: .resume, config: updated))
    try await pumpPlayback(for: 2.5)
    let resumed = try #require(store.loadHealth())
    #expect(resumed.childPID == original.childPID)
    #expect(resumed.running && resumed.lastError == nil)
    if staticOutput {
        #expect(!resumed.childRunning && resumed.frames == original.frames)
        #expect(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8) == "x")
    } else {
        #expect(resumed.frames > settled.frames && resumed.renderedFrames > settled.renderedFrames)
        try store.setPlaybackPaused(true)
        try store.saveCommand(.init(action: .pause, config: updated))
        try await pumpPlayback(for: 1)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        terminated = true
        #expect(store.loadPID() == nil && store.loadLockScreenHeartbeat() == nil)
        if let childPID = original.childPID {
            #expect(kill(pid_t(childPID), 0) == -1 && errno == ESRCH)
        }
    }
}
