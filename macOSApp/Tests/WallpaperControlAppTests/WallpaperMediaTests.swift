import Foundation
import Testing
@testable import WallpaperControlApp

@Test func wallpaperMediaKindRecognizesImagesAndKeepsLegacyMotionExtensions() {
    #expect(WallpaperMediaKind.forURL(URL(fileURLWithPath: "/tmp/wallpaper.png")) == .image)
    #expect(WallpaperMediaKind.forURL(URL(fileURLWithPath: "/tmp/wallpaper.heic")) == .image)
    #expect(WallpaperMediaKind.forURL(URL(fileURLWithPath: "/tmp/wallpaper.gif")) == .motion)
    #expect(WallpaperMediaKind.forURL(URL(fileURLWithPath: "/tmp/wallpaper.mp4")) == .motion)
}
