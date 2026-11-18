import AppKit
import AVFoundation
import Combine
import SwiftUI
import Testing
@testable import AuraWallpaperCore
@testable import WallpaperControlApp

@Test @MainActor func previewRenderingGateCoalescesWindowDragUpdates() {
    let gate = PreviewRenderingActivity()
    var changes: [Bool] = []
    let subscription = gate.changes.sink { changes.append($0) }
    defer { subscription.cancel() }
    for _ in 0..<1_000 { gate.set(.windowDrag, active: true) }
    #expect(gate.isSuspended && changes == [true])
    for _ in 0..<1_000 { gate.set(.windowDrag, active: false) }
    #expect(!gate.isSuspended && changes == [true, false])
}

@Test @MainActor func previewScrollingKeepsVideoMusicAndEffectsMoving() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try await silentMusicMovie(in: root)
    let controller = MockNativeWallpaperController()
    let audio = WallpaperPreviewAudioPlayback(systemAllowsPlayback: { true },
        applicationIsActive: { true }, automaticallyMonitor: false)
    defer { audio.stop() }
    let model = AppViewModel(controller: controller, appSupportDirectoryURL: root, previewAudioPlayback: audio)
    _ = model.stageCatalogWallpaperForPreview(CatalogWallpaper(id: "scroll-live", title: "Scroll live",
        category: "Anime", attribution: "fixture", previewImageURL: nil, sourcePageURL: nil,
        sources: [], hasMusic: true), localURL: source)
    model.setPreviewWindowVisible(true)
    model.updateVolume(0.4, immediately: true)
    let player = try #require(model.previewPlayer)
    let deadline = Date().addingTimeInterval(5)
    while (audio.playback.time ?? 0) < 0.1 || player.currentTime().seconds < 0.1 {
        try #require(Date() < deadline)
        try await Task.sleep(for: .milliseconds(20))
    }

    let window = ScrollPreviewTestWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: window.contentView!.bounds)
    window.contentView = scroll
    let coordinator = WindowAccessor.Coordinator()
    coordinator.attachIfNeeded(window, onInteractionStart: model.suspendPreviewRenderingForWindowDrag,
        onInteractionEnd: model.resumePreviewRenderingAfterWindowDrag)
    defer { coordinator.detach(); window.contentView = nil }

    let effects = WallpaperEffectsView(content: NSView(frame: scroll.bounds), store: nil, isPreview: true)
    effects.update(settings: WallpaperEffectsPreset.cinematic.settings)
    let effectsCoordinator = WallpaperEffectsPreview<EmptyView>.Coordinator()
    effectsCoordinator.attach(effects, activity: model.previewRenderingActivity)
    effects.applyActivity(WallpaperEffectsActivity())
    let beforeFrames = effects.status.renderedFrames
    let beforeVideo = player.currentTime().seconds, beforeAudio = audio.playback.time ?? 0
    let center = NotificationCenter.default
    center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    for _ in 0..<30 {
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        effects.renderFrame(deltaTime: 1.0/60, cursor: .zero)
        try await Task.sleep(for: .milliseconds(10))
    }
    center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    #expect(!model.previewRenderingActivity.isSuspended && player.rate > 0)
    #expect(player.currentTime().seconds > beforeVideo)
    #expect((audio.playback.time ?? 0) > beforeAudio)
    #expect(effects.isAnimating && effects.status.renderedFrames > beforeFrames)
    #expect(!window.isVisible && controller.startCallCount == 0 && controller.lockCallCount == 0)
}

@MainActor private final class ScrollPreviewTestWindow: NSWindow {
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        if place != .out { Issue.record("Never order a test window on the active Desktop") }
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        Issue.record("Never activate a test window on the active Desktop")
    }
}
