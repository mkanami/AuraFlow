import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import AuraWallpaperCore
@testable import AuraWallpaperAgent
@testable import WallpaperControlApp

private func musicWindow(_ bounds: CGRect, pid: Int = 42, layer: Int = 0, alpha: Double = 1, onscreen: Bool = true) -> [String: Any] {
    [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
     kCGWindowIsOnscreen as String: onscreen, kCGWindowBounds as String: [
        "X": bounds.minX, "Y": bounds.minY, "Width": bounds.width, "Height": bounds.height]]
}

@Test func desktopMusicStopsForSmallWindowsAndFloatingPanelsOnEitherDisplay() {
    let displays = [CGRect(x: 0, y: 0, width: 1400, height: 900), CGRect(x: -1100, y: -300, width: 1100, height: 800)]
    for frame in [CGRect(x: 100, y: 100, width: 400, height: 300), CGRect(x: -900, y: -100, width: 500, height: 350)] {
        for layer in [0, 3, Int(CGWindowLevelForKey(.modalPanelWindow))] {
            let count = DesktopApplicationWindows.visibleCount(applicationPIDs: [42],
                windowInfo: [musicWindow(frame, layer: layer)], displays: displays)
            #expect(count == 1)
            #expect(DesktopApplicationWindows.State(count: count, fullscreen: false).blocksMusic)
        }
    }
    #expect(!DesktopApplicationWindows.State(count: 0, fullscreen: false).blocksMusic)
    #expect(DesktopApplicationWindows.State.unknown.blocksMusic)
}

@Test func desktopMusicIgnoresMinimizedHiddenOtherSpaceDesktopAndTooltipWindows() {
    let display = CGRect(x: 0, y: 0, width: 1400, height: 900)
    let normal = CGRect(x: 100, y: 100, width: 500, height: 300)
    let info = [musicWindow(normal, onscreen: false), musicWindow(normal, alpha: 0),
        musicWindow(normal, pid: 99), musicWindow(normal, layer: -1000), musicWindow(normal, layer: 103),
        musicWindow(CGRect(x: 2000, y: 2000, width: 500, height: 300)),
        musicWindow(CGRect(x: 1392, y: 100, width: 500, height: 300)), musicWindow(.zero)]
    #expect(DesktopApplicationWindows.visibleCount(applicationPIDs: [42], windowInfo: info, displays: [display]) == 0)
}

@Test(arguments: ["normal-window", "manual-lock", "os-lock", "idle-saver", "missing-lock-notification", "sleep", "manual-stop", "lock-only"])
func desktopMusicPolicyRetainsSilenceForEveryHiddenDesktopState(state: String) {
    let volume = WallpaperAudioPolicy.desktopVolume(0.5, lockScreenOnly: state == "lock-only",
        sessionInactive: state == "manual-lock", systemLocked: state == "os-lock" || state == "missing-lock-notification",
        sleeping: state == "sleep", screenSaverActive: state == "idle-saver", paused: state == "manual-stop",
        desktopObstructed: state == "normal-window")
    #expect(volume == 0)
    #expect(WallpaperAudioPolicy.desktopVolume(0.5, lockScreenOnly: false, sessionInactive: false,
        systemLocked: false, sleeping: false, desktopObstructed: false) == 0.5)
}

@Test @MainActor func desktopMusicCompositionContainsAudioWithoutASecondVideoDecoder() async throws {
    let source = try #require(Bundle.module.url(forResource: "wallpaper-with-audio", withExtension: "mp4"))
    let composition = try #require(try await WallpaperAudioPlayback.audioComposition(for: source))
    #expect(try await composition.loadTracks(withMediaType: .audio).count == 1)
    #expect(try await composition.loadTracks(withMediaType: .video).isEmpty)
    let silentVideo = try #require(Bundle.module.url(forResource: "wallpaper-without-audio", withExtension: "mp4"))
    #expect(try await WallpaperAudioPlayback.audioComposition(for: silentVideo) == nil)
}

@Test(arguments: [false, true]) @MainActor func desktopMusicRealPlayerPausesAndResumesTheSamePositionWithoutReloading(paired: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("silent-clock.wav")
    // Exercise the real audio clock without emitting test tones on the user's Mac.
    try silentMusicClock().write(to: url)
    let music = WallpaperAudioPlayback()
    defer { music.stop() }
    let source: URL
    if paired {
        source = root.appendingPathComponent("silent-video.mp4")
        try Data("video source is independent of the music clock".utf8).write(to: source)
        try WallpaperAudioAttachment.install(url, for: source)
    } else { source = url }
    music.setSource(source)
    #expect(!music.isPrepared, "Muted wallpapers must not create an extra decoder")
    music.update(volume: 0.3)
    try await waitForMusic { (music.time ?? 0) > 0.15 }
    #expect(music.errorDescription == nil)
    music.update(volume: 0)
    try await Task.sleep(for: .milliseconds(80))
    let pausedAt = try #require(music.time)
    try await Task.sleep(for: .milliseconds(250))
    #expect(abs((music.time ?? 0) - pausedAt) < 0.025)
    #expect(music.rate == 0)
    music.setSource(source) // Video refreshes/quality changes keep the original source.
    #expect(abs((music.time ?? 0) - pausedAt) < 0.025)
    music.update(volume: 0.6)
    try await waitForMusic { (music.time ?? 0) > pausedAt + 0.15 }
    #expect(music.time! < pausedAt + 1)
    music.stop()
    #expect(!music.isPrepared && music.time == nil)
}

@Test(arguments: [WallpaperLoginRuntime.removed, .terminal, .video], [(false, false), (false, true), (true, false), (true, true)]) @MainActor
func desktopMusicLoginWarningRespectsAppliedEngineWithoutChangingPreferences(runtime: WallpaperLoginRuntime, preferences: (Bool, Bool)) async {
    let (login, lock) = preferences
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = MockNativeWallpaperController()
    controller.statusConfigAutostart = login
    controller.statusAutostart = login
    controller.statusShowOnLockScreen = lock
    controller.statusLoginRuntime = runtime
    controller.statusAutostartPlistExists = false
    let app = AppViewModel(controller: controller, appSupportDirectoryURL: root)
    await app.loadStatus()
    #expect((app.alertMessage?.contains("LaunchAgent plist is missing") == true) == (login && runtime == .video))
    #expect(controller.statusConfigAutostart == login)
    #expect(controller.statusShowOnLockScreen == lock)
    #expect(controller.startCallCount == 0 && controller.stopCallCount == 0 && controller.lockCallCount == 0)
}

@MainActor private func waitForMusic(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !predicate() {
        try #require(Date() < deadline, "Audio playback clock did not advance")
        try await Task.sleep(for: .milliseconds(20))
    }
}

@Test @MainActor func desktopMusicAgentPausesForWindowsAndSleepWithoutRewindingOnVideoReload() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraMusicAgent-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("login.plist"),
        launchctlRunner: { _ in LaunchctlResult(succeeded: false, output: "not loaded") })
    try store.ensureDirectories()
    let url = try await silentMusicMovie(in: root)
    let config = ControlConfig(video_path: url.path, playback_speed: 1, volume: 0.5, autostart: false,
        pause_on_fullscreen: false, show_on_lock_screen: false)
    try store.saveConfig(config)
    var windowCount = 1
    var locked = false
    let agent = WallpaperAgentDelegate(store: store, lockScreenPlatform: UnsupportedAdapter(),
        presentWindow: { _, _ in }, observesSystemEvents: false, sessionIsLocked: { locked },
        applicationWindows: { .init(count: windowCount, fullscreen: false) })
    defer { agent.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
    agent.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    func refresh(_ action: WallpaperRuntimeCommandAction = .updateVolume) throws {
        try store.saveCommand(.init(action: action, config: config))
        agent.pollCommand()
    }
    func health() -> DaemonHealth? {
        agent.samplePlaybackHealth()
        return store.loadHealth()
    }
    try refresh()
    #expect(health()?.audio_prepared == false)
    windowCount = 0
    try refresh()
    try await waitForMusic { (health()?.audio_time ?? 0) > 0.15 }
    #expect(agent.player?.volume == 0 && agent.player?.isMuted == true)
    windowCount = 1
    try refresh()
    try await Task.sleep(for: .milliseconds(80))
    let pausedAt = try #require(health()?.audio_time)
    try await Task.sleep(for: .milliseconds(200))
    #expect(abs((health()?.audio_time ?? 0) - pausedAt) < 0.025)
    #expect(health()?.audio_rate == 0 && health()?.audio_paused_for_windows == true)
    #expect((agent.player?.rate ?? 0) > 0, "A small window must pause music independently of video")
    let video = agent.player
    try refresh(.reload)
    #expect(agent.player !== video)
    #expect(abs((health()?.audio_time ?? 0) - pausedAt) < 0.025)
    windowCount = 0
    try refresh()
    try await waitForMusic { (health()?.audio_time ?? 0) > pausedAt + 0.15 }
    for callback in ["screensWillSleep", "systemWillSleep"] {
        _ = agent.perform(NSSelectorFromString(callback))
        #expect(health()?.audio_rate == 0)
        _ = agent.perform(NSSelectorFromString("systemDidWake"))
        try await waitForMusic { health()?.audio_rate == 1 }
    }
    // A missing lock notification still mutes via the authoritative session query.
    locked = true
    try refresh()
    #expect(health()?.audio_rate == 0)
    locked = false
    agent.reconcileSystemSessionState()
    try refresh()
    try await waitForMusic { health()?.audio_rate == 1 }
    #expect(agent.windows.allSatisfy { !$0.isVisible }, "Never order a test window on the active Desktop")
}

@MainActor func silentMusicMovie(in root: URL) async throws -> URL {
    let wav = root.appendingPathComponent("silent-clock.wav")
    try silentMusicClock().write(to: wav)
    let composition = try #require(try await WallpaperAudioPlayback.audioComposition(for: wav))
    let videoURL = try #require(Bundle.module.url(forResource: "wallpaper-without-audio", withExtension: "mp4"))
    let videoAsset = AVURLAsset(url: videoURL)
    let track = try #require(try await videoAsset.loadTracks(withMediaType: .video).first)
    let video = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
    try video.insertTimeRange(try await track.load(.timeRange), of: track, at: .zero)
    let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
    let url = root.appendingPathComponent("silent-wallpaper.mov")
    exporter.outputURL = url
    exporter.outputFileType = .mov
    await exporter.export()
    try #require(exporter.status == .completed)
    return url
}

func silentMusicClock() -> Data {
    let samples = 12 * 16_000, bytes = samples * 2
    var data = Data("RIFF".utf8)
    func append<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    append(UInt32(bytes + 36)); data.append(Data("WAVEfmt ".utf8))
    append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
    append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
    data.append(Data("data".utf8)); append(UInt32(bytes)); data.append(Data(repeating: 0, count: bytes))
    return data
}
