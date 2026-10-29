import AppKit
import AVFoundation
import AuraWallpaperCore
import QuartzCore
import Testing
@testable import AuraWallpaperAgent

@MainActor
private final class WallpaperSessionFixture {
    let root: URL
    let store: WallpaperRuntimeStore
    var locked = false
    var agent: WallpaperAgentDelegate?

    init() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraSessionRegression-\(UUID())")
        store = WallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("login.plist"))
        try store.ensureDirectories()
    }

    func start(stalePauseCommand: Bool = false) async throws -> WallpaperAgentDelegate {
        let movie = root.appendingPathComponent("animated.mp4")
        try await makeSessionRegressionMovie(movie)
        let config = ControlConfig(video_path: movie.path, playback_speed: 1, autostart: true,
            pause_on_fullscreen: false, show_on_lock_screen: true)
        try store.saveConfig(config)
        // Both files really survive a process/OS restart. The cached first
        // frame must not become the final presentation or replay an old Pause.
        _ = try store.ensureCurrentStillFrame(from: movie)
        if stalePauseCommand { try store.saveCommand(.init(operationID: 10, action: .pause, config: config)) }
        let agent = WallpaperAgentDelegate(store: store, lockScreenPlatform: UnsupportedAdapter(),
            observesSystemEvents: false, sessionIsLocked: { [weak self] in self?.locked })
        self.agent = agent
        agent.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        agent.pollCommand()
        return agent
    }

    func cleanup() {
        agent?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        agent = nil
        try? FileManager.default.removeItem(at: root)
    }

    func setLocked(_ value: Bool) {
        locked = value
        agent?.handleSessionNotification(expectedLocked: value)
    }
}

@Suite(.serialized)
struct WallpaperSessionRegressionTests {
    @Test @MainActor
    func issue2LoginStartsDecodedAnimationInsteadOfLeavingCachedStillFrame() async throws {
        let fixture = try WallpaperSessionFixture()
        defer { fixture.cleanup() }
        let agent = try await fixture.start(stalePauseCommand: true)
        try await requireAdvancingWallpaper(agent)
        #expect(fixture.store.loadConfig().autostart == true)
        #expect(!fixture.store.isPaused())
        #expect(!agent.windows.isEmpty)
        #expect(agent.windows.allSatisfy { $0.isVisible })
    }

    @Test @MainActor
    func issue3UnlockResumesDecodedAnimationAfterSystemSuspendsDesktopPlayer() async throws {
        let fixture = try WallpaperSessionFixture()
        defer { fixture.cleanup() }
        let agent = try await fixture.start()
        try await requireAdvancingWallpaper(agent)
        let originalPlayer = try #require(agent.player)
        let originalLayers = agent.playerLayers
        for _ in 0..<5 {
            fixture.setLocked(true)
            // Model the observed system boundary: Desktop decoding can be
            // suspended while the separate secure provider owns the display.
            originalPlayer.pause()
            for _ in 0..<5 { agent.samplePlaybackHealth() }
            #expect(agent.player === originalPlayer)
            #expect(fixture.store.loadHealth()?.recovery_events == 0)
            fixture.setLocked(false)
            try await requireAdvancingWallpaper(agent)
            #expect(agent.player === originalPlayer)
            #expect(agent.playerLayers.elementsEqual(originalLayers, by: { $0 === $1 }))
            #expect(agent.windows.allSatisfy { $0.isVisible })
            #expect(fixture.store.loadHealth()?.presentation_mode == "desktop")
        }
    }
}

@MainActor
private func requireAdvancingWallpaper(_ agent: WallpaperAgentDelegate) async throws {
    let player = try #require(agent.player)
    try #require(!agent.playerLayers.isEmpty)
    let deadline = Date().addingTimeInterval(6)
    while player.currentItem?.status != .readyToPlay || !agent.playerLayers.allSatisfy(\.isReadyForDisplay) {
        try #require(Date() < deadline, "Wallpaper must decode and attach a ready video layer; a running PID or nonzero rate is insufficient")
        pumpSessionRegressionAppKit()
        try await Task.sleep(for: .milliseconds(10))
    }
    let item = try #require(player.currentItem)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    item.add(output)
    defer { item.remove(output) }
    let firstTime = player.currentTime().seconds
    try #require(firstTime.isFinite)
    var decodedPixels: Set<UInt32> = []
    while player.currentTime().seconds - firstTime < 0.2 || decodedPixels.count < 2 {
        try #require(Date() < deadline, "Wallpaper must advance time and decode two different frames instead of retaining a still")
        if let buffer = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                decodedPixels.insert(UInt32(base[0]) | UInt32(base[1]) << 8 | UInt32(base[2]) << 16)
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        pumpSessionRegressionAppKit()
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(player.currentTime().seconds - firstTime >= 0.2)
    #expect(decodedPixels.count >= 2)
    #expect(player.rate > 0)
    #expect(agent.playerLayers.allSatisfy { $0.player === player && $0.isReadyForDisplay })
}

@MainActor private func pumpSessionRegressionAppKit() {
    CATransaction.flush()
    let deadline = Date().addingTimeInterval(0.005)
    while let event = NSApp.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
    }
    NSApp.updateWindows()
}

@MainActor private func makeSessionRegressionMovie(_ url: URL) async throws {
    let width = 64, height = 48
    let fps: Int32 = 12
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    writer.add(input)
    try #require(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<180 {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        var buffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                base[offset] = UInt8((frame * 7) % 256)
                base[offset + 1] = UInt8((x + frame) % 256)
                base[offset + 2] = UInt8((y + frame * 3) % 256)
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        try #require(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: 180, timescale: fps))
    await writer.finishWriting()
    try #require(writer.status == .completed)
}
