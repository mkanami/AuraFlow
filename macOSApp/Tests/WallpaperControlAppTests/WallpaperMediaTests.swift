import Foundation
import Testing
@testable import WallpaperControlApp

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
