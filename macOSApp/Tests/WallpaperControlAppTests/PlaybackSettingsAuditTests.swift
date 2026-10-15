import AVFoundation
import AuraWallpaperCore
import AuraTerminalWallpaperCore
import Foundation
import ImageIO
import Testing
@testable import WallpaperControlApp

@MainActor private func auditMovie(_ url: URL, width: Int = 72, height: Int = 48, fps: Int32 = 12) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                     kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<Int(fps) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
                base[i] = frame >= Int(fps)/2 ? 255 : 0
                base[i+1] = 0
                base[i+2] = frame < Int(fps)/2 ? 255 : 0
                base[i+3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: Int64(fps), timescale: fps))
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

private func auditRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraPlaybackAudit-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test @MainActor func playbackAuditBlendProducesMixedFramesAndKeepsResolutionDurationAndSource() async throws {
    let root = try auditRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.mp4")
    try await auditMovie(source)
    let original = try Data(contentsOf: source)
    let cache = VideoFrameBlendCache(appSupportURL: root)
    let movie = try await cache.prepare(source)
    let asset = AVURLAsset(url: movie)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    #expect(try await track.load(.naturalSize) == CGSize(width: 72, height: 48))
    #expect(try await track.load(.nominalFrameRate) >= 59.9)
    #expect(abs(CMTimeGetSeconds(try await asset.load(.duration)) - 1) < 0.05)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    var mixed = false
    for frame in 20...34 {
        let image = try await generator.image(at: CMTime(value: Int64(frame), timescale: 60)).image
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        if rgba[0] > 40 && rgba[2] > 40 && rgba[1] < 40 { mixed = true }
    }
    #expect(mixed) // Purple intermediary frames, not duplicated red/blue source frames.
    #expect(try Data(contentsOf: source) == original)
    #expect(try await cache.prepare(source) == movie)
    let store = WallpaperRuntimeStore(appSupportURL: root)
    var config = ControlConfig(video_path: source.path, playback_speed: 1, blend_interpolation: true)
    #expect(store.effectiveLockScreenSourceURL(for: config) == movie)
    config.blend_interpolation = false
    #expect(store.effectiveLockScreenSourceURL(for: config) == source)
    try store.saveLockScreenOnlySource(source)
    config.video_path = "/unused/desktop.mp4"
    config.blend_interpolation = true
    #expect(store.effectiveLockScreenSourceURL(for: config) == movie)
    // A damaged old cache must be regenerated rather than reported as a cache hit.
    try Data("unfinished".utf8).write(to: movie)
    #expect(try await cache.prepare(source) == movie)
    #expect(try Data(contentsOf: movie).count > 100)
}

@Test @MainActor func playbackAuditOptimizationProfilesAndCorruptCache() async throws {
    let root = try auditRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("portrait.mp4")
    try await auditMovie(source, width: 128, height: 1152, fps: 4)
    let optimizer = VideoOptimizer(cacheDirectory: root.appendingPathComponent("optimized"))
    var settings = VideoOptimizationSettings.default
    settings.enabled = false
    let disabled = try await optimizer.optimizeIfNeeded(inputURL: source, settings: settings, progress: { _ in })
    #expect(disabled.outputURL == source)
    settings.enabled = true
    settings.profile = .quality
    let quality = try await optimizer.optimizeIfNeeded(inputURL: source, settings: settings, progress: { _ in })
    let qTrack = try #require(try await AVURLAsset(url: quality.outputURL).loadTracks(withMediaType: .video).first)
    #expect(try await qTrack.load(.naturalSize) == CGSize(width: 128, height: 1152))
    let descriptions = try await qTrack.load(.formatDescriptions)
    #expect(descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_HEVC)
    #expect(try await qTrack.load(.nominalFrameRate) == 4)
    settings.profile = .balanced
    let balanced = try await optimizer.optimizeIfNeeded(inputURL: source, settings: settings, progress: { _ in })
    let track = try #require(try await AVURLAsset(url: balanced.outputURL).loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    #expect(size.width <= 1920 && size.height <= 1080)
    #expect(balanced.outputURL != quality.outputURL)
    let cached = try await optimizer.optimizeIfNeeded(inputURL: source, settings: settings, progress: { _ in })
    #expect(cached.fromCache && cached.outputURL == balanced.outputURL)
    try Data("unfinished".utf8).write(to: cached.outputURL)
    let repaired = try await optimizer.optimizeIfNeeded(inputURL: source, settings: settings, progress: { _ in })
    #expect(!repaired.fromCache && repaired.outputURL == cached.outputURL)
    #expect(try FileManager.default.contentsOfDirectory(atPath: repaired.outputURL.deletingLastPathComponent().path).allSatisfy { !$0.contains("partial") })
}

@Test @MainActor func playbackAuditFailedConversionLeavesNoCacheAndReportsEncoderError() async throws {
    let root = try auditRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("ffmpeg")
    try Data("#!/bin/sh\nif [ \"$1\" = -version ]; then exit 0; fi\nfor last; do :; done\nprintf partial > \"$last\"\nprintf 'intentional encoder failure\\n' >&2\nexit 1\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let old = ProcessInfo.processInfo.environment["AURAFLOW_FFMPEG_PATH"]
    setenv("AURAFLOW_FFMPEG_PATH", script.path, 1)
    defer { if let old { setenv("AURAFLOW_FFMPEG_PATH", old, 1) } else { unsetenv("AURAFLOW_FFMPEG_PATH") } }
    let source = root.appendingPathComponent("source.webm")
    try Data("fake web container".utf8).write(to: source)
    let output = root.appendingPathComponent("optimized")
    let optimizer = VideoOptimizer(cacheDirectory: output)
    do {
        _ = try await optimizer.optimizeIfNeeded(inputURL: source, settings: .default, progress: { _ in })
        Issue.record("Expected conversion failure")
    } catch { #expect(error.localizedDescription.contains("intentional encoder failure")) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
}

@Test @MainActor func playbackAuditOptimizationPreferencesPersistAndAV1GuardMatchesHardware() throws {
    let suite = "AuraPlaybackAudit-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = VideoOptimizationStore(defaults: defaults)
    let app = AppViewModel(controller: MockNativeWallpaperController(), optimizationStore: store)
    app.setOptimizationEnabled(false)
    app.setOptimizationTranscodeH264ToHEVC(false)
    app.setOptimizationAllowAV1Passthrough(false)
    app.setOptimizationProfile(.quality)
    app.setOptimizationForceSoftwareAV1Encode(true)
    let saved = store.load()
    #expect(!saved.enabled && !saved.transcodeH264ToHEVC && !saved.allowAV1PassthroughOnHardwareDecode)
    #expect(saved.profile == .quality)
    #expect(saved.forceSoftwareAV1Encode == app.optimizationHardwareAV1DecodeAvailable)
}

private final class AuditLockScreen: LockScreenSaverInstalling {
    var isInstalled = true
    var failNextInstall = false
    var installs: [(URL, Double, WallpaperScaleMode, Bool)] = []
    var pauses = 0
    func install(videoURL: URL) throws {}
    func installForDesktopAgent(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) throws {
        if failNextInstall { failNextInstall = false; throw CocoaError(.fileWriteUnknown) }
        installs.append((videoURL, playbackSpeed, scaleMode, false))
    }
    func installLockScreenOnly(videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) throws {
        if failNextInstall { failNextInstall = false; throw CocoaError(.fileWriteUnknown) }
        installs.append((videoURL, playbackSpeed, scaleMode, true))
    }
    func pauseLockScreenOnlyPlayback(videoURL: URL) throws -> Bool { pauses += 1; return true }
    func uninstall() throws {}
}

@Test @MainActor func playbackAuditNativeBlendPreservesSourceRateScalePauseAndRollsBackErrors() async throws {
    let root = try auditRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.mp4")
    try await auditMovie(source)
    let store = WallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("launch.plist"))
    var config = ControlConfig(video_path: source.path, playback_speed: 0.75, scale_mode: "fit")
    try store.saveConfig(config)
    store.markPaused(true)
    let platform = AuditLockScreen()
    let controller = try NativeWallpaperController(store: store, helperURL: URL(fileURLWithPath: "/usr/bin/true"),
        lockScreenSaverInstaller: platform, nativeBridgeURL: URL(fileURLWithPath: "/usr/bin/true"))
    let enabled = try await controller.setInterpolation(true)
    config.blend_interpolation = true
    #expect(enabled.config == config && enabled.paused == true)
    #expect(platform.installs.last?.0 == store.effectiveLockScreenSourceURL(for: config))
    #expect(platform.installs.last?.1 == 0.75 && platform.installs.last?.2 == .fit)
    #expect(platform.pauses == 1)
    platform.failNextInstall = true
    do { _ = try await controller.setInterpolation(false); Issue.record("Expected failed route update") }
    catch { #expect(store.loadConfig() == config) }
    #expect(store.isPaused())
    let disabled = try await controller.setInterpolation(false)
    #expect(disabled.config.video_path == source.path && disabled.config.blend_interpolation == false)
    #expect(platform.installs.last?.0 == source)
    try store.saveLockScreenOnlySource(source)
    _ = try await controller.setInterpolation(true)
    #expect(platform.installs.last?.3 == true)
    #expect(store.loadLockScreenOnlySource() == source && store.loadPID() == nil)
    store.clearLockScreenOnlySource()
    let next = root.appendingPathComponent("next.mp4")
    try FileManager.default.copyItem(at: source, to: next)
    let updated = try await controller.setVideo(next)
    #expect(updated.config.video_path == next.path && updated.config.blend_interpolation == true)
    #expect(store.effectiveLockScreenSourceURL(for: updated.config) != next)
}

@Test @MainActor func playbackAuditClearCacheKeepsActiveLockScreenAndBlendButDeletesUnusedCache() async throws {
    let root = try auditRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.mp4")
    try await auditMovie(source)
    let runtime = WallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("launch.plist"))
    try runtime.saveConfig(.init(video_path: source.path, playback_speed: 1, blend_interpolation: true))
    let blend = try await VideoFrameBlendCache(appSupportURL: root).prepare(source)
    let unused = blend.deletingLastPathComponent().appendingPathComponent("unused.mp4")
    try Data("unused cache".utf8).write(to: unused)
    let lockCache = root.appendingPathComponent("LockScreenMediaCache")
    try FileManager.default.createDirectory(at: lockCache, withIntermediateDirectories: true)
    try Data("active lock asset".utf8).write(to: lockCache.appendingPathComponent("active.mov"))
    let video = MockNativeWallpaperController()
    video.configuredVideoURL = source
    video.statusRunning = true
    let app = AppViewModel(controller: video, appSupportDirectoryURL: root)
    await app.loadStatus()
    #expect(app.hasInstalledWallpaperSessionForControls)
    #expect(runtime.effectiveLockScreenSourceURL(for: runtime.loadConfig())?.path == blend.path)
    app.clearCache()
    let deadline = Date().addingTimeInterval(3)
    while app.statusMessage != "Cache and downloaded wallpapers cleared.", Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(app.alertMessage == nil)
    #expect(app.statusMessage == "Cache and downloaded wallpapers cleared.")
    #expect(FileManager.default.fileExists(atPath: blend.path))
    #expect(FileManager.default.fileExists(atPath: lockCache.appendingPathComponent("active.mov").path))
    #expect(!FileManager.default.fileExists(atPath: unused.path))
    #expect(video.clearCallCount == 0 && app.isRunning)
}

@Test @MainActor func playbackAuditBlendAvailabilityAndCancellation() async throws {
    let root = try auditRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
    selection.selectTerminal(.init(command: .init(executable: "/bin/echo")))
    let app = AppViewModel(controller: MockNativeWallpaperController(), appSupportDirectoryURL: root,
        previewSelectionStore: selection)
    #expect(!app.canToggleBlendInterpolation)
    app.toggleBlendInterpolation(true)
    #expect(!app.blendInterpolationEnabled && !app.isBusy)
    let source = root.appendingPathComponent("source.mp4")
    try await auditMovie(source)
    let script = root.appendingPathComponent("slow-ffmpeg")
    try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let cache = VideoFrameBlendCache(appSupportURL: root)
    let job = Task { try await cache.prepare(source, ffmpegURL: script) }
    try await Task.sleep(for: .milliseconds(100))
    let started = Date()
    job.cancel()
    do { _ = try await job.value; Issue.record("Expected cancellation") }
    catch { #expect(error is CancellationError) }
    #expect(Date().timeIntervalSince(started) < 2)
    #expect(!FileManager.default.fileExists(atPath: try cache.outputURL(for: source).path))
}

@Test @MainActor func playbackAuditNativeHighFrameRateDoesNotReencode() async throws {
    let root = try auditRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("90fps.mp4")
    try await auditMovie(source, fps: 90)
    let bytes = try Data(contentsOf: source)
    let cache = VideoFrameBlendCache(appSupportURL: root)
    #expect(try await cache.prepare(source) == source)
    #expect(try Data(contentsOf: source) == bytes)
    #expect(!FileManager.default.fileExists(atPath: cache.directory.path))
}

@Test @MainActor func playbackAuditClearManagedLockOnlyStopsItsRuntimeBeforeDeletingSource() async throws {
    let root = try auditRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let optimized = root.appendingPathComponent("OptimizedVideos")
    try FileManager.default.createDirectory(at: optimized, withIntermediateDirectories: true)
    let source = optimized.appendingPathComponent("lock-only.mp4")
    try await auditMovie(source)
    let runtime = WallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("launch.plist"))
    try runtime.saveLockScreenOnlySource(source)
    let video = MockNativeWallpaperController()
    video.statusLockScreenOnly = true
    video.statusPaused = false
    let app = AppViewModel(controller: video, appSupportDirectoryURL: root)
    await app.loadStatus()
    #expect(app.isLockScreenOnlyActive)
    app.clearCache()
    let deadline = Date().addingTimeInterval(3)
    while app.statusMessage != "Cache and downloaded wallpapers cleared.", Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(app.alertMessage == nil)
    #expect(video.clearCallCount == 1)
    #expect(!FileManager.default.fileExists(atPath: source.path))
}

@Test @MainActor func playbackAuditBlendToggleSurvivesStatusPollingAndUpdatesPreview() async throws {
    let root = try auditRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.mp4")
    try await auditMovie(source)
    let store = WallpaperRuntimeStore(appSupportURL: root, launchAgentURL: root.appendingPathComponent("launch.plist"))
    try store.saveConfig(.init(video_path: source.path, playback_speed: 1))
    let platform = AuditLockScreen()
    platform.isInstalled = false
    let controller = try NativeWallpaperController(store: store, helperURL: URL(fileURLWithPath: "/usr/bin/true"),
        lockScreenSaverInstaller: platform, nativeBridgeURL: URL(fileURLWithPath: "/usr/bin/true"))
    let app = AppViewModel(controller: controller, appSupportDirectoryURL: root)
    await app.loadStatus()
    #expect(app.canToggleBlendInterpolation)
    app.toggleBlendInterpolation(true)
    #expect(app.isBusy && app.blendInterpolationEnabled)
    await app.loadStatus()
    #expect(app.blendInterpolationEnabled)
    let deadline = Date().addingTimeInterval(3)
    while app.isBusy, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(app.alertMessage == nil && !app.isBusy && app.blendInterpolationEnabled)
    let cached = try VideoFrameBlendCache(appSupportURL: root).outputURL(for: source)
    #expect((app.previewPlayer?.currentItem?.asset as? AVURLAsset)?.url.path == cached.path)
    app.toggleBlendInterpolation(false)
    let disabledDeadline = Date().addingTimeInterval(3)
    while app.isBusy, Date() < disabledDeadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!app.blendInterpolationEnabled && !app.isBusy)
    #expect((app.previewPlayer?.currentItem?.asset as? AVURLAsset)?.url.path == source.path)
}

@Test @MainActor func playbackAuditGIFBalancedPreservesTimingAndCapsPortraitSize() async throws {
    let root = try auditRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("portrait.gif")
    let context = try #require(CGContext(data: nil, width: 128, height: 1152,
        bitsPerComponent: 8, bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 128, height: 1152))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "com.compuserve.gif" as CFString, 2, nil))
    let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    CGImageDestinationAddImage(destination, image, properties)
    #expect(CGImageDestinationFinalize(destination))
    let optimizer = VideoOptimizer(cacheDirectory: root.appendingPathComponent("optimized"))
    let result = try await optimizer.optimizeIfNeeded(inputURL: source, settings: .default, progress: { _ in })
    let asset = AVURLAsset(url: result.outputURL)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let size = try await track.load(.naturalSize)
    #expect(size.width <= 1920 && size.height <= 1080)
    #expect(abs(CMTimeGetSeconds(try await asset.load(.duration)) - 0.4) < 0.04)
}
