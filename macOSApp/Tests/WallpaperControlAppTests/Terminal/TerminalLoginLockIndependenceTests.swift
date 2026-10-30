import AppKit
import AuraTerminalWallpaperCore
import AuraWallpaperCore
import Testing
@testable import AuraTerminalWallpaperAgent
@testable import WallpaperControlApp

private final class RecordingLoginLockCoordinator: TerminalLockScreenCoordinating, @unchecked Sendable {
    var activations = 0
    var restorations = 0
    func activate() throws { activations += 1 }
    func restore() throws { restorations += 1 }
    func restoreUserWallpaper() throws { restorations += 1 }
}

@Suite(.serialized)
struct TerminalLoginLockIndependenceTests {
    @Test(arguments: [false, true]) @MainActor
    func loginPreferenceLeavesTheRunningLockScreenPublicationUntouched(initialLogin: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraLoginLock-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = WallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("LaunchAgents/video.plist"))
        try app.saveConfig(.init(video_path: "", playback_speed: 1, autostart: initialLogin,
            show_on_lock_screen: true, login_wallpaper_runtime: .terminal))
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal-wallpaper"),
            launchAgentURL: root.appendingPathComponent("LaunchAgents/terminal.plist"))
        let config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh", arguments: ["-c",
            "n=0; while :; do printf '\\033[Hframe %s' \"$n\"; n=$((n+1)); sleep 0.05; done"]),
            render: .init(columns: 20, rows: 4, maxFPS: 15),
            behavior: .init(launchAtLogin: initialLogin, pauseOnFullscreen: false))
        try store.saveConfig(config)
        var now: TimeInterval = 100
        let publisher = TerminalLockScreenFramePublisher(store: store, clock: { now })
        let agent = TerminalWallpaperAgentDelegate(configurationURL: store.configURL, managesLockScreenPresentation: false,
            screensProvider: { [] }, framePublisher: publisher)
        agent.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        defer { agent.applicationWillTerminate(.init(name: NSApplication.willTerminateNotification)) }
        let health = try #require(store.loadHealth())
        let child = try #require(health.childPID)
        let pixels = Data(repeating: 255, count: 16)
        for _ in 0..<4 {
            now += 1
            publisher.publishDesktopSeed(pixels, width: 2, height: 2)
            let deadline = Date().addingTimeInterval(3)
            while publisher.isWritingFrame {
                try #require(Date() < deadline)
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try #require(!publisher.needsDesktopSeed)
        let frame = try Data(contentsOf: store.lockScreenFrameURL)
        let coordinator = RecordingLoginLockCoordinator()
        let controller = try NativeTerminalWallpaperController(store: store, helperURL: URL(fileURLWithPath: "/usr/bin/true"),
            videoRuntimeIsRunning: { false }, lockScreenVideoIsActive: { false }, lockScreenCoordinator: coordinator,
            lockScreenFrameReadinessWaiter: { _, _ in true })
        for enabled in [!initialLogin, initialLogin] {
            let command = store.loadCommand()
            _ = try controller.setLaunchAtLogin(enabled, config: config)
            try await Task.sleep(for: .milliseconds(650))
            #expect(store.loadCommand() == command, "Login registration must not send a playback command")
            #expect(!publisher.needsDesktopSeed, "Login registration must not invalidate the prepared Lock Screen frame")
            #expect(try Data(contentsOf: store.lockScreenFrameURL) == frame)
            #expect(store.lockScreenPlaybackEnabled && app.loadConfig().show_on_lock_screen == true)
            #expect(store.loadHealth()?.childPID == child && store.loadHealth()?.childRunning == true)
            #expect(coordinator.activations == 0 && coordinator.restorations == 0)
        }
        // Compatibility Update commands containing only the login flag are
        // also ordinary metadata, never an instruction to reseed the saver.
        var metadata = config
        metadata.behavior.launchAtLogin.toggle()
        try store.saveCommand(.init(action: .update, config: metadata))
        try await Task.sleep(for: .milliseconds(650))
        #expect(!publisher.needsDesktopSeed)
        // Only the actual Lock Screen checkbox can revoke/prepare this lease.
        var shared = app.loadConfig()
        shared.show_on_lock_screen = false
        try app.saveConfig(shared)
        try controller.setShowOnLockScreen(false)
        #expect(store.loadCommand()?.action == .syncLockScreen && store.loadCommand()?.config == nil)
        try await Task.sleep(for: .milliseconds(650))
        #expect(store.loadLockScreenHeartbeat() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.lockScreenFrameURL.path))
        #expect(coordinator.restorations == 1)
        shared.show_on_lock_screen = true
        try app.saveConfig(shared)
        try controller.setShowOnLockScreen(true)
        #expect(store.loadCommand()?.action == .syncLockScreen && store.loadCommand()?.config == nil)
        try await Task.sleep(for: .milliseconds(650))
        #expect(publisher.needsDesktopSeed && coordinator.activations == 1)
        #expect(store.loadHealth()?.childPID == child && store.loadHealth()?.childRunning == true)
    }
}
