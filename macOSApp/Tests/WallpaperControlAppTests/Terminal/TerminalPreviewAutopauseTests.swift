import AppKit
import AuraTerminalRendering
import AuraTerminalWallpaperCore
import AuraWallpaperCore
import IOSurface
import Metal
import Testing
@testable import AuraTerminalWallpaperAgent
@testable import WallpaperControlApp

private func previewChildIsStopped(_ pid: Int) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-o", "state=", "-p", String(pid)]
    let output = Pipe()
    task.standardOutput = output
    guard (try? task.run()) != nil else { return false }
    task.waitUntilExit()
    return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("T")
}

@MainActor private func awaitPreviewActivity(timeout: TimeInterval = 4, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        try #require(Date() < deadline, "Preview and Desktop pause must react independently")
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Suite(.serialized)
struct TerminalPreviewAutopauseTests {
    @Test @MainActor
    func visiblePreviewKeepsTheSameChildLiveWhileDesktopIsAutomaticallyPaused() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraPreviewPause-\(UUID())")
        let app = WallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("unused.plist"))
        try app.saveConfig(.init(video_path: "", playback_speed: 1, show_on_lock_screen: false))
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("terminal-wallpaper"),
            launchAgentURL: root.appendingPathComponent("terminal.plist"))
        let config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh", arguments: ["-c",
            "printf x >> starts; n=0; while :; do printf '\\033[Hframe %s' \"$n\"; printf x >> ticks; n=$((n+1)); sleep 0.05; done"],
            workingDirectory: root.path), render: .init(columns: 20, rows: 4, maxFPS: 15),
            behavior: .init(pauseOnFullscreen: true))
        try store.saveConfig(config)
        let agent = TerminalWallpaperAgentDelegate(configurationURL: store.configURL, managesLockScreenPresentation: false,
            screensProvider: { [] }, fullscreenApplicationIsActive: { true })
        agent.applicationDidFinishLaunching(.init(name: NSApplication.didFinishLaunchingNotification))
        let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
        var visible = true
        let preview = TerminalWallpaperPreviewModel(selectionStore: selection, runtimeStore: store,
            windowIsVisible: { visible })
        defer {
            selection.selectVideo()
            preview.previewVisibilityDidChange()
            agent.applicationWillTerminate(.init(name: NSApplication.willTerminateNotification))
            try? FileManager.default.removeItem(at: root)
        }
        let child = try #require(store.loadHealth()?.childPID)
        let surface = try #require(IOSurfaceCreate([kIOSurfaceWidth: 2, kIOSurfaceHeight: 2,
            kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: 8] as CFDictionary))
        let descriptor = TerminalSharedFrameDescriptor(surfaceID: IOSurfaceGetID(surface), width: 2, height: 2,
            agentPID: Int(getpid()))
        try store.saveSharedFrameDescriptor(descriptor)
        selection.selectTerminal(config)
        preview.previewVisibilityDidChange()
        try await awaitPreviewActivity { agent.fullscreenPausePolicy.isPaused }
        #expect(!previewChildIsStopped(child), "The source must keep producing frames for the visible preview")
        let ticks = root.appendingPathComponent("ticks")
        let count = try Data(contentsOf: ticks).count
        try await Task.sleep(for: .milliseconds(250))
        #expect(try Data(contentsOf: ticks).count > count)
        #expect(preview.sharedFrame == descriptor && preview.snapshot == nil)
        #expect(try String(contentsOf: root.appendingPathComponent("starts"), encoding: .utf8) == "x",
            "A shared preview must not start a second copy of the command")

        visible = false
        preview.previewVisibilityDidChange()
        try await awaitPreviewActivity(timeout: 0.75) { previewChildIsStopped(child) }
        let unrelated = TerminalPreviewActivityMessage(agentPID: Int(Int32.max), clientPID: Int(getpid()), isVisible: true)
        DistributedNotificationCenter.default().postNotificationName(
            TerminalWallpaperRuntimeNotifications.previewActivityDidChange, object: nil,
            userInfo: unrelated.userInfo, deliverImmediately: true)
        try await Task.sleep(for: .milliseconds(250))
        #expect(previewChildIsStopped(child), "A preview belonging to a different runtime cannot resume this producer")
        visible = true
        preview.previewVisibilityDidChange()
        try await awaitPreviewActivity(timeout: 0.75) { !previewChildIsStopped(child) }
        #expect(agent.fullscreenPausePolicy.isPaused, "Showing the preview must not unpause the Desktop")

        try store.setPlaybackPaused(true)
        // Stop's marker precedes IPC, which may be delayed or lost. Preview
        // demand must already respect it before a Pause command is received.
        try await awaitPreviewActivity { previewChildIsStopped(child) }
        preview.previewVisibilityDidChange()
        try await Task.sleep(for: .milliseconds(250))
        #expect(previewChildIsStopped(child) && store.isPlaybackPaused,
            "Preview demand must not override an explicit Stop")
        try store.saveCommand(.init(action: .pause, config: config))
        #expect(store.loadHealth()?.childPID == child)
        withExtendedLifetime(surface) {}
    }

    @Test @MainActor
    func previewFramesContinueOffscreenWithoutDesktopOrLockScreenPresentation() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240),
            logicalSize: CGSize(width: 320, height: 240), device: device)
        defer { view.setRendererPaused(true) }
        view.setDesktopPresentationPaused(true)
        #expect(view.window == nil)
        var sequence: UInt64 = 0
        view.onSharedFrame = { _, next in sequence = next }
        var parser = VTParser(columns: 20, rows: 4)
        let render = TerminalRenderConfiguration(pixelMode: .fixed, fixedWidth: 320, fixedHeight: 240,
            columns: 20, rows: 4)
        for frame in 0..<5 {
            let previous = sequence
            parser.feed(Data("\u{1b}[Hpreview frame \(frame)".utf8))
            view.update(snapshot: parser.grid.snapshot(), configuration: render)
            try await awaitPreviewActivity { sequence > previous }
        }
    }

    @Test func closedCrashedExpiredOrPreviousBootClientsCannotKeepTheProducerRunning() {
        var activity = TerminalPreviewActivity()
        activity.update(clientPID: 42, visible: true, at: 100)
        let visible = activity.hasVisibleClient(at: 101, processIsRunning: { _ in true })
        #expect(visible)
        activity.update(clientPID: 42, visible: false, at: 101)
        let closed = activity.hasVisibleClient(at: 101, processIsRunning: { _ in true })
        #expect(!closed)
        activity.update(clientPID: 42, visible: true, at: 101)
        let crashed = activity.hasVisibleClient(at: 101, processIsRunning: { _ in false })
        #expect(!crashed)
        activity.update(clientPID: 42, visible: true, at: 101)
        let expired = activity.hasVisibleClient(at: 104, processIsRunning: { _ in true })
        #expect(!expired)
        activity.update(clientPID: 42, visible: true, at: 100)
        let previousBoot = activity.hasVisibleClient(at: 1, processIsRunning: { _ in true })
        #expect(!previousBoot)
    }

    @Test @MainActor
    func onlyVisibleMatchingPreviewsAdvertiseDemandAndSelectionChangesReleaseIt() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraPreviewDemand-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("runtime"))
        let config = TerminalWallpaperConfig(command: .init(executable: "/usr/bin/true"))
        try store.saveConfig(config)
        try store.savePID()
        let surface = try #require(IOSurfaceCreate([kIOSurfaceWidth: 2, kIOSurfaceHeight: 2,
            kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: 8] as CFDictionary))
        try store.saveSharedFrameDescriptor(.init(surfaceID: IOSurfaceGetID(surface), width: 2, height: 2,
            agentPID: Int(getpid())))
        let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
        selection.selectTerminal(config)
        var visible = true
        var messages: [TerminalPreviewActivityMessage] = []
        let preview = TerminalWallpaperPreviewModel(selectionStore: selection, runtimeStore: store,
            windowIsVisible: { visible }, publishPreviewActivity: { messages.append($0) })
        #expect(messages.map(\.isVisible) == [true])
        preview.previewVisibilityDidChange()
        #expect(messages.count == 1, "Frame/visibility refreshes must not flood IPC")
        visible = false
        preview.previewVisibilityDidChange()
        visible = true
        preview.previewVisibilityDidChange()
        selection.selectVideo()
        preview.previewVisibilityDidChange()
        #expect(messages.map(\.isVisible) == [true, false, true, false])
        #expect(messages.allSatisfy { $0.agentPID == Int(getpid()) && $0.clientPID == Int(getpid()) })
        withExtendedLifetime(surface) {}
    }

    @Test func hidingOneClientDoesNotDiscardAnotherVisiblePreview() {
        var activity = TerminalPreviewActivity()
        activity.update(clientPID: 41, visible: true, at: 100)
        activity.update(clientPID: 42, visible: true, at: 100)
        activity.update(clientPID: 41, visible: false, at: 100.5)
        let visible = activity.hasVisibleClient(at: 101, processIsRunning: { _ in true })
        #expect(visible)
        #expect(TerminalPreviewActivityMessage(userInfo: ["agent_pid": Int.max, "client_pid": 42, "visible": true]) == nil)
        #expect(TerminalPreviewActivityMessage(userInfo: ["agent_pid": 41, "client_pid": -1, "visible": true]) == nil)
    }
}
