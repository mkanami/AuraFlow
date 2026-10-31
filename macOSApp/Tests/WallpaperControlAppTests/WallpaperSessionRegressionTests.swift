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
    let launchctlCalls: SessionLaunchctlCalls
    let presentWindow: ((NSWindow, WallpaperPresentationMode) -> Void)?
    let screensProvider: () -> [NSScreen]
    let fullscreenApplicationIsActive: @MainActor () -> Bool

    init(presentWindow: ((NSWindow, WallpaperPresentationMode) -> Void)? = nil,
         screensProvider: @escaping () -> [NSScreen] = { NSScreen.screens },
         fullscreenApplicationIsActive: @escaping @MainActor () -> Bool = { false }) throws {
        self.presentWindow = presentWindow
        self.screensProvider = screensProvider
        self.fullscreenApplicationIsActive = fullscreenApplicationIsActive
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraSessionRegression-\(UUID())")
        let calls = SessionLaunchctlCalls()
        launchctlCalls = calls
        store = WallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("login.plist"),
            launchctlRunner: { arguments in
                calls.values.append(arguments)
                return LaunchctlResult(succeeded: arguments.first != "print", output: "not loaded")
            })
        try store.ensureDirectories()
    }

    func start(stalePauseCommand: Bool = false, pauseOnFullscreen: Bool = false) async throws -> WallpaperAgentDelegate {
        let movie = root.appendingPathComponent("animated.mp4")
        try await makeSessionRegressionMovie(movie)
        let config = ControlConfig(video_path: movie.path, playback_speed: 1, autostart: true,
            pause_on_fullscreen: pauseOnFullscreen, show_on_lock_screen: true)
        try store.saveConfig(config)
        // Both files really survive a process/OS restart. The cached first
        // frame must not become the final presentation or replay an old Pause.
        _ = try store.ensureCurrentStillFrame(from: movie)
        if stalePauseCommand { try store.saveCommand(.init(operationID: 10, action: .pause, config: config)) }
        let agent = WallpaperAgentDelegate(store: store, lockScreenPlatform: UnsupportedAdapter(),
            presentWindow: presentWindow,
            screensProvider: screensProvider,
            observesSystemEvents: false, sessionIsLocked: { [weak self] in self?.locked },
            fullscreenApplicationIsActive: fullscreenApplicationIsActive)
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

// These cases use real decoded frames, but intercept every window ordering
// operation. The fixture never presents its wallpaper on the user's Desktop.
@Suite(.serialized)
struct HiddenLoginPlaybackTests {
    @Test @MainActor
    func loginBeforeDisplaysAreReadyRecoversAWindowWithoutRestartingTheDecoder() async throws {
        var displaysAvailable = false
        let fixture = try WallpaperSessionFixture(presentWindow: { _, _ in },
            screensProvider: { displaysAvailable ? NSScreen.screens : [] })
        defer { fixture.cleanup() }
        let agent = try await fixture.start()
        let player = try #require(agent.player)
        #expect(agent.windows.isEmpty)
        displaysAvailable = true
        agent.samplePlaybackHealth()
        try await requireAdvancingWallpaper(agent)
        #expect(agent.player === player)
        #expect(!agent.windows.isEmpty && agent.windows.allSatisfy { !$0.isVisible })
    }

    @Test @MainActor
    func loginPreferenceChangesFutureJobsWhileDecodedPlaybackContinues() async throws {
        let fixture = try WallpaperSessionFixture(presentWindow: { _, _ in })
        defer { fixture.cleanup() }
        let agent = try await fixture.start()
        try await requireAdvancingWallpaper(agent)
        let player = agent.player
        let pid = fixture.store.loadPID()
        let command = fixture.store.loadCommand()
        let manager = AutostartManager(store: fixture.store, helperURL: fixture.root.appendingPathComponent("helper"))
        for enabled in [false, true] {
            _ = try manager.setEnabled(enabled)
            try await requireAdvancingWallpaper(agent)
            #expect(agent.player === player)
            #expect(fixture.store.loadPID() == pid && fixture.store.loadCommand() == command)
            #expect(agent.windows.allSatisfy { !$0.isVisible })
            #expect(fixture.launchctlCalls.values.allSatisfy { $0.first == "print" })
        }
    }

    @Test @MainActor
    func loginDecodesMotionBeforePresentingAndNeverUsesACachedDesktopStill() async throws {
        var presentations = 0
        let fixture = try WallpaperSessionFixture(presentWindow: { _, _ in presentations += 1 })
        defer { fixture.cleanup() }
        let agent = try await fixture.start(stalePauseCommand: true)
        #expect(presentations == 0)
        #expect(agent.windows.allSatisfy { !$0.isVisible })
        #expect(agent.windows.allSatisfy { $0.contentView?.layer?.contents == nil })
        try await requireAdvancingWallpaper(agent)
        #expect(presentations > 0)
        #expect(agent.windows.allSatisfy { !$0.isVisible })
        let player = agent.player
        fixture.setLocked(true)
        fixture.setLocked(false)
        try await requireAdvancingWallpaper(agent)
        #expect(agent.player === player)
        #expect(agent.windows.allSatisfy { !$0.isVisible })
    }
}

private final class SessionLaunchctlCalls { var values: [[String]] = [] }

@Suite(.serialized)
struct FullscreenResumeRegressionTests {
    @Test(arguments: [false, true]) @MainActor
    func videoResumesPromptlyWhenTheCoveringWindowLeaves(spaceChanged: Bool) async throws {
        var coveringWindow = true
        let fixture = try WallpaperSessionFixture(presentWindow: { _, _ in },
            fullscreenApplicationIsActive: { coveringWindow })
        defer { fixture.cleanup() }
        let agent = try await fixture.start(pauseOnFullscreen: true)
        let player = try #require(agent.player)
        agent.startFullscreenMonitoring()
        try await requireAdvancingWallpaper(agent)
        let pauseDeadline = Date().addingTimeInterval(4)
        while player.rate > 0 {
            try #require(Date() < pauseDeadline, "A covering window must still auto-pause playback")
            try await Task.sleep(for: .milliseconds(10))
        }
        if spaceChanged {
            agent.activeSpaceDidChange()
            #expect(player.rate == 0, "A Space change must keep playback paused while the Desktop remains covered")
        }
        coveringWindow = false
        if spaceChanged { agent.activeSpaceDidChange() }
        let resumeDeadline = Date().addingTimeInterval(0.75)
        while player.rate == 0 {
            try #require(Date() < resumeDeadline, "An exposed Desktop must not wait for two slow fullscreen polls or the Spaces pause grace period")
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(agent.player === player)
        #expect(agent.windows.allSatisfy { !$0.isVisible })
        try await requireAdvancingWallpaper(agent)

        fixture.store.markPaused(true)
        try fixture.store.saveCommand(.init(action: .pause, config: fixture.store.loadConfig()))
        agent.pollCommand()
        agent.activeSpaceDidChange()
        try await Task.sleep(for: .milliseconds(350))
        #expect(player.rate == 0 && fixture.store.isPaused(), "Visibility changes must preserve the user's explicit Stop")
    }
}

@Suite(.serialized)
struct WallpaperSessionRegressionTests {
    @Test @MainActor
    func issue5LoginCheckboxDoesNotStopRestartOrPauseCurrentWallpaper() async throws {
        let fixture = try WallpaperSessionFixture()
        defer { fixture.cleanup() }
        let agent = try await fixture.start()
        try await requireAdvancingWallpaper(agent)
        let originalPlayer = try #require(agent.player)
        let originalPID = fixture.store.loadPID()
        let command = fixture.store.loadCommand()
        fixture.store.markLockScreenAgentReady(true)
        try Data("existing login registration".utf8).write(to: fixture.store.launchAgentURL)
        let manager = AutostartManager(store: fixture.store, helperURL: fixture.root.appendingPathComponent("helper"))
        let disabled = try manager.setEnabled(false)
        try #require(fixture.launchctlCalls.values.allSatisfy { $0.first == "print" },
            "The login checkbox must not bootout, bootstrap, kickstart, or signal current playback")
        #expect(disabled.config.autostart == false)
        #expect(!fixture.store.launchAgentPlistExists())
        try await requireAdvancingWallpaper(agent)
        let enabled = try manager.setEnabled(true)
        #expect(enabled.config.autostart == true)
        #expect(fixture.store.launchAgentPlistExists())
        #expect(fixture.launchctlCalls.values.allSatisfy { $0.first == "print" })
        #expect(fixture.store.loadPID() == originalPID)
        #expect(agent.player === originalPlayer)
        #expect(fixture.store.loadCommand() == command)
        #expect(fixture.store.isLockScreenAgentReady())
        #expect(!fixture.store.isPaused())
        try await requireAdvancingWallpaper(agent)
    }

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
