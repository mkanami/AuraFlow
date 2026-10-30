import AppKit
import AuraTerminalWallpaperCore
import AuraWallpaperCore
import Testing
@testable import AuraTerminalWallpaperAgent
@testable import WallpaperControlApp

@MainActor private func awaitTerminalFullscreen(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        try #require(Date() < deadline)
        try await Task.sleep(for: .milliseconds(20))
    }
}

private func terminalChildIsStopped(_ pid: Int) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "state=", "-p", String(pid)]
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { return false }
    process.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("T")
}

@Suite(.serialized)
struct TerminalFullscreenRuntimeTests {
    @Test @MainActor
    func fullscreenSettingPausesAndResumesTheSameRealPTYWithoutReapplyingWallpaper() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraFullscreen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = WallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("login.plist"))
        try app.saveConfig(.init(video_path: "", playback_speed: 1, autostart: false, show_on_lock_screen: true))
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal-wallpaper"),
            launchAgentURL: root.appendingPathComponent("terminal-login.plist"))
        let config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh", arguments: ["-c",
            "printf x >> launches; n=0; while :; do printf '\\033[Hframe %s' \"$n\"; n=$((n+1)); sleep 0.05; done"], workingDirectory: root.path),
            render: .init(columns: 20, rows: 4, maxFPS: 15), behavior: .init(pauseOnFullscreen: false))
        try store.saveConfig(config)
        var fullscreen = true
        var now: TimeInterval = 100
        let publisher = TerminalLockScreenFramePublisher(store: store, clock: { now })
        let agent = TerminalWallpaperAgentDelegate(configurationURL: store.configURL, managesLockScreenPresentation: false,
            screensProvider: { [] }, framePublisher: publisher, fullscreenApplicationIsActive: { fullscreen })
        agent.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        defer { agent.applicationWillTerminate(.init(name: NSApplication.willTerminateNotification)) }
        let child = try #require(store.loadHealth()?.childPID)
        for _ in 0..<4 {
            now += 1
            publisher.publishDesktopSeed(Data([0, 0, 255, 255]), width: 1, height: 1)
            try await awaitTerminalFullscreen { !publisher.isWritingFrame }
        }
        try #require(!publisher.needsDesktopSeed)
        let frame = try Data(contentsOf: store.lockScreenFrameURL)
        let controller = try NativeTerminalWallpaperController(store: store, helperURL: URL(fileURLWithPath: "/usr/bin/true"))
        let draft = TerminalWallpaperConfig(command: .init(executable: "/different/preview"), render: .init(fontSize: 42))
        _ = try controller.setPauseOnFullscreen(true, config: draft)
        try await awaitTerminalFullscreen { terminalChildIsStopped(child) }
        #expect(!store.isPlaybackPaused, "Automatic pause must not become an explicit Stop")
        _ = try controller.setPauseOnFullscreen(false, config: draft)
        try await awaitTerminalFullscreen { !terminalChildIsStopped(child) }
        let previousFrames = store.loadHealth()?.frames ?? 0
        try await awaitTerminalFullscreen { (store.loadHealth()?.frames ?? 0) > previousFrames }
        _ = try controller.setPauseOnFullscreen(true, config: draft)
        try await awaitTerminalFullscreen { terminalChildIsStopped(child) }
        fullscreen = false
        try await awaitTerminalFullscreen { !terminalChildIsStopped(child) }
        _ = try controller.setPlaybackPaused(true)
        try await awaitTerminalFullscreen { terminalChildIsStopped(child) }
        _ = try controller.setPauseOnFullscreen(false, config: draft)
        try await Task.sleep(for: .milliseconds(650))
        #expect(store.isPlaybackPaused && terminalChildIsStopped(child), "Disabling auto-pause must preserve the user's explicit Stop")
        _ = try controller.setPlaybackPaused(false)
        try await awaitTerminalFullscreen { !terminalChildIsStopped(child) }
        #expect(store.loadHealth()?.childPID == child)
        #expect(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8) == "x")
        #expect(store.loadConfig() == config)
        #expect(!publisher.needsDesktopSeed)
        #expect(try Data(contentsOf: store.lockScreenFrameURL) == frame)
        #expect(app.loadConfig().show_on_lock_screen == true && app.loadConfig().autostart == false)
        #expect(!store.launchAgentEnabled())
    }
}
