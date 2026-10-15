import AuraTerminalWallpaperCore
import Combine
import Foundation
import Testing
@testable import WallpaperControlApp

private final class UnifiedTerminalController: TerminalWallpaperControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var state: TerminalWallpaperStatus
    private var requests: [TerminalScaleMode] = []
    var failScale = false
    init(running: Bool, mode: TerminalScaleMode = .fit) {
        state = .init(running: running, config: .init(command: .init(executable: "/bin/echo", arguments: ["installed"]), render: .init(scaleMode: mode)))
    }
    var modes: [TerminalScaleMode] { lock.withLock { requests } }
    func status() throws -> TerminalWallpaperStatus { lock.withLock { state } }
    func updateScaleMode(_ mode: TerminalScaleMode) throws -> TerminalWallpaperStatus {
        try lock.withLock {
            requests.append(mode)
            if failScale { throw TerminalWallpaperControllerError.unavailable("scale rejected") }
            if state.running { state.config.render.scaleMode = mode }
            return state
        }
    }
    func stop() throws -> TerminalWallpaperStatus { lock.withLock { state.running = false; return state } }
    func terminate() throws -> TerminalWallpaperStatus { try stop() }
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Scale must not start") }
    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Scale must not restart") }
    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Scale must not apply drafts") }
    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Scale must not resize") }
    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError() }
}

private final class UnifiedVideoController: WallpaperControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var state: ControlStatus
    private var requests: [WallpaperScaleMode] = []
    var failScale = false
    var delay: UInt64 = 0
    init(running: Bool = false, paused: Bool = false, lockOnly: Bool = false) {
        state = .init(running: running, config: .defaultConfig, paused: paused, lock_screen_only: lockOnly)
        state.config.scale_mode = "fit"
        if paused { state.config.video_path = "/tmp/unified-scale-paused.mp4" }
    }
    var modes: [WallpaperScaleMode] { lock.withLock { requests } }
    func status() throws -> ControlStatus { lock.withLock { state } }
    func setScaleMode(_ mode: WallpaperScaleMode) async throws -> ControlStatus {
        lock.withLock { requests.append(mode) }
        // Ignore cancellation deliberately to verify stale response protection.
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return try lock.withLock {
            if failScale { throw NativeWallpaperControllerError.unavailable("scale rejected") }
            state.config.scale_mode = mode.rawValue
            return state
        }
    }
    func clearWallpaper() async throws -> ControlStatus { lock.withLock { state.running = false; state.paused = false; state.lock_screen_only = false; return state } }
    func start(videoURL: URL?, speed: Double?) async throws -> ControlStatus { fatalError() }
    func resume() throws -> ControlStatus { try status() }
    func stop() throws -> ControlStatus { try status() }
    func setVideo(_ url: URL) throws -> ControlStatus { fatalError() }
    func setSpeed(_ speed: Double) async throws -> ControlStatus { try status() }
    func setInterpolation(_ enabled: Bool) throws -> ControlStatus { try status() }
    func setPauseOnFullscreen(_ enabled: Bool) throws -> ControlStatus { try status() }
    func setShowOnLockScreen(_ enabled: Bool) async throws -> ControlStatus { try status() }
    func syncLockScreenSaver() async throws {}
    func beginLockScreenPreview() throws -> ControlStatus { try status() }
    func endLockScreenPreview() throws -> ControlStatus { try status() }
    func setAutostart(_ enabled: Bool) throws -> ControlStatus { try status() }
    func metrics() throws -> DaemonMetrics { .init(running: false) }
}

@MainActor private func waitUnifiedScale(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(condition())
}

@MainActor private struct UnifiedScaleFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let selection: WallpaperPreviewSelectionStore
    let terminalController: UnifiedTerminalController
    let terminal: TerminalWallpaperViewModel
    let video: UnifiedVideoController
    let app: AppViewModel
    init(terminalRunning: Bool = false, video: UnifiedVideoController = UnifiedVideoController()) {
        selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
        selection.selectTerminal(.init(command: .init(executable: "/bin/echo", arguments: ["preview"]), render: .init(scaleMode: .fill)))
        terminalController = UnifiedTerminalController(running: terminalRunning)
        terminal = TerminalWallpaperViewModel(controller: terminalController, previewSelectionStore: selection)
        self.video = video
        app = AppViewModel(controller: video, appSupportDirectoryURL: root, previewSelectionStore: selection)
        app.connectTerminalScaleControls(terminal)
    }
    func cleanup() { selection.selectVideo(); try? FileManager.default.removeItem(at: root) }
}

@Test @MainActor func unifiedScaleUsesInstalledTerminalDespiteVideoPreviewAndMatchingDraft() async throws {
    let f = UnifiedScaleFixture(terminalRunning: true)
    defer { f.cleanup() }
    f.selection.selectVideo()
    #expect(f.app.scaleControlTarget == .terminal(installed: true))
    #expect(f.terminal.scaleMode == .fill && f.app.settingsScaleMode == .fit)
    #expect(f.app.canToggleScaleMode)
    f.app.setScaleMode(.fill)
    #expect(f.app.settingsScaleMode == .fill)
    try await waitUnifiedScale { f.terminal.status.config.render.scaleMode == .fill }
    #expect(f.terminalController.modes == [.fill])
    #expect(f.video.modes.isEmpty)
    #expect(f.selection.kind == .video)
    #expect(f.terminal.status.config.command.arguments == ["installed"])
    f.terminal.stop()
    try await waitUnifiedScale { !f.terminal.isBusy && !f.terminal.status.running }
    #expect(f.app.scaleControlTarget == .video(installed: false))
}

@Test(arguments: [0, 1, 2]) @MainActor
func unifiedScaleUsesInstalledVideoIncludingPausedAndLockOnly(state: Int) async throws {
    let video = UnifiedVideoController(running: state == 0, paused: state == 1, lockOnly: state == 2)
    let f = UnifiedScaleFixture(video: video)
    defer { f.cleanup() }
    await f.app.loadStatus()
    #expect(f.app.scaleControlTarget == .video(installed: true))
    #expect(f.app.settingsScaleMode == .fit)
    f.app.setScaleMode(.stretch)
    #expect(f.app.settingsScaleMode == .stretch)
    try await waitUnifiedScale { f.app.settingsScaleMode == .stretch && !video.modes.isEmpty }
    try await Task.sleep(for: .milliseconds(30))
    #expect(video.modes == [.stretch])
    #expect(f.terminalController.modes.isEmpty)
    #expect(f.selection.kind == .terminal)
    #expect(f.selection.terminalConfiguration?.render.scaleMode == .fill)
}

@Test @MainActor func unifiedScalePreviewFallbackAndUnsupportedWeb() async throws {
    let f = UnifiedScaleFixture()
    defer { f.cleanup() }
    #expect(f.app.scaleControlTarget == .terminal(installed: false))
    f.app.setScaleMode(.fit)
    #expect(f.selection.terminalConfiguration?.render.scaleMode == .fit)
    try await waitUnifiedScale { f.terminalController.modes == [.fit] }
    f.selection.selectVideo()
    f.app.setScaleMode(.stretch)
    try await waitUnifiedScale { f.video.modes == [.stretch] }
    f.selection.selectWeb("test-project")
    #expect(f.app.scaleControlTarget == .unsupported)
    #expect(!f.app.canToggleScaleMode)
    f.app.setScaleMode(.fill)
    #expect(f.video.modes == [.stretch])
}

@Test @MainActor func unifiedScaleTerminalErrorRollsBackAndIsVisibleInGeneralSettings() async throws {
    let f = UnifiedScaleFixture(terminalRunning: true)
    defer { f.cleanup() }
    f.terminalController.failScale = true
    f.app.setScaleMode(.stretch)
    try await waitUnifiedScale { f.app.alertMessage != nil }
    #expect(f.app.settingsScaleMode == .fit)
    #expect(f.terminal.scaleMode == .fit)
    #expect(f.selection.terminalConfiguration?.render.scaleMode == .fit)
}

@Test @MainActor func unifiedScaleVideoErrorRollsBackWithoutChangingTerminalPreview() async throws {
    let video = UnifiedVideoController(running: true)
    video.failScale = true
    let f = UnifiedScaleFixture(video: video)
    defer { f.cleanup() }
    await f.app.loadStatus()
    f.app.setScaleMode(.stretch)
    try await waitUnifiedScale { f.app.alertMessage != nil }
    #expect(f.app.settingsScaleMode == .fit)
    #expect(f.selection.kind == .terminal)
    #expect(f.selection.terminalConfiguration?.render.scaleMode == .fill)
}

@Test @MainActor func unifiedScaleIgnoresVideoResponseAfterTargetChange() async throws {
    let video = UnifiedVideoController()
    video.delay = 100_000_000
    let f = UnifiedScaleFixture(video: video)
    defer { f.cleanup() }
    f.selection.selectVideo()
    f.app.setScaleMode(.stretch)
    try await waitUnifiedScale { video.modes == [.stretch] }
    f.selection.selectTerminal(.init(command: .init(executable: "/bin/echo"), render: .init(scaleMode: .fill)))
    try await Task.sleep(for: .milliseconds(150))
    #expect(f.app.scaleControlTarget == .terminal(installed: false))
    #expect(f.app.settingsScaleMode == .fill)
    #expect(f.selection.kind == .terminal)
    #expect(f.app.statusMessage?.hasPrefix("Scale mode:") != true)
}

@Test @MainActor func unifiedScaleRapidVideoChangesAndRemoveKeepTheLatestTarget() async throws {
    let video = UnifiedVideoController(running: true)
    video.delay = 80_000_000
    let f = UnifiedScaleFixture(video: video)
    defer { f.cleanup() }
    await f.app.loadStatus()
    f.app.setScaleMode(.fill)
    f.app.setScaleMode(.stretch)
    #expect(f.app.settingsScaleMode == .stretch)
    try await waitUnifiedScale { (try? video.status().config.scale_mode) == "stretch" }
    #expect(f.app.settingsScaleMode == .stretch)
    f.app.setScaleMode(.fit)
    try await waitUnifiedScale { video.modes.last == .fit }
    f.app.clearWallpaper()
    try await waitUnifiedScale { !f.app.isLifecycleBusy && !f.app.hasInstalledWallpaperSessionForControls }
    try await Task.sleep(for: .milliseconds(120))
    #expect(f.app.scaleControlTarget == .terminal(installed: false))
    #expect(f.app.settingsScaleMode == .fill)
    #expect(!f.app.hasInstalledWallpaperSessionForControls)
    #expect(f.selection.kind == .terminal)
}
