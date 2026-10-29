import AppKit
import Foundation
import Testing
@testable import AuraWallpaperCore

@Test func loginReusesPreparedWallpaperFrameWithoutDecodingOrRewritingIt() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("StillFrameLogin-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32))
    let source = root.appendingPathComponent("wallpaper.png")
    try #require(bitmap.representation(using: .png, properties: [:])).write(to: source)
    let support = root.appendingPathComponent("Support")
    let frame = try StillFrameService(appSupportURL: support).ensureCurrentStillFrame(from: source)
    let original = try FileManager.default.attributesOfItem(atPath: frame.path)
    let restored = try StillFrameService(appSupportURL: support).ensureCurrentStillFrame(from: source)
    let after = try FileManager.default.attributesOfItem(atPath: restored.path)
    #expect(restored == frame)
    #expect(original[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber)
    #expect(original[.modificationDate] as? Date == after[.modificationDate] as? Date)
}
