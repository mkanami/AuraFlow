import AppKit
import AuraWallpaperCore
import AuraTerminalWallpaperCore
import Testing
@testable import AuraTerminalWallpaperAgent
@testable import WallpaperControlApp

@Suite(.serialized)
struct TerminalLoginRestorationTests {
    @Test(arguments: [TerminalWallpaperCommandAction.update, .restart, .stop, .syncLockScreen]) @MainActor
    func newLoginRunsSavedCommandInsteadOfReplayingPreviousProcessCommands(staleAction: TerminalWallpaperCommandAction) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraTerminalLogin-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let video = WallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("unused.plist"))
        try video.saveConfig(.init(video_path: "", playback_speed: 1, show_on_lock_screen: false))
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal-wallpaper"),
            launchAgentURL: root.appendingPathComponent("terminal.plist"))
        let config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh", arguments: ["-c", "n=0; while :; do printf '\\033[Hframe %s' \"$n\"; n=$((n+1)); sleep 0.05; done"]),
            render: .init(columns: 40, rows: 10, maxFPS: 15))
        try store.saveConfig(config)
        try store.saveCommand(.init(action: staleAction, config: .init(command: .init(executable: "/bin/false"))))
        let agent = TerminalWallpaperAgentDelegate(configurationURL: store.configURL,
            managesLockScreenPresentation: false, screensProvider: { [] })
        agent.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        defer { agent.applicationWillTerminate(.init(name: NSApplication.willTerminateNotification)) }
        try await Task.sleep(for: .milliseconds(2300))
        let health = try #require(store.loadHealth())
        #expect(health.childRunning && health.frames > 2)
        #expect(health.screens == 0)
        #expect(health.lastError == nil)
        #expect(store.loadConfig() == config)
    }

    @Test func terminalLoginHelperIsCopiedToAStableLocationOutsideTheOriginalApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraLoginHelper-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Downloads/AuraFlow.app/Contents/Helpers/AuraTerminalWallpaperAgent.app")
        let binary = bundle.appendingPathComponent("Contents/MacOS/AuraTerminalWallpaperAgent")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let installed = try NativeTerminalWallpaperController.installLoginHelperBundle(from: bundle,
            runtimeDirectory: root.appendingPathComponent("Runtime"))
        try Data("#!/bin/sh\n# updated helper\nexit 0\n".utf8).write(to: binary)
        let replacement = try NativeTerminalWallpaperController.installLoginHelperBundle(from: bundle,
            runtimeDirectory: root.appendingPathComponent("Runtime"))
        #expect(replacement == installed)
        #expect(try String(contentsOf: replacement).contains("updated helper"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Downloads"))
        #expect(FileManager.default.isExecutableFile(atPath: installed.path))
        #expect(try String(contentsOf: installed).contains("exit 0"))
    }

    @Test func terminalHelperUpdateRecognizesTheOldProcessAfterItsExecutableWasReplaced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraUnlinkedHelper-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("AuraTerminalWallpaperAgent")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal-wallpaper"),
            launchAgentURL: root.appendingPathComponent("unused.plist"))
        let process = Process()
        process.executableURL = executable
        process.arguments = ["60"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        try store.savePID(process.processIdentifier)
        try store.saveHealth(.init(agentPID: Int(process.processIdentifier),
            executableFingerprint: RuntimeExecutableFingerprint.digest(at: executable)))
        #expect(!NativeTerminalWallpaperController.helperNeedsReplacement(in: store, expectedExecutable: executable))

        let replacement = root.appendingPathComponent("updated-helper")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: replacement.path)
        _ = try FileManager.default.replaceItemAt(executable, withItemAt: replacement)

        #expect(process.isRunning && store.processIsAlive(pid: Int(process.processIdentifier)))
        #expect(NativeTerminalWallpaperController.helperNeedsReplacement(in: store, expectedExecutable: executable))
    }
}

private struct LoginTestLockCoordinator: TerminalLockScreenCoordinating {
    func activate() throws {}
    func restore() throws {}
}

@Test(arguments: [false, true])
func applyingTerminalInheritsApplicationLoginPreferenceAndToggleKeepsTheRuntimeAlive(enabled: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraAppliedLogin-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let video = WallpaperRuntimeStore(appSupportURL: root,
        launchAgentURL: root.appendingPathComponent("LaunchAgents/com.andrijvergeles.auraflow.plist"))
    try video.saveConfig(.init(video_path: "", playback_speed: 1, autostart: enabled,
        show_on_lock_screen: false, login_wallpaper_runtime: .video))
    let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal-wallpaper"),
        launchAgentURL: root.appendingPathComponent("LaunchAgents/com.andrijvergeles.auraflow.terminal-wallpaper.plist"))
    let helper = root.appendingPathComponent("fixture-helper")
    try Data("#!/bin/sh\ntrap 'exit 0' TERM\nwhile :; do sleep 0.05; done\n".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    let controller = try NativeTerminalWallpaperController(store: store, helperURL: helper,
        videoRuntimeIsRunning: { false }, lockScreenVideoIsActive: { false }, lockScreenCoordinator: LoginTestLockCoordinator())
    defer { _ = store.terminateAgent(timeout: 1) }
    let config = TerminalWallpaperConfig(command: .init(executable: "/bin/echo", arguments: ["chosen"]),
        render: .init(columns: 40, rows: 10), behavior: .init(launchAtLogin: !enabled))
    let status = try controller.start(config: config)
    let pid = try #require(status.pid)
    #expect(status.running && store.loadConfig().behavior.launchAtLogin == enabled)
    #expect(video.loadConfig().login_wallpaper_runtime == .terminal)
    #expect(store.launchAgentEnabled() == enabled)
    _ = try controller.setLaunchAtLogin(!enabled, config: config)
    #expect(try controller.status().pid == pid)
    #expect(video.loadConfig().autostart == !enabled)
    #expect(store.loadConfig().command == config.command)
    #expect(!video.launchAgentPlistExists())
    _ = try controller.stop()
    #expect(video.loadConfig().login_wallpaper_runtime == .removed)
    #expect(!store.launchAgentEnabled())
}
