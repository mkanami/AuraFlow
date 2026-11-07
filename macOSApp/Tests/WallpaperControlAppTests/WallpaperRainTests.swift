import AppKit
import QuartzCore
import Testing
@testable import AuraWallpaperCore

@Suite(.serialized)
struct WallpaperRainTests {
    @Test func olderPreferencesAndUnknownColorsUseBlueRainWithoutChangingTheLightColor() throws {
        for data in [#"{"enabled":true,"rainEnabled":true,"tint":"warm"}"#,
                     #"{"rainColor":"future-rain","tint":"warm"}"#] {
            let settings = try JSONDecoder().decode(WallpaperEffectsSettings.self, from: Data(data.utf8))
            #expect(settings.rainColor == .blue && settings.tint == .warm)
        }
        for preset in WallpaperEffectsPreset.allCases { #expect(preset.settings.rainColor == .blue) }
        for color in WallpaperRainColor.allCases {
            var settings = WallpaperEffectsSettings()
            settings.rainColor = color
            #expect(try JSONDecoder().decode(WallpaperEffectsSettings.self, from: JSONEncoder().encode(settings)) == settings)
        }
    }

    @Test @MainActor func densityAddsMoreDropsWithDifferentDepthsAndTurnsOffCleanly() throws {
        let layer = WallpaperRainLayer()
        var settings = rainSettings()
        let size = CGSize(width: 1920, height: 1080)
        layer.render(settings: settings, motion: WallpaperEffectsMotion(), size: size, scale: 2)
        let normal = visibleDrops(layer)
        #expect(normal.count > 240)
        #expect(Set(normal.map { $0.bounds.height }).count >= 6)
        let images = try normal.map { try image(in: $0) }
        #expect(images.allSatisfy { $0.width > 0 } && normal.allSatisfy { $0.contentsScale == 2 })
        settings.rainAmount = 1
        layer.render(settings: settings, motion: WallpaperEffectsMotion(), size: size, scale: 2)
        #expect(visibleDrops(layer).count > normal.count && visibleDrops(layer).count <= 512)
        settings.rainAmount = 0.1
        layer.render(settings: settings, motion: WallpaperEffectsMotion(), size: size, scale: 2)
        #expect(visibleDrops(layer).count < normal.count)
        settings.rainEnabled = false
        layer.render(settings: settings, motion: WallpaperEffectsMotion(), size: size, scale: 2)
        #expect(layer.isHidden)
        settings.rainEnabled = true
        layer.render(settings: settings, motion: WallpaperEffectsMotion(), size: size, scale: 2)
        #expect(!layer.isHidden && !visibleDrops(layer).isEmpty)
    }

    @Test @MainActor func dropsAreBlueUnderWarmLightingAndChangeToRedIndependently() throws {
        let overlay = WallpaperEffectsOverlay()
        var settings = rainSettings()
        settings.tint = .warm
        let size = CGSize(width: 1200, height: 800)
        overlay.render(settings: settings, motion: WallpaperEffectsMotion(), size: size, scale: 2)
        let rain = try #require(overlay.sublayers?.first { $0.name == "rain" })
        let first = try #require(visibleDrops(rain).first)
        let blue = try image(in: first)
        let bluePixels = try averageColor(blue)
        #expect(bluePixels.b > bluePixels.r * 1.8)
        settings.rainColor = .red
        overlay.render(settings: settings, motion: WallpaperEffectsMotion(), size: size, scale: 2)
        let red = try image(in: first)
        let redPixels = try averageColor(red)
        #expect(redPixels.r > redPixels.b * 1.8)
        #expect(settings.tint == .warm && red !== blue)
    }

    @Test @MainActor func framesSpeedAndDensityReuseTexturesButDisplayScaleImprovesResolution() throws {
        let layer = WallpaperRainLayer()
        var settings = rainSettings()
        var motion = WallpaperEffectsMotion()
        let size = CGSize(width: 1920, height: 1080)
        layer.render(settings: settings, motion: motion, size: size, scale: 1)
        let drop = try #require(visibleDrops(layer).first)
        let original = try image(in: drop)
        let initialPosition = drop.position
        for _ in 0..<120 {
            motion.advance(settings: settings, cursor: CGPoint(x: 0.8, y: 0.5), deltaTime: 1.0 / 60)
            layer.render(settings: settings, motion: motion, size: size, scale: 1)
        }
        #expect(drop.position != initialPosition)
        #expect(try image(in: drop) === original)
        settings.rainSpeed = 0.9
        settings.rainAmount = 1
        settings.tint = .aurora
        layer.render(settings: settings, motion: motion, size: size, scale: 1)
        #expect(try image(in: drop) === original)
        layer.render(settings: settings, motion: motion, size: size, scale: 2)
        let retina = try image(in: drop)
        #expect(retina.width >= original.width * 2 - 1 && retina.height >= original.height * 2 - 1)
    }

    @Test @MainActor func changingCursorWindAfterLongPlaybackDoesNotTeleportDrops() throws {
        let layer = WallpaperRainLayer()
        var settings = rainSettings()
        settings.parallaxEnabled = false
        settings.smoothing = 0
        var motion = WallpaperEffectsMotion()
        for _ in 0..<2400 { motion.advance(settings: settings, cursor: CGPoint(x: 1, y: 0), deltaTime: 0.1) }
        let size = CGSize(width: 1920, height: 1080)
        layer.render(settings: settings, motion: motion, size: size, scale: 1)
        let drops = visibleDrops(layer)
        let before = drops.map(\.position)
        motion.advance(settings: settings, cursor: CGPoint(x: -1, y: 0), deltaTime: 1.0 / 60)
        layer.render(settings: settings, motion: motion, size: size, scale: 1)
        let visible = zip(drops, before).filter { $0.1.x > 0 && $0.1.x < size.width }
        #expect(visible.allSatisfy { abs($0.0.position.x - $0.1.x) < 5 })
    }

    private func rainSettings() -> WallpaperEffectsSettings {
        var settings = WallpaperEffectsPreset.subtle.settings
        settings.rainEnabled = true
        return settings
    }

    private func visibleDrops(_ layer: CALayer) -> [CALayer] { (layer.sublayers ?? []).filter { !$0.isHidden } }

    private func image(in layer: CALayer) throws -> CGImage {
        let contents = try #require(layer.contents)
        try #require(CFGetTypeID(contents as CFTypeRef) == CGImage.typeID)
        return contents as! CGImage
    }

    private func averageColor(_ image: CGImage) throws -> (r: Double, g: Double, b: Double) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var r = 0.0, g = 0.0, b = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            r += Double(pixels[index]); g += Double(pixels[index + 1]); b += Double(pixels[index + 2])
        }
        return (r, g, b)
    }
}
