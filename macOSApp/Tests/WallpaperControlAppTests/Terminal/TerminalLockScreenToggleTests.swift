import AppKit
import AuraTerminalWallpaperCore
import AuraWallpaperCore
import IOSurface
import Testing
@testable import AuraTerminalWallpaperAgent
@testable import WallpaperControlApp

private final class ToggleLockCoordinator: TerminalLockScreenCoordinating, @unchecked Sendable {
    var activations = 0
    var restorations = 0
    func activate() { activations += 1 }
    func restore() { restorations += 1 }
}

@Suite(.serialized)
struct TerminalLockScreenToggleTests {
    @Test(arguments: [false, true]) @MainActor
    func offOnReusesTheReadyLiveSurfaceWithoutWaitingForAnotherPNG(loginEnabled: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraLockToggle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = WallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("login.plist"))
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal-wallpaper"),
            launchAgentURL: root.appendingPathComponent("terminal-login.plist"))
        try app.saveConfig(.init(video_path: "", playback_speed: 1, autostart: loginEnabled, show_on_lock_screen: true))
        try store.savePID(getpid())
        try store.saveHealth(.init(available: true, running: true, agentPID: Int(getpid())))
        let surface = try #require(IOSurfaceCreate([kIOSurfaceWidth: 2, kIOSurfaceHeight: 2,
            kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: 8] as CFDictionary))
        let descriptor = TerminalSharedFrameDescriptor(surfaceID: IOSurfaceGetID(surface), width: 2, height: 2,
            agentPID: Int(getpid()), generation: UUID().uuidString)
        try store.saveSharedFrameDescriptor(descriptor)
        let coordinator = ToggleLockCoordinator()
        var waits = 0
        let controller = try NativeTerminalWallpaperController(store: store, helperURL: URL(fileURLWithPath: "/usr/bin/true"),
            lockScreenCoordinator: coordinator, lockScreenFrameReadinessWaiter: { _, _ in waits += 1; return false })
        for _ in 0..<3 {
            var config = app.loadConfig()
            config.show_on_lock_screen = false
            try app.saveConfig(config)
            try controller.setShowOnLockScreen(false)
            #expect(!store.lockScreenPlaybackEnabled)
            #expect(store.loadLockScreenHeartbeat() == nil)
            config.show_on_lock_screen = true
            try app.saveConfig(config)
            try controller.setShowOnLockScreen(true)
            #expect(store.loadLockScreenHeartbeat()?.pid == Int(getpid()))
            #expect(store.loadCommand()?.action == .update, "A running helper from the previous version must understand the toggle")
            #expect(store.loadCommand()?.config == nil, "The switch must not reapply a Terminal preset")
            #expect(store.loadSharedFrameDescriptor() == descriptor)
            #expect(app.loadConfig().autostart == loginEnabled)
            #expect(store.loadPID() == Int(getpid()))
        }
        #expect(waits == 0, "An already-rendered IOSurface must be immediately usable without PNG compression")
        #expect(coordinator.activations == 3 && coordinator.restorations == 3)
        withExtendedLifetime(surface) {}
    }

    @Test @MainActor
    func offDuringLockResetsCaptureSoOnCanImmediatelySeedTheDesktopAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraLockToggleSeed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root)
        let publisher = TerminalLockScreenFramePublisher(store: store)
        let pixel = Data([0, 0, 255, 255])
        publisher.setLockScreenActive(true)
        publisher.publish(pixel, width: 1, height: 1)
        let deadline = Date().addingTimeInterval(2)
        while publisher.isWritingFrame {
            try #require(Date() < deadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        publisher.revoke()
        #expect(store.loadLockScreenHeartbeat() == nil)
        publisher.beginDesktopGeneration()
        #expect(publisher.needsDesktopSeed, "OFF must release the former locked capture mode")
        publisher.publishDesktopSeed(pixel, width: 1, height: 1)
        let enabledDeadline = Date().addingTimeInterval(2)
        while publisher.isWritingFrame {
            try #require(Date() < enabledDeadline)
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.loadLockScreenHeartbeat()?.pid == Int(getpid()))
        #expect(FileManager.default.fileExists(atPath: store.lockScreenFrameURL.path))
        publisher.revoke()
    }

    @Test(arguments: ["owner", "surface", "dimensions", "failed-output"]) @MainActor
    func anInvalidSharedSourceStillRequiresAReadyFrame(invalid: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraInvalidLockSource-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal-wallpaper"))
        try store.savePID(getpid())
        try store.saveHealth(.init(available: true, running: true,
            lastError: invalid == "failed-output" ? "The command failed" : nil, agentPID: Int(getpid())))
        let surface = try #require(IOSurfaceCreate([kIOSurfaceWidth: 2, kIOSurfaceHeight: 2,
            kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: 8] as CFDictionary))
        try store.saveSharedFrameDescriptor(.init(surfaceID: invalid == "surface" ? 0 : IOSurfaceGetID(surface),
            width: invalid == "dimensions" ? 3 : 2, height: 2,
            agentPID: invalid == "owner" ? Int(getpid()) + 1 : Int(getpid())))
        let coordinator = ToggleLockCoordinator()
        var waits = 0
        let controller = try NativeTerminalWallpaperController(store: store, helperURL: URL(fileURLWithPath: "/usr/bin/true"),
            lockScreenCoordinator: coordinator, lockScreenFrameReadinessWaiter: { _, _ in waits += 1; return false })
        #expect(throws: TerminalWallpaperControllerError.lockScreenFrameNotReady) { try controller.setShowOnLockScreen(true) }
        #expect(waits == 1 && coordinator.activations == 0)
        #expect(store.loadLockScreenHeartbeat() == nil)
        withExtendedLifetime(surface) {}
    }
}
