import Foundation
import Testing
@testable import WallpaperControlApp

private func writeTinyGIF(to url: URL) throws {
    let bytes: [UInt8] = [
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00,
        0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0x21, 0xF9, 0x04, 0x01, 0x00,
        0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44,
        0x01, 0x00, 0x3B,
    ]
    try Data(bytes).write(to: url, options: .atomic)
}

@Test func wallpaperMediaKindRecognizesImagesAndKeepsLegacyMotionExtensions() {
    #expect(WallpaperMediaKind.forURL(URL(fileURLWithPath: "/tmp/wallpaper.png")) == .image)
    #expect(WallpaperMediaKind.forURL(URL(fileURLWithPath: "/tmp/wallpaper.heic")) == .image)
    #expect(WallpaperMediaKind.forURL(URL(fileURLWithPath: "/tmp/wallpaper.gif")) == .motion)
    #expect(WallpaperMediaKind.forURL(URL(fileURLWithPath: "/tmp/wallpaper.mp4")) == .motion)
}

@Test func lockScreenSourceFallsBackToDesktopSourceForOldConfigs() {
    let config = ControlConfig(
        video_path: "/tmp/desktop.mp4",
        playback_speed: 1.0
    )

    #expect(config.effectiveLockScreenPath == "/tmp/desktop.mp4")
    #expect(config.effectiveLockScreenRuntimePath == "/tmp/desktop.mp4")
}

@Test func staticLockScreenSourceIsMaterializedWithoutChangingDesktopPath() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowWallpaperMedia-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let imageURL = root.appendingPathComponent("lock-screen.png")
    let pngData = try #require(
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
    )
    try pngData.write(to: imageURL, options: .atomic)

    let store = WallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("Support", isDirectory: true))
    let movieURL = try store.ensureLockScreenVideo(from: imageURL)

    #expect(FileManager.default.fileExists(atPath: movieURL.path))
    #expect(WallpaperMediaKind.forURL(imageURL) == .image)
    #expect(movieURL.pathExtension == "mov")
    #expect(store.loadConfig().video_path.isEmpty)
}

@Test func animatedGIFLockScreenSourceIsMaterializedAsMovie() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowWallpaperGIF-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let gifURL = root.appendingPathComponent("lock-screen.gif")
    try writeTinyGIF(to: gifURL)
    let store = WallpaperRuntimeStore(
        appSupportURL: root.appendingPathComponent("Support", isDirectory: true)
    )

    let movieURL = try store.ensureLockScreenVideo(from: gifURL)

    #expect(FileManager.default.fileExists(atPath: movieURL.path))
    #expect(movieURL.pathExtension == "mov")
    #expect(WallpaperMediaKind.forURL(gifURL) == .motion)
}
