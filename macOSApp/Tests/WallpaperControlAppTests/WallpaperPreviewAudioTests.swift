import AVFoundation
import AppKit
import Foundation
import Testing
@testable import AuraWallpaperCore
@testable import WallpaperControlApp

@Test(arguments: [false, true]) @MainActor
func previewMusicPlaysEmbeddedAndCompanionTracksAndPausesItsClock(paired: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try await previewMusicSource(in: root, paired: paired)
    let audio = WallpaperPreviewAudioPlayback(systemAllowsPlayback: { true }, applicationIsActive: { true }, automaticallyMonitor: false)
    defer { audio.stop() }
    audio.setSource(source)
    #expect(!audio.playback.isPrepared)
    audio.update(volume: 0.4, visible: true)
    try await waitForPreviewMusic { (audio.playback.time ?? 0) > 0.15 }
    #expect(audio.playback.errorDescription == nil)
    audio.update(volume: 0.4, visible: false)
    try await Task.sleep(for: .milliseconds(80))
    let pausedAt = try #require(audio.playback.time)
    try await Task.sleep(for: .milliseconds(200))
    #expect(audio.playback.rate == 0)
    #expect(abs((audio.playback.time ?? 0) - pausedAt) < 0.025)
    audio.setSource(source)
    audio.update(volume: 0.4, visible: true)
    try await waitForPreviewMusic { (audio.playback.time ?? 0) > pausedAt + 0.1 }
    audio.update(volume: 0, visible: true)
    #expect(audio.playback.rate == 0)
    audio.stop()
    #expect(!audio.playback.isPrepared)
}

@Test(arguments: ["manual-lock", "os-lock", "idle-saver", "missing-notification", "sleep-wake", "unknown-session"])
@MainActor func previewMusicWaitsForTheRealSessionAndDesktopOwnership(scenario: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("silent.wav")
    try silentMusicClock().write(to: source)
    var locked: Bool? = false
    var active = true, saver = false, awake = true
    var desktopPlaying = true
    let audio = WallpaperPreviewAudioPlayback(systemAllowsPlayback: {
        WallpaperPreviewAudioPlayback.sessionAllowsPlayback(locked: locked, active: active, saver: saver, displayAwake: awake)
    },
        desktopOwnsAudio: { desktopPlaying }, applicationIsActive: { true }, automaticallyMonitor: false)
    defer { audio.stop() }
    audio.setSource(source)
    audio.update(volume: 0.4, visible: true)
    #expect(!audio.playback.isPrepared, "Wait for the installed Desktop music to pause before playing the preview")
    desktopPlaying = false
    audio.refresh()
    try await waitForPreviewMusic { (audio.playback.time ?? 0) > 0.1 }
    // No notification is required: the sampled secure/saver/sleep state wins.
    switch scenario {
    case "manual-lock": locked = true; active = false
    case "os-lock", "missing-notification": locked = true
    case "idle-saver": saver = true
    case "sleep-wake": awake = false
    case "unknown-session": locked = nil
    default: Issue.record("Unknown scenario")
    }
    audio.refresh()
    try await Task.sleep(for: .milliseconds(80))
    let pausedAt = try #require(audio.playback.time)
    audio.setSource(source)
    audio.update(volume: 0.7, visible: true)
    try await Task.sleep(for: .milliseconds(120))
    #expect(audio.playback.rate == 0)
    #expect(abs((audio.playback.time ?? 0) - pausedAt) < 0.025)
    if scenario == "sleep-wake" {
        awake = true; locked = true
        audio.refresh()
        #expect(audio.playback.rate == 0, "Wake must not unmute a still-locked session")
    }
    locked = false; active = true; saver = false; awake = true
    audio.refresh()
    try await waitForPreviewMusic { (audio.playback.time ?? 0) > pausedAt + 0.1 }
}

@Test(arguments: [false, true]) @MainActor
func mainPreviewUsesTheVolumeControlForEmbeddedAndCompanionMusic(paired: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try await previewMusicSource(in: root, paired: paired)
    let audio = WallpaperPreviewAudioPlayback(systemAllowsPlayback: { true }, applicationIsActive: { true }, automaticallyMonitor: false)
    defer { audio.stop() }
    let controller = MockNativeWallpaperController()
    let model = AppViewModel(controller: controller, appSupportDirectoryURL: root, previewAudioPlayback: audio)
    model.setPreviewWindowVisible(false)
    let wallpaper = CatalogWallpaper(id: "preview-music", title: "Preview music", category: "Anime",
        attribution: "fixture", previewImageURL: nil, sourcePageURL: nil,
        sources: [CatalogVideoSource(url: source, width: 16, height: 16)], hasMusic: true)
    _ = model.stageCatalogWallpaperForPreview(wallpaper, localURL: source)
    model.updateVolume(0.4, immediately: true)
    #expect(audio.playback.rate == 0)
    model.setPreviewWindowVisible(true)
    try await waitForPreviewMusic { (audio.playback.time ?? 0) > 0.1 }
    #expect(model.previewPlayer?.isMuted == true && model.previewPlayer?.volume == 0,
        "The original video must not emit a second copy of its embedded audio")
    let beforeDrag = try #require(audio.playback.time)
    model.suspendPreviewRenderingForWindowDrag()
    try await waitForPreviewMusic { (audio.playback.time ?? 0) > beforeDrag + 0.1 }
    #expect(model.previewPlayer?.rate == 0, "Pausing video redraws while dragging must not interrupt music")
    model.resumePreviewRenderingAfterWindowDrag()
    model.updateVolume(0, immediately: true)
    #expect(audio.playback.rate == 0)
    model.updateVolume(0.6, immediately: true)
    try await waitForPreviewMusic { audio.playback.rate > 0 }
    model.setPreviewWindowVisible(false)
    #expect(audio.playback.rate == 0)
    #expect(controller.startCallCount == 0 && controller.lockCallCount == 0,
        "Listening in preview must never install or start Desktop/Lock Screen wallpaper")
}

@Test @MainActor func previewWithoutMusicDoesNotKeepADecoderOrPollingTimer() async throws {
    let source = try #require(Bundle.module.url(forResource: "wallpaper-without-audio", withExtension: "mp4"))
    let audio = WallpaperPreviewAudioPlayback(systemAllowsPlayback: { true }, applicationIsActive: { true })
    defer { audio.stop() }
    audio.setSource(source)
    audio.update(volume: 0.4, visible: true)
    try await waitForPreviewMusic { audio.playback.errorDescription != nil && !audio.isMonitoringSystem }
    #expect(!audio.playback.isPrepared && audio.playback.rate == 0)
}

@Test(arguments: [false, true], [false, true]) @MainActor
func previewMusicRequiresAppFocusAndResumesTheSameClock(paired: Bool, missingLossNotification: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try await previewMusicSource(in: root, paired: paired)
    let notifications = NotificationCenter()
    var active = false
    let audio = WallpaperPreviewAudioPlayback(systemAllowsPlayback: { true },
        applicationIsActive: { active }, applicationNotifications: notifications)
    defer { audio.stop() }
    audio.setSource(source)
    audio.update(volume: 0.4, visible: true)
    #expect(!audio.playback.isPrepared && !audio.isMonitoringSystem,
        "An unfocused visible preview must not start an audio decoder or polling timer")

    active = true
    notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    try await waitForPreviewMusic { (audio.playback.time ?? 0) > 0.15 }
    #expect(audio.isMonitoringSystem)
    active = false
    if missingLossNotification {
        try await waitForPreviewMusic { audio.playback.rate == 0 }
    } else {
        notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(audio.playback.rate == 0, "Focus loss must pause immediately, without waiting for the timer")
    }
    #expect(!audio.isMonitoringSystem)
    try await Task.sleep(for: .milliseconds(80))
    let pausedAt = try #require(audio.playback.time)
    audio.setSource(source)
    audio.update(volume: 0.7, visible: true)
    try await Task.sleep(for: .milliseconds(200))
    #expect(audio.playback.rate == 0)
    #expect(abs((audio.playback.time ?? 0) - pausedAt) < 0.025)

    active = true
    notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    try await waitForPreviewMusic { (audio.playback.time ?? 0) > pausedAt + 0.1 }
    audio.update(volume: 0.7, visible: false)
    active = false
    notifications.post(name: NSApplication.didResignActiveNotification, object: nil)
    active = true
    notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(audio.playback.rate == 0 && !audio.isMonitoringSystem,
        "Returning to AuraFlow must not unpause a hidden preview")
    audio.stop()
    notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(!audio.playback.isPrepared && !audio.isMonitoringSystem)
}

@MainActor private func previewMusicSource(in root: URL, paired: Bool) async throws -> URL {
    if !paired { return try await silentMusicMovie(in: root) }
    let source = root.appendingPathComponent("paired.mp4")
    let video = try #require(Bundle.module.url(forResource: "wallpaper-without-audio", withExtension: "mp4"))
    try FileManager.default.copyItem(at: video, to: source)
    let soundtrack = root.appendingPathComponent("soundtrack.wav")
    try silentMusicClock().write(to: soundtrack)
    try WallpaperAudioAttachment.install(soundtrack, for: source)
    return source
}

@MainActor private func waitForPreviewMusic(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !predicate() {
        try #require(Date() < deadline, "Preview audio playback did not advance")
        try await Task.sleep(for: .milliseconds(20))
    }
}
