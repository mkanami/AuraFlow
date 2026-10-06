import AuraTerminalWallpaperCore
import AuraWallpaperCore
import Foundation
import Testing
@testable import WallpaperControlApp

private final class RemovalController: TerminalWallpaperControlling, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var current: TerminalWallpaperStatus
    private var calls = 0
    let fails: Bool
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    init(running: Bool, fails: Bool = false) {
        current = .init(running: running, config: .defaultConfig)
        self.fails = fails
    }
    func status() throws -> TerminalWallpaperStatus { lock.lock(); defer { lock.unlock() }; return current }
    func terminate() throws -> TerminalWallpaperStatus {
        lock.lock(); calls += 1; lock.unlock()
        entered.signal()
        release.wait()
        if fails { throw TerminalWallpaperControllerError.unavailable("Restore failed") }
        lock.lock(); current.running = false; let result = current; lock.unlock()
        return result
    }
    func stop() throws -> TerminalWallpaperStatus { throw TerminalWallpaperControllerError.unavailable("Remove must terminate") }
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try status() }
    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try status() }
    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try status() }
    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try status() }
    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { try status() }
}

@Test(arguments: [false, true]) @MainActor
func terminalRemoveClearsPreviewImmediatelyAndRejectsRepeatedClicks(running: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraRemove-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    selection.selectTerminal(.init(command: .init(executable: "/bin/echo", arguments: ["frame"])))
    let controller = RemovalController(running: running)
    defer { controller.release.signal() }
    let model = TerminalWallpaperViewModel(controller: controller, previewSelectionStore: selection, resolveExecutable: { _ in nil })
    let app = AppViewModel(appSupportDirectoryURL: root.appendingPathComponent("app"), previewSelectionStore: selection)
    app.terminalRemoveAction = { model.remove() }
    app.terminalCanRemove = { !model.isBusy }
    app.terminalIsActive = { model.status.running }
    #expect(app.canClearWallpaper)
    let started = Date()
    app.clearWallpaper()
    #expect(Date().timeIntervalSince(started) < 0.1)
    #expect(selection.kind == .video && selection.terminalConfiguration == nil)
    #expect(model.isBusy && !app.canClearWallpaper && !app.canStart && !app.canApplyLockScreenOnly)
    app.clearWallpaper()
    model.remove()
    let enteredDeadline = Date().addingTimeInterval(2)
    while controller.count == 0 && Date() < enteredDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(controller.count == 1)
    #expect(!app.lifecycleViewModel.isBusy)
    controller.release.signal()
    let deadline = Date().addingTimeInterval(2)
    while model.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(!model.isBusy && !model.status.running && model.errorMessage == nil)
    #expect(model.statusMessage == "Terminal Wallpaper removed.")
    let restored = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    #expect(restored.kind == .video && restored.terminalConfiguration == nil)
}

@Test(arguments: [false, true]) @MainActor
func terminalRemoveFailureAllowsRetryWithoutOverwritingANewerSelection(selectNewSource: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraRemoveFailure-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    let previous = TerminalWallpaperConfig(command: .init(executable: "/bin/echo", arguments: ["previous"]))
    selection.selectTerminal(previous)
    let controller = RemovalController(running: true, fails: true)
    defer { controller.release.signal() }
    let model = TerminalWallpaperViewModel(controller: controller, previewSelectionStore: selection, resolveExecutable: { _ in nil })
    model.remove()
    #expect(selection.kind == .video)
    if selectNewSource { selection.selectWeb("new-source") }
    controller.release.signal()
    let deadline = Date().addingTimeInterval(2)
    while model.isBusy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(!model.isBusy && model.errorMessage == "Restore failed")
    #expect(model.statusMessage == nil)
    if selectNewSource {
        #expect(selection.kind == .web && selection.webProjectID == "new-source")
    } else {
        #expect(selection.kind == .terminal && selection.terminalConfiguration == previous.normalized())
    }
}

@Test func terminalRemoveMenuAcceptsPreviewAndKeepsActiveRuntimePriority() {
    #expect(WallpaperMenuActionPolicy.removeTarget(terminalRuntimeActive: false, videoRuntimeActive: false,
        terminalPreviewSelected: true) == .terminal)
    #expect(WallpaperMenuActionPolicy.removeTarget(terminalRuntimeActive: false, videoRuntimeActive: true,
        terminalPreviewSelected: true) == .video)
    #expect(WallpaperMenuActionPolicy.removeTarget(terminalRuntimeActive: false, videoRuntimeActive: false,
        webRuntimeActive: true, terminalPreviewSelected: true) == .web)
}

private struct RemovalLockScreen: TerminalLockScreenCoordinating {
    func activate() throws {}
    func restore() throws {}
}

@Test(arguments: [false, true]) @MainActor
func terminalRemoveReapsTheRealAgentAndCLIProcessGroup(paused: Bool) async throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let helper = package.appendingPathComponent(".build/debug/AuraTerminalWallpaperAgent")
    guard FileManager.default.isExecutableFile(atPath: helper.path) else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraRemoveAgent-\(UUID())")
    let store = TerminalWallpaperRuntimeStore(appSupportURL: root)
    let config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh", arguments: ["-c",
        "trap '' HUP; sleep 60 & echo $! > child.pid; printf '\\033[Hready'; wait"], workingDirectory: root.path),
        render: .init(columns: 40, rows: 20), behavior: .init(allDisplays: false, pauseOnFullscreen: false))
    try store.saveConfig(config)
    let process = Process()
    process.executableURL = helper
    process.arguments = ["--config", store.configURL.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: root)
    }
    let readyDeadline = Date().addingTimeInterval(6)
    while (store.loadHealth()?.childPID == nil || !FileManager.default.fileExists(atPath: root.appendingPathComponent("child.pid").path)) && Date() < readyDeadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    let child = try #require(store.loadHealth()?.childPID)
    let descendant = try #require(Int(String(contentsOf: root.appendingPathComponent("child.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { if DaemonProcessManager.isProcessAlive(pid: child) { kill(pid_t(child), SIGKILL) }; if DaemonProcessManager.isProcessAlive(pid: descendant) { kill(pid_t(descendant), SIGKILL) } }
    if paused { kill(pid_t(child), SIGSTOP) }
    let controller = try NativeTerminalWallpaperController(store: store, helperURL: helper, lockScreenCoordinator: RemovalLockScreen())
    let started = Date()
    let status = try await Task.detached { try controller.terminate() }.value
    #expect(Date().timeIntervalSince(started) < 2)
    #expect(!status.running && store.loadPID() == nil && store.loadHealth() == nil)
    #expect(store.loadSharedFrameDescriptor() == nil && store.loadLockScreenHeartbeat() == nil && store.loadCommand() == nil)
    let exitDeadline = Date().addingTimeInterval(1)
    while (process.isRunning || DaemonProcessManager.isProcessAlive(pid: child) || DaemonProcessManager.isProcessAlive(pid: descendant)) && Date() < exitDeadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(!process.isRunning && !DaemonProcessManager.isProcessAlive(pid: child) && !DaemonProcessManager.isProcessAlive(pid: descendant))
}
