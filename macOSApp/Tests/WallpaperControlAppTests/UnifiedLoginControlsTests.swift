import AuraTerminalWallpaperCore
import AuraWallpaperCore
import Foundation
import Testing
@testable import WallpaperControlApp

private final class LoginTerminal: TerminalWallpaperControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TerminalWallpaperStatus
    private var requests: [TerminalWallpaperConfig] = []
    var fail = false
    init(running: Bool) {
        value = .init(running: running, pid: running ? 123 : nil,
            config: .init(command: .init(executable: "/bin/echo", arguments: ["installed"]),
                          render: .init(columns: 80, rows: 24, fontSize: 14)))
    }
    var loginRequests: [TerminalWallpaperConfig] { lock.withLock { requests } }
    func status() throws -> TerminalWallpaperStatus { lock.withLock { value } }
    func setLaunchAtLogin(_ enabled: Bool, config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus {
        try lock.withLock {
            requests.append(config)
            if fail { throw TerminalWallpaperControllerError.unavailable("registration failed") }
            value.config = config
            value.config.behavior.launchAtLogin = enabled
            return value
        }
    }
    func start(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Login must not start") }
    func stop() throws -> TerminalWallpaperStatus { fatalError("Login must not remove") }
    func terminate() throws -> TerminalWallpaperStatus { fatalError("Login must not terminate") }
    func restart(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Login must not restart") }
    func update(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Login must not apply drafts") }
    func resize(config: TerminalWallpaperConfig) throws -> TerminalWallpaperStatus { fatalError("Login must not resize") }
}

private final class LoginVideo: WallpaperControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ControlStatus
    private var requests: [Bool] = []
    var fail = false
    init(root: URL, running: Bool = false, paused: Bool = false, lockOnly: Bool = false, image: Bool = false) {
        value = .init(running: running,
            config: .init(video_path: root.appendingPathComponent(image ? "wallpaper.png" : "wallpaper.mp4").path,
                          playback_speed: 0.75, scale_mode: "fit"),
            paused: paused, lock_screen_only: lockOnly)
    }
    var loginRequests: [Bool] { lock.withLock { requests } }
    func status() throws -> ControlStatus { lock.withLock { value } }
    func setAutostart(_ enabled: Bool) throws -> ControlStatus {
        try lock.withLock {
            requests.append(enabled)
            if fail { throw NativeWallpaperControllerError.unavailable("registration failed") }
            value.config.autostart = enabled; value.autostart = enabled
            return value
        }
    }
    func start(videoURL: URL?, speed: Double?) async throws -> ControlStatus { fatalError("Login must not start") }
    func setVideo(_ url: URL) throws -> ControlStatus { fatalError("Login must not change preview/source") }
    func clearWallpaper() async throws -> ControlStatus { fatalError("Login must not remove") }
    func setScaleMode(_ mode: WallpaperScaleMode) async throws -> ControlStatus { fatalError("Login must not change scale") }
    func resume() throws -> ControlStatus { fatalError() }
    func stop() throws -> ControlStatus { fatalError() }
    func setSpeed(_ speed: Double) async throws -> ControlStatus { fatalError() }
    func setInterpolation(_ enabled: Bool) throws -> ControlStatus { fatalError() }
    func setPauseOnFullscreen(_ enabled: Bool) throws -> ControlStatus { fatalError() }
    func setShowOnLockScreen(_ enabled: Bool) async throws -> ControlStatus { fatalError() }
    func syncLockScreenSaver() async throws {}
    func beginLockScreenPreview() throws -> ControlStatus { fatalError() }
    func endLockScreenPreview() throws -> ControlStatus { fatalError() }
    func metrics() throws -> DaemonMetrics { .init(running: false) }
}

@MainActor private func awaitLogin(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(predicate())
}

@Test @MainActor func unifiedLoginUsesInstalledTerminalAndPreservesDifferentPreviewAndDrafts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    selection.selectTerminal(.init(command: .init(executable: "/bin/echo", arguments: ["different preview"])))
    let controller = LoginTerminal(running: true)
    let terminal = TerminalWallpaperViewModel(controller: controller, previewSelectionStore: selection)
    terminal.fontSize = 42
    let original = try controller.status().config
    let video = LoginVideo(root: root)
    let app = AppViewModel(controller: video, appSupportDirectoryURL: root, previewSelectionStore: selection)
    app.connectTerminalScaleControls(terminal)
    selection.selectVideo()
    #expect(app.canToggleAutostart && !app.settingsAutostartEnabled)
    app.toggleAutostart(true)
    #expect(app.settingsAutostartEnabled && !app.canToggleAutostart)
    app.toggleAutostart(false) // A second click while busy must not queue another transaction.
    try await awaitLogin { !terminal.isBusy }
    var expected = original
    expected.behavior.launchAtLogin = true
    #expect(controller.loginRequests == [expected])
    #expect(try controller.status().config == expected && terminal.status.pid == 123)
    #expect(terminal.argumentsText == "different preview" && terminal.fontSize == 42)
    #expect(selection.kind == .video && video.loginRequests.isEmpty)
    controller.fail = true
    app.toggleAutostart(false)
    try await awaitLogin { !terminal.isBusy && terminal.errorMessage != nil }
    #expect(app.settingsAutostartEnabled)
    #expect(app.alertMessage?.contains("registration failed") == true)
}

@Test @MainActor func unifiedLoginConfiguresTerminalPreviewWithoutStartingAndRestoresSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    selection.selectTerminal(.init(command: .init(executable: "/bin/echo", arguments: ["preview"])))
    let terminalController = LoginTerminal(running: false)
    let terminal = TerminalWallpaperViewModel(controller: terminalController, previewSelectionStore: selection)
    let app = AppViewModel(controller: LoginVideo(root: root), appSupportDirectoryURL: root, previewSelectionStore: selection)
    app.connectTerminalScaleControls(terminal)
    app.toggleAutostart(true)
    try await awaitLogin { !terminal.isBusy }
    #expect(!terminal.status.running && terminal.status.pid == nil && app.settingsAutostartEnabled)
    let restored = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    #expect(restored.terminalConfiguration?.behavior.launchAtLogin == true)
    #expect(restored.terminalConfiguration?.command.arguments == ["preview"])
}

@Test(arguments: [0, 1, 2, 3]) @MainActor func unifiedLoginUsesInstalledVideoDespiteTerminalPreview(state: Int) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    selection.selectTerminal(.init(command: .init(executable: "/bin/echo")))
    let terminalController = LoginTerminal(running: false)
    let terminal = TerminalWallpaperViewModel(controller: terminalController, previewSelectionStore: selection)
    let video = LoginVideo(root: root, running: state == 0 || state == 3, paused: state == 1,
                           lockOnly: state == 2, image: state == 3)
    let app = AppViewModel(controller: video, appSupportDirectoryURL: root, previewSelectionStore: selection)
    app.connectTerminalScaleControls(terminal)
    await app.loadStatus()
    let original = try video.status().config
    app.toggleAutostart(true)
    #expect(app.isBusy && app.settingsAutostartEnabled)
    try await awaitLogin { !app.isBusy }
    #expect(video.loginRequests == [true] && terminalController.loginRequests.isEmpty)
    var expected = original; expected.autostart = true
    #expect(try video.status().config == expected)
    #expect(selection.kind == .terminal)
    video.fail = true
    app.toggleAutostart(false)
    try await awaitLogin { !app.isBusy }
    #expect(app.settingsAutostartEnabled && app.alertMessage?.contains("registration failed") == true)
}

@Test func unifiedLoginTerminalRegistrationPreservesRunningConfigPIDAndFrame() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let launch = root.appendingPathComponent("LaunchAgents/login.plist")
    let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal"), launchAgentURL: launch)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep"); process.arguments = ["30"]
    try process.run()
    defer {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: root)
    }
    let applied = TerminalWallpaperConfig(command: .init(executable: "/bin/echo", arguments: ["installed"]),
        render: .init(columns: 80, rows: 24, fontSize: 14))
    try store.saveConfig(applied)
    try store.savePID(process.processIdentifier)
    try store.setPlaybackPaused(true)
    let frame = Data("retained static frame".utf8)
    try frame.write(to: store.lockScreenFrameURL)
    let controller = try NativeTerminalWallpaperController(store: store, helperURL: URL(fileURLWithPath: "/usr/bin/true"),
        videoRuntimeIsRunning: { false }, lockScreenVideoIsActive: { false })
    let draft = TerminalWallpaperConfig(command: .init(executable: "/does/not/exist"), render: .init(fontSize: 42))
    let enabled = try controller.setLaunchAtLogin(true, config: draft)
    var expected = applied; expected.behavior.launchAtLogin = true
    #expect(enabled.config == expected && enabled.pid == Int(process.processIdentifier) && enabled.paused)
    #expect(try Data(contentsOf: store.lockScreenFrameURL) == frame)
    let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: launch), format: nil) as? [String: Any])
    #expect(plist["RunAtLoad"] as? Bool == true)
    #expect(plist["ProgramArguments"] as? [String] == ["/usr/bin/true", "--config", store.configURL.path])
    #expect(store.loadCommand() == nil, "A future-login preference must not issue a current playback command")
    let disabled = try controller.setLaunchAtLogin(false, config: draft)
    #expect(disabled.config == applied && disabled.pid == enabled.pid && disabled.paused)
    #expect(!FileManager.default.fileExists(atPath: launch.path))
    #expect(try Data(contentsOf: store.lockScreenFrameURL) == frame)
}

@Test func unifiedLoginTerminalRegistrationFailureRestoresConfigurationAndCanDisableMissingCLI() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents")
            .appendingPathComponent(String(repeating: "x", count: 300) + ".plist"))
    let original = TerminalWallpaperConfig(command: .init(executable: "/bin/echo", arguments: ["original"]))
    try store.saveConfig(original)
    let controller = try NativeTerminalWallpaperController(store: store, helperURL: URL(fileURLWithPath: "/usr/bin/true"))
    var draft = original; draft.command.arguments = ["different"]
    #expect(throws: (any Error).self) { try controller.setLaunchAtLogin(true, config: draft) }
    #expect(store.loadConfig() == original)
    #expect(store.loadCommand() == nil && store.loadPID() == nil)
    draft.command.executable = "/deleted/cli"
    #expect(try controller.setLaunchAtLogin(false, config: draft).config.behavior.launchAtLogin == false)
}

@Test(arguments: [false, true]) func unifiedLoginOrdinaryAndLockOnlyLaunchAgentsUseCorrectSourceAndArguments(lockOnly: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let launch = root.appendingPathComponent("LaunchAgents/login.plist")
    var commands: [[String]] = []
    let store = WallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("support"), launchAgentURL: launch,
        launchctlRunner: { arguments in
            commands.append(arguments)
            return .init(succeeded: true, output: "state = running")
        })
    try store.ensureDirectories()
    let image = root.appendingPathComponent("wallpaper.png")
    try Data("image".utf8).write(to: image)
    try store.saveConfig(.init(video_path: lockOnly ? "" : image.path, playback_speed: 1))
    if lockOnly { try store.saveLockScreenOnlySource(image) }
    let manager = AutostartManager(store: store, helperURL: URL(fileURLWithPath: "/usr/bin/true"))
    let status = try manager.setEnabled(true)
    #expect(status.config.autostart == true && store.launchAgentPlistExists())
    let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: launch), format: nil) as? [String: Any])
    let args = try #require(plist["ProgramArguments"] as? [String])
    #expect(args.contains("--lock-screen-only") == lockOnly)
    #expect(args.contains(store.configURL.path))
    _ = try manager.setEnabled(false)
    #expect(!store.launchAgentPlistExists() && store.loadConfig().autostart == false)
    #expect(commands.allSatisfy { $0.first == "print" })
}
