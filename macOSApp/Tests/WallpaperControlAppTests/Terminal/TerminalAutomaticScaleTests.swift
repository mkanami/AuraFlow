import AuraTerminalWallpaperCore
import Foundation
import Testing
@testable import WallpaperControlApp

private final class ScaleController: TerminalWallpaperControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TerminalWallpaperStatus
    private var requests: [TerminalScaleMode] = []
    var firstRequestGate: DispatchSemaphore?
    var failMode: TerminalScaleMode?

    init(running: Bool = true) {
        value = .init(running: running, pid: running ? 123 : nil,
            config: .init(command: .init(executable: "/bin/echo", arguments: ["applied"]),
                          render: .init(columns: 80, rows: 24, fontSize: 14, scaleMode: .fill)))
    }
    func status() throws -> TerminalWallpaperStatus { lock.withLock { value } }
    var modes: [TerminalScaleMode] { lock.withLock { requests } }
    func updateScaleMode(_ mode: TerminalScaleMode) throws -> TerminalWallpaperStatus {
        let first = lock.withLock { requests.append(mode); return requests.count == 1 }
        if first { firstRequestGate?.wait() }
        return try lock.withLock {
            if failMode == mode { throw TerminalWallpaperControllerError.unavailable("test failure") }
            if value.running { value.config.render.scaleMode = mode }
            return value
        }
    }
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Scale must not start") }
    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Scale must not restart") }
    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Scale must not apply drafts") }
    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Scale must not resize") }
    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError() }
    func stop() throws -> TerminalWallpaperStatus { lock.withLock { value.running = false; value.pid = nil; return value } }
    func terminate() throws -> TerminalWallpaperStatus { try stop() }
}

@MainActor private func awaitScale(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(condition())
}

@Test @MainActor func terminalAutomaticScalePreservesAppliedCommandAndDrafts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    var preview = TerminalWallpaperConfig(command: .init(executable: "/bin/echo", arguments: ["preview"]))
    preview.render.scaleMode = .fill
    preview.render.fontSize = 30
    selection.selectTerminal(preview)
    let controller = ScaleController()
    let model = TerminalWallpaperViewModel(controller: controller, previewSelectionStore: selection)
    model.fontSize = 40
    model.argumentsText = "draft"
    let applied = try controller.status().config
    model.setScaleMode(.fit)
    #expect(model.scaleMode == .fit)
    #expect(selection.terminalConfiguration?.render.scaleMode == .fit)
    #expect(selection.terminalConfiguration?.command == preview.command)
    try await awaitScale { model.status.config.render.scaleMode == .fit }
    var expected = applied
    expected.render.scaleMode = .fit
    #expect(try controller.status().config == expected)
    #expect(model.fontSize == 40 && model.argumentsText == "draft")
    let restored = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    #expect(restored.terminalConfiguration?.render.scaleMode == .fit)
}

@Test @MainActor func terminalAutomaticScaleCoalescesAndRollsBackToLastAppliedMode() async throws {
    let controller = ScaleController()
    let gate = DispatchSemaphore(value: 0)
    controller.firstRequestGate = gate
    defer { gate.signal() }
    controller.failMode = .stretch
    let model = TerminalWallpaperViewModel(controller: controller)
    model.setScaleMode(.fit)
    try await awaitScale { controller.modes == [.fit] }
    model.setScaleMode(.fill)
    model.setScaleMode(.stretch)
    gate.signal()
    try await awaitScale { model.errorMessage != nil }
    #expect(controller.modes == [.fit, .stretch])
    #expect(model.scaleMode == .fit)
    #expect(try controller.status().config.render.scaleMode == .fit)
    #expect(!model.isBusy)
}

@Test @MainActor func terminalAutomaticScaleDoesNotReviveRemovedWallpaper() async throws {
    let controller = ScaleController()
    let gate = DispatchSemaphore(value: 0)
    controller.firstRequestGate = gate
    defer { gate.signal() }
    let model = TerminalWallpaperViewModel(controller: controller)
    model.setScaleMode(.fit)
    try await awaitScale { controller.modes == [.fit] }
    model.setScaleMode(.stretch)
    model.stop()
    try await awaitScale { !model.isBusy && !model.status.running }
    gate.signal()
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.modes == [.fit])
    #expect(!model.status.running)
    #expect(try controller.status().config.render.scaleMode == .fill)
}

@Test @MainActor func terminalAutomaticScaleWithoutWallpaperOnlyPersistsPreview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    selection.selectTerminal(.init(command: .init(executable: "/bin/echo"), render: .init(scaleMode: .fill)))
    let controller = ScaleController(running: false)
    let model = TerminalWallpaperViewModel(controller: controller, previewSelectionStore: selection)
    model.setScaleMode(.stretch)
    try await awaitScale { !controller.modes.isEmpty }
    #expect(model.scaleMode == .stretch)
    #expect(selection.terminalConfiguration?.render.scaleMode == .stretch)
    #expect(!model.status.running)
    #expect(try controller.status().config.render.scaleMode == .fill)
}

private struct AutomaticScaleLockScreen: TerminalLockScreenCoordinating {
    func activate() throws {}
    func restore() throws {}
}

@Test func terminalAutomaticScaleControllerUpdatesOnlyScaleAndIgnoresStoppedAgent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal"),
        launchAgentURL: root.appendingPathComponent("launch.plist"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]
    try process.run()
    defer {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }
    var original = TerminalWallpaperConfig(command: .init(executable: "/bin/echo", arguments: ["active"]),
        render: .init(pixelMode: .fixed, fixedWidth: 320, fixedHeight: 240, columns: 20, rows: 4, scaleMode: .fill))
    original.playbackSpeed = 1.25
    try store.saveConfig(original)
    try store.savePID(process.processIdentifier)
    let controller = try NativeTerminalWallpaperController(store: store,
        helperURL: URL(fileURLWithPath: "/usr/bin/true"), videoRuntimeIsRunning: { false },
        lockScreenVideoIsActive: { false }, lockScreenCoordinator: AutomaticScaleLockScreen())
    for mode in TerminalScaleMode.allCases {
        let latest = try controller.updateScaleMode(mode)
        var expected = original
        expected.render.scaleMode = mode
        #expect(latest.config == expected)
        #expect(latest.pid == Int(process.processIdentifier))
        #expect(store.loadCommand()?.action == .update)
        #expect(store.loadCommand()?.config == expected)
    }
    process.terminate()
    process.waitUntilExit()
    store.removePID()
    store.removeCommand()
    let previous = store.loadConfig()
    let latest = try controller.updateScaleMode(.fit)
    #expect(!latest.running)
    #expect(store.loadConfig() == previous)
    #expect(store.loadCommand() == nil)
}
