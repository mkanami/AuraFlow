import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import AuraWallpaperCore

private func effectsBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
    try #require(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess)
    return try #require(buffer)
}

@Test @MainActor func nativeEffectsMovieContainsSilentHEVCEffectsAndReusesOnlyMatchingCache() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraNativeMovie-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = try #require(Bundle.module.url(forResource: "wallpaper-with-audio", withExtension: "mp4"))
    let original = try Data(contentsOf: source)
    let preparer = NativeEffectsMediaPreparer(directory: root, canvas: CGSize(width: 320, height: 200), maximumDuration: 0.3)
    var settings = WallpaperEffectsPreset.cinematic.settings
    settings.rainEnabled = true; settings.glassRainEnabled = true; settings.rainAmount = 1
    let output = try await preparer.prepare(source: source, settings: settings, speed: 1.5, scaleMode: .fill, shouldProceed: { true })
    #expect(output != source && FileManager.default.isReadableFile(atPath: output.path))
    let asset = AVURLAsset(url: output)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try #require(tracks.first)
    let format = try #require(try await track.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
    #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    #expect(abs(try await asset.load(.duration).seconds - 0.3) < 0.05)
    let generator = AVAssetImageGenerator(asset: asset)
    let frame = try generator.copyCGImage(at: CMTime(value: 1, timescale: 30), actualTime: nil)
    #expect(frame.width == 320 && frame.height == 200)
    #expect(try Data(contentsOf: source) == original)
    let modified = try output.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    let cached = try await preparer.prepare(source: source, settings: settings, speed: 1.5, scaleMode: .fill, shouldProceed: { true })
    #expect(cached == output)
    #expect(try cached.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
    settings.rainColor = .red
    let red = try await preparer.prepare(source: source, settings: settings, speed: 1.5, scaleMode: .fill, shouldProceed: { true })
    #expect(red != output)
    let disabled = try await preparer.prepare(source: source, settings: WallpaperEffectsSettings(), speed: 1, scaleMode: .fill, shouldProceed: { true })
    #expect(disabled == source)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".render-") })
}

@Test @MainActor func nativeEffectsMovieCancellationLeavesNoMovieOrTemporaryFrames() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraCancelledMovie-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try #require(Bundle.module.url(forResource: "wallpaper-without-audio", withExtension: "mp4"))
    let preparer = NativeEffectsMediaPreparer(directory: root, canvas: CGSize(width: 320, height: 200), maximumDuration: 0.3)
    do {
        _ = try await preparer.prepare(source: source, settings: WallpaperEffectsPreset.cinematic.settings,
            speed: 1, scaleMode: .fill, shouldProceed: { false })
        Issue.record("Cancelled preparation must not return an installed source")
    } catch { #expect(error is CancellationError) }
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).allSatisfy { $0.hasSuffix(".lock") })
}
private func effectsBytes(_ buffer: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: pointer, count: CVPixelBufferGetBytesPerRow(buffer)*CVPixelBufferGetHeight(buffer)))
}

@Test @MainActor func nativeEffectsOffscreenFramesPreserveOrientationAndCompositeRealRainAndGlass() throws {
    let size = CGSize(width: 320, height: 200), rect = CGRect(origin: .zero, size: size)
    let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: rect)
    let input = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
        .cropped(to: CGRect(x: 0, y: 100, width: 320, height: 100)).composited(over: blue)
    let plain = try WallpaperEffectsFrameRenderer(size: size, settings: WallpaperEffectsSettings())
    let buffer = try effectsBuffer(width: 320, height: 200)
    try plain.render(image: input, into: buffer, deltaTime: 1.0/30, scaleMode: .fill)
    let original = effectsBytes(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
    let top = row*20+160*4, bottom = row*180+160*4
    #expect(original[top+2] > 220 && original[top] < 20, "Top red pixels must stay upright: \(Array(original[top..<top+4]))")
    #expect(original[bottom] > 220 && original[bottom+2] < 20, "Bottom pixels: \(Array(original[bottom..<bottom+4]))")
    var settings = WallpaperEffectsPreset.cinematic.settings
    settings.rainEnabled = true; settings.glassRainEnabled = true; settings.rainAmount = 0.9; settings.glassRainIntensity = 0.8
    let wet = try WallpaperEffectsFrameRenderer(size: size, settings: settings)
    for _ in 0..<5 { try wet.render(image: input, into: buffer, deltaTime: 1.0/30, scaleMode: .fill) }
    let effected = effectsBytes(buffer)
    #expect(wet.rainCount > 0 && wet.dropCount > 0)
    #expect(zip(original, effected).filter { abs(Int($0)-Int($1)) > 15 }.count > 1000,
        "Effects must exist in encoded pixels, independent of any preview/saver window")
}

@Test @MainActor func nativeEffectsEncodedPixelsContainVisibleWaterWithoutAWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraEncodedPixels-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let rect = CGRect(x: 0, y: 0, width: 320, height: 200)
    let blue = CIImage(color: CIColor(red: 0.1, green: 0.15, blue: 0.7)).cropped(to: rect)
    let input = CIImage(color: CIColor(red: 0.7, green: 0.15, blue: 0.1))
        .cropped(to: CGRect(x: 0, y: 100, width: 320, height: 100)).composited(over: blue)
    let context = CIContext(), source = root.appendingPathComponent("image.png")
    try context.writePNGRepresentation(of: input, to: source, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    var settings = WallpaperEffectsSettings()
    settings.enabled = true; settings.rainEnabled = true; settings.rainAmount = 1
    settings.glassRainEnabled = true; settings.glassRainIntensity = 1
    let preparer = NativeEffectsMediaPreparer(directory: root.appendingPathComponent("cache"), canvas: rect.size, maximumDuration: 0.4)
    let movie = try await preparer.prepare(source: source, settings: settings, speed: 1, scaleMode: .fill, shouldProceed: { true })
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let encoded = try generator.copyCGImage(at: CMTime(value: 5, timescale: 30), actualTime: nil)
    let pixel = try effectsBuffer(width: 320, height: 200)
    try WallpaperEffectsFrameRenderer(size: rect.size, settings: WallpaperEffectsSettings())
        .render(image: CIImage(cgImage: encoded), into: pixel, deltaTime: 0, scaleMode: .fill)
    let actual = effectsBytes(pixel), row = CVPixelBufferGetBytesPerRow(pixel)
    let top = row*20+160*4, bottom = row*180+160*4
    #expect(actual[top+2] > actual[top]+80 && actual[bottom] > actual[bottom+2]+80)
    try WallpaperEffectsFrameRenderer(size: rect.size, settings: WallpaperEffectsSettings())
        .render(image: input, into: pixel, deltaTime: 0, scaleMode: .fill)
    let plain = effectsBytes(pixel)
    #expect(zip(actual, plain).filter { abs(Int($0)-Int($1)) > 25 }.count > 1000,
        "The actual HEVC file must contain visible water, not just valid video metadata")
}
