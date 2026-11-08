import AppKit
import AVFoundation
import QuartzCore
import IOSurface
import Testing
@testable import AuraWallpaperCore

@Suite(.serialized)
struct WallpaperRainTests {
    @Test @MainActor func threeDepthPoolsHaveTheRequestedDistributionAndMostlyHeadlessStreaks() throws {
        let rain = WallpaperRainLayer()
        var settings = rainSettings()
        settings.rainAmount = 1
        rain.render(settings: settings, motion: WallpaperEffectsMotion(), size: CGSize(width: 1920, height: 1080), scale: 2)
        let groups = try #require(rain.sublayers)
        #expect(groups.map(\.name) == ["rain-far", "rain-middle", "rain-near"])
        let drops = groups.map { ($0.sublayers ?? []).filter { !$0.isHidden } }
        #expect(drops.map(\.count) == [359, 128, 25])
        let all = drops.flatMap { $0 }
        #expect(all.filter { $0.name == "rain-drop-highlight" }.count == 51)
        #expect(Set(all.map { $0.bounds.height }).count > 100)
        #expect(Set(all.map { $0.bounds.width }).count > 100)
        #expect(Set(all.map(\.opacity)).count > 100)
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        let lengths = drops.map { mean($0.map { Double($0.bounds.height) }) }
        #expect(lengths[0] < lengths[1] && lengths[1] < lengths[2])
        #expect(drops[0].allSatisfy { $0.opacity < 0.22 })
        // Changing the density repeatedly cannot accumulate additional particle pools.
        for amount in stride(from: 0.02, through: 1, by: 0.02) {
            settings.rainAmount = amount
            rain.render(settings: settings, motion: WallpaperEffectsMotion(), size: CGSize(width: 1920, height: 1080), scale: 2)
        }
        #expect(groups.flatMap { $0.sublayers ?? [] }.count <= 512)
    }

    @Test @MainActor func windTrajectoriesIgnoreTheCursorAndParallaxOnlyOffsetsTheDepthPlanes() throws {
        let left = WallpaperRainLayer(), right = WallpaperRainLayer()
        var settings = rainSettings()
        settings.parallaxEnabled = false
        var a = WallpaperEffectsMotion(), b = WallpaperEffectsMotion()
        let size = CGSize(width: 1920, height: 1080)
        for _ in 0..<300 {
            a.advance(settings: settings, cursor: CGPoint(x: -1, y: -1), deltaTime: 1.0 / 60)
            b.advance(settings: settings, cursor: CGPoint(x: 1, y: 1), deltaTime: 1.0 / 60)
            left.render(settings: settings, motion: a, size: size, scale: 1)
            right.render(settings: settings, motion: b, size: size, scale: 1)
        }
        let l = visibleDrops(left), r = visibleDrops(right)
        #expect(l.map(\.position) == r.map(\.position))
        #expect(zip(l, r).allSatisfy { $0.affineTransform() == $1.affineTransform() })
        settings.parallaxEnabled = true
        settings.parallaxAmount = 1
        left.render(settings: settings, motion: a, size: size, scale: 1)
        right.render(settings: settings, motion: b, size: size, scale: 1)
        #expect(zip(l, r).allSatisfy { $0.affineTransform() == $1.affineTransform() })
        let offsets = zip(l, r).map { abs($0.position.x - $1.position.x) }
        let farOffset = try #require(offsets.first), nearOffset = try #require(offsets.last)
        #expect(farOffset < nearOffset)
        #expect(offsets.allSatisfy { $0 <= 22 })
    }

    @Test @MainActor func fasterRainLengthensTheTrailAndNearDropsFallFasterWithoutNewTextures() throws {
        let rain = WallpaperRainLayer()
        var settings = rainSettings()
        settings.rainSpeed = 0
        let size = CGSize(width: 1920, height: 1080)
        var motion = WallpaperEffectsMotion()
        rain.render(settings: settings, motion: motion, size: size, scale: 1)
        let drops = visibleDrops(rain)
        let heights = drops.map { $0.bounds.height }
        let textures = try drops.map { try image(in: $0) }
        settings.rainSpeed = 1
        rain.render(settings: settings, motion: motion, size: size, scale: 1)
        #expect(zip(drops, heights).allSatisfy { $0.bounds.height > $1 })
        for (drop, texture) in zip(drops, textures) { #expect(try image(in: drop) === texture) }
        let before = drops.map(\.position)
        motion.advance(settings: settings, cursor: nil, deltaTime: 1.0 / 60)
        rain.render(settings: settings, motion: motion, size: size, scale: 1)
        let distances = zip(drops, before).map { abs($0.position.y - $1.y) }.filter { $0 < 100 }
        let nearDistance = try #require(distances.last), farDistance = try #require(distances.first)
        #expect(nearDistance > farDistance)
    }

    @Test @MainActor func restoringDensityUpdatesPreviouslyHiddenDropsToTheCurrentColorAndSpeed() throws {
        let rain = WallpaperRainLayer()
        var settings = rainSettings()
        settings.rainAmount = 1
        let size = CGSize(width: 1920, height: 1080)
        rain.render(settings: settings, motion: WallpaperEffectsMotion(), size: size, scale: 1)
        let last = try #require(visibleDrops(rain).last)
        let height = last.bounds.height
        settings.rainAmount = 0.1
        rain.render(settings: settings, motion: WallpaperEffectsMotion(), size: size, scale: 1)
        #expect(last.isHidden)
        settings.rainColor = .red
        settings.rainSpeed = 1
        rain.render(settings: settings, motion: WallpaperEffectsMotion(), size: size, scale: 2)
        settings.rainAmount = 1
        rain.render(settings: settings, motion: WallpaperEffectsMotion(), size: size, scale: 2)
        let color = try averageColor(image(in: last))
        #expect(!last.isHidden && last.bounds.height > height && last.contentsScale == 2)
        #expect(color.r > color.b * 1.8)
    }

    @Test @MainActor func darkScenesDimRainAndNeonAccentsOnlyColorSomeDrops() throws {
        let dark = try #require(WallpaperRainLighting.analyze(scene(neon: false)))
        let neon = try #require(WallpaperRainLighting.analyze(scene(neon: true)))
        #expect(dark.accents.isEmpty && neon.accents.count == 2)
        #expect(neon.palette(base: .blue).count == 3)
        #expect(dark.illumination(x: 0.5, y: 0.5) < neon.illumination(x: 0.5, y: 0.5))
        let rain = WallpaperRainLayer()
        let settings = rainSettings(), size = CGSize(width: 1920, height: 1080)
        rain.lighting = dark
        rain.render(settings: settings, motion: WallpaperEffectsMotion(), size: size, scale: 2)
        let dim = visibleDrops(rain).map(\.opacity)
        rain.lighting = neon
        rain.render(settings: settings, motion: WallpaperEffectsMotion(), size: size, scale: 2)
        let drops = visibleDrops(rain)
        #expect(zip(drops, dim).allSatisfy { $0.opacity >= $1 })
        let colors = try drops.map { try averageColor(image(in: $0)) }
        let pink = colors.filter { $0.r > $0.g * 1.5 }
        #expect(!pink.isEmpty && pink.count < drops.count / 4)
        #expect(drops.allSatisfy { $0.filters == nil && $0.shadowOpacity == 0 })
        if let directory = ProcessInfo.processInfo.environment["AURAFLOW_RAIN_ARTIFACTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for (name, lighting) in [("dark", dark), ("neon", neon)] {
                rain.lighting = lighting
                let background = try scene(neon: name == "neon", size: size)
                var motion = WallpaperEffectsMotion()
                for _ in 0..<60 {
                    motion.advance(settings: settings, cursor: CGPoint(x: 0.4, y: 0), deltaTime: 1.0 / 60)
                    rain.render(settings: settings, motion: motion, size: size, scale: 2)
                }
                let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(background, in: CGRect(origin: .zero, size: size))
                rain.render(in: context)
                let output = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
                try output.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            }
        }
    }

    @Test @MainActor func lightingSamplingIsBoundedAndDiscardsResultsAfterSuspension() async throws {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        view.wantsLayer = true
        view.layer?.contents = try scene(neon: true)
        let sampler = WallpaperRainLightingSampler()
        var results: [WallpaperRainLighting] = []
        sampler.onSample = { results.append($0) }
        sampler.sample(content: view, surfaceID: nil, imageURL: nil, at: 0)
        sampler.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(results.allSatisfy { $0 == .neutral })
        sampler.sample(content: view, surfaceID: nil, imageURL: nil, at: 2)
        let deadline = Date().addingTimeInterval(3)
        while results.last?.accents.count != 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(results.last?.accents.count == 2)
        let submitted = sampler.submittedSamples
        for time in 3..<100 { sampler.sample(content: view, surfaceID: nil, imageURL: nil, at: Double(time)) }
        #expect(sampler.submittedSamples == submitted, "A static image must not be resampled every poll")
        #expect(view.window == nil)
        sampler.stop()
    }

    @Test @MainActor func lightingReadsTheLiveTerminalSurfaceAndRefreshesWithoutChangingItsID() async throws {
        let surface = try #require(IOSurfaceCreate([kIOSurfaceWidth: 64, kIOSurfaceHeight: 32,
            kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: 256,
            kIOSurfacePixelFormat: UInt32(0x42475241), "IOSurfaceIsGlobal": true] as CFDictionary))
        func paint(neon: Bool) throws {
            IOSurfaceLock(surface, [], nil)
            defer { IOSurfaceUnlock(surface, [], nil) }
            let context = try #require(CGContext(data: IOSurfaceGetBaseAddress(surface), width: 64, height: 32,
                bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.draw(try scene(neon: neon), in: CGRect(x: 0, y: 0, width: 64, height: 32))
        }
        try paint(neon: true)
        let sampler = WallpaperRainLightingSampler()
        var results: [WallpaperRainLighting] = []
        sampler.onSample = { if !$0.cells.isEmpty { results.append($0) } }
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 320))
        sampler.sample(content: content, surfaceID: IOSurfaceGetID(surface), imageURL: nil, at: 0)
        var deadline = Date().addingTimeInterval(3)
        while results.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(results.last?.accents.count == 2)
        let first = try #require(results.last)
        sampler.sample(content: content, surfaceID: IOSurfaceGetID(surface), imageURL: nil, at: 1)
        #expect(sampler.submittedSamples == 1)
        try paint(neon: false)
        sampler.sample(content: content, surfaceID: IOSurfaceGetID(surface), imageURL: nil, at: 2)
        deadline = Date().addingTimeInterval(3)
        while results.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let dark = try #require(results.last)
        #expect(results.count == 2 && dark.accents.isEmpty)
        #expect(dark.illumination(x: 0.5, y: 0.5) < first.illumination(x: 0.5, y: 0.5))
        sampler.stop()
        #expect(content.window == nil)
    }

    @Test @MainActor func videoLightingUsesDecodedFramesAndReleasesItsOutputOnPause() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("RainLight-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            let readyDeadline = Date().addingTimeInterval(2)
            while !input.isReadyForMoreMediaData && Date() < readyDeadline { try await Task.sleep(for: .milliseconds(1)) }
            try #require(input.isReadyForMoreMediaData)
            var pixelBuffer: CVPixelBuffer?
            #expect(CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &pixelBuffer) == kCVReturnSuccess)
            let buffer = try #require(pixelBuffer)
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 32, height: 32,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.draw(try scene(neon: true), in: CGRect(x: 0, y: 0, width: 32, height: 32))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        let item = AVPlayerItem(url: file), sampler = WallpaperRainLightingSampler()
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        view.layer?.addSublayer(layer)
        var lighting: WallpaperRainLighting?
        sampler.onSample = { if !$0.cells.isEmpty { lighting = $0 } }
        player.play()
        defer { player.pause(); sampler.stop() }
        let deadline = Date().addingTimeInterval(4)
        var time = 0.0
        while lighting == nil && Date() < deadline {
            sampler.sample(content: view, surfaceID: nil, imageURL: nil, at: time)
            time += 2
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(lighting?.accents.count == 2)
        #expect(item.outputs.count == 1)
        sampler.stop()
        #expect(item.outputs.isEmpty && view.window == nil)
    }

    private func scene(neon: Bool, size: CGSize = CGSize(width: 64, height: 32)) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if neon {
            context.setFillColor(CGColor(red: 0.9, green: 0.04, blue: 0.65, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
            context.setFillColor(CGColor(red: 0.03, green: 0.7, blue: 0.95, alpha: 1))
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        } else {
            context.setFillColor(CGColor(red: 0.025, green: 0.03, blue: 0.055, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try #require(context.makeImage())
    }

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

    private func visibleDrops(_ layer: CALayer) -> [CALayer] {
        (layer.sublayers ?? []).filter { !$0.isHidden }.flatMap {
            $0.name?.hasPrefix("rain-drop") == true ? [$0] : visibleDrops($0)
        }
    }

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
