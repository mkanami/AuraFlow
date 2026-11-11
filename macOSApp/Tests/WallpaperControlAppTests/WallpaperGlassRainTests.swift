import AppKit
import AVFoundation
import CoreImage
import IOSurface
import Metal
import Testing
@testable import AuraWallpaperCore

@Suite(.serialized)
struct WallpaperGlassRainTests {
    private func settings() -> WallpaperEffectsSettings {
        var s = WallpaperEffectsSettings()
        s.enabled = true; s.parallaxEnabled = false; s.glowEnabled = false
        s.glassRainEnabled = true
        return s
    }

    @Test func independentModesMigrateNormalizeAndRoundTrip() throws {
        var s = try JSONDecoder().decode(WallpaperEffectsSettings.self, from: Data(#"{"enabled":true,"rainEnabled":true,"rainColor":"red"}"#.utf8))
        #expect(!s.glassRainEnabled && s.glassRainSlidingEnabled && s.rainBlur == 0.25 && s.rainColor == .red)
        s = settings()
        #expect(s.hasVisibleEffects && s.hasAnimatedEffects && !s.rainEnabled)
        s.rainEnabled = true; s.glassRainIntensity = 0
        #expect(s.hasAnimatedEffects)
        s.rainEnabled = false
        #expect(!s.hasAnimatedEffects)
        s.glassRainIntensity = .nan; s.glassRainWind = -2; s.glassRainRefraction = 9
        s.glassRainBlur = .infinity
        s.glassRainSlidingEnabled = false
        s = s.normalized()
        #expect(s.glassRainIntensity == 0.45 && s.glassRainWind == 0 && s.glassRainRefraction == 1 && s.glassRainBlur == 0.2)
        #expect(try JSONDecoder().decode(WallpaperEffectsSettings.self, from: JSONEncoder().encode(s)) == s)
    }

    @Test func stationaryBeadsSlidingMergingAndTrailsStayBoundedAcrossFrameRates() {
        var a = WallpaperGlassRainSimulation(), b = WallpaperGlassRainSimulation()
        let s = settings()
        a.advance(deltaTime: 0, aspect: 16.0/9, settings: s)
        let initialBeads = a.beads, initialRunners = a.runners
        for _ in 0..<1800 { a.advance(deltaTime: 1.0/30, aspect: 16.0/9, settings: s) }
        for _ in 0..<3600 { b.advance(deltaTime: 1.0/60, aspect: 16.0/9, settings: s) }
        #expect(a.beads == b.beads && a.runners == b.runners)
        #expect(a.runners != initialRunners && a.mergeCount > 0)
        // Uncollected tiny beads remain exactly at their original positions.
        let stationary = zip(initialBeads, a.beads).filter { $0 == $1 }.count
        #expect(stationary > initialBeads.count / 3)
        #expect(!a.trails.isEmpty && a.trails.count <= 768)
        #expect(a.beads.count <= 1000 && a.runners.count <= 50 && a.instances.count <= 1818)
        #expect(a.instances.allSatisfy { $0.ellipse.x.isFinite && $0.ellipse.y.isFinite })
    }

    @Test func glassWindAndSpeedAreIndependentOfFallingRainAndCursor() {
        var a = WallpaperGlassRainSimulation(), b = WallpaperGlassRainSimulation()
        let s = settings()
        var alternate = s
        alternate.rainSpeed = 1; alternate.rainAngle = 0; alternate.rainEnabled = true
        alternate.reactsToCursor = false; alternate.rainBlur = 1
        for _ in 0..<300 {
            a.advance(deltaTime: 1.0/30, aspect: 1.6, settings: s)
            b.advance(deltaTime: 1.0/30, aspect: 1.6, settings: alternate)
        }
        #expect(a.runners == b.runners && a.beads == b.beads)
        alternate.glassRainSpeed = 1; alternate.glassRainWind = 0
        for _ in 0..<60 {
            a.advance(deltaTime: 1.0/30, aspect: 1.6, settings: s)
            b.advance(deltaTime: 1.0/30, aspect: 1.6, settings: alternate)
        }
        #expect(a.runners != b.runners)
    }

    @Test func slidingSwitchFreezesBeadsAndLargeDropsClearsTrailsAndResumesWithoutJumping() {
        var simulation = WallpaperGlassRainSimulation()
        var s = settings()
        for _ in 0..<300 { simulation.advance(deltaTime: 1.0/30,aspect: 16.0/9,settings: s) }
        #expect(!simulation.trails.isEmpty)
        s.glassRainSlidingEnabled = false
        simulation.advance(deltaTime: 0,aspect: 16.0/9,settings: s)
        let runners = simulation.runners, beads = simulation.beads, instances = simulation.instances
        for _ in 0..<600 { simulation.advance(deltaTime: 1.0/30,aspect: 16.0/9,settings: s) }
        #expect(simulation.runners == runners && simulation.beads == beads && simulation.instances == instances)
        #expect(simulation.trails.isEmpty && s.hasAnimatedEffects, "Video and Falling Rain still update through stationary glass")
        #expect(simulation.runners.allSatisfy { $0.velocityY == 0 })
        s.glassRainSlidingEnabled = true
        simulation.advance(deltaTime: 1.0/60,aspect: 16.0/9,settings: s)
        #expect(zip(runners,simulation.runners).allSatisfy { hypot($0.x-$1.x,$0.y-$1.y) < 2 })
        for _ in 0..<120 { simulation.advance(deltaTime: 1.0/60,aspect: 16.0/9,settings: s) }
        #expect(simulation.runners != runners && !simulation.trails.isEmpty)
        #expect(simulation.runners.contains { $0.velocityY > 20 })
    }

    @Test @MainActor func fallingRainSurvivesCompositorHandoffAndSourceUnavailability() throws {
        let overlay = WallpaperEffectsOverlay()
        var s = settings(); s.rainEnabled = true
        let size = CGSize(width: 1280,height: 720)
        overlay.render(settings: s,motion: WallpaperEffectsMotion(),size: size,scale: 1)
        let before = overlay.airRainInstances
        let rain = try #require(overlay.sublayers?.first { $0.name == "rain" })
        #expect(!before.isEmpty && !rain.isHidden)
        overlay.setRainComposited(true)
        #expect(rain.isHidden && overlay.airRainInstances.count == before.count)
        overlay.setRainComposited(false)
        #expect(!rain.isHidden)
        s.rainEnabled = false
        overlay.render(settings: s,motion: WallpaperEffectsMotion(),size: size,scale: 1)
        #expect(overlay.airRainInstances.isEmpty)
        s.rainEnabled = true
        let view = WallpaperEffectsView(content: NSView(frame: CGRect(origin: .zero,size: size)),store: nil)
        view.update(settings: s)
        view.applyActivity(WallpaperEffectsActivity())
        view.renderFrame(deltaTime: 1.0/30,cursor: nil)
        let visibleRain = try #require(view.layer?.sublayers?.first { $0 is WallpaperEffectsOverlay }?.sublayers?.first { $0.name == "rain" })
        #expect(view.status.glassReady == false && !visibleRain.isHidden)
        var paused = WallpaperEffectsActivity(); paused.playbackPaused = true
        view.applyActivity(paused)
        #expect(view.window == nil)
    }

    @Test @MainActor func wetGlassRefractsFallingRainAndDryAreasKeepTheSameStorm() throws {
        let renderer = try #require(WallpaperGlassRainRenderer())
        let queue = try #require(renderer.device.makeCommandQueue())
        let width = 512, height = 288
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: width,height: height,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget,.shaderRead]
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let size = CGSize(width: width,height: height), rect = CGRect(origin: .zero,size: size)
        let background = CIImage(color: .black).cropped(to: rect)
        let water = WallpaperGlassRainSimulation.Instance(ellipse: SIMD4(960,540,330,330),optics: SIMD4(1,0,0,0))
        let airborne = [900,350].map { x in WallpaperAirRainInstance(ellipse: SIMD4(Float(x),540,20,500),
            color: SIMD4(1,0.1,0.1,0.95),optics: SIMD4(0,0.65,0.95,0.15)) }
        var s = settings(); s.rainEnabled = true; s.glassRainBlur = 0; s.glassRainRefraction = 0
        func render(settings: WallpaperEffectsSettings,water: [WallpaperGlassRainSimulation.Instance],rain: [WallpaperAirRainInstance]) throws -> [UInt8] {
            let command = try #require(queue.makeCommandBuffer())
            try renderer.encode(command: command,target: target,
                source: .init(image: background,gravity: .resize,revision: 1,label: "test"),settings: settings,
                size: size,contentFrame: rect,instances: water,airRain: rain)
            command.commit(); command.waitUntilCompleted(); #expect(command.status == .completed)
            var pixels = [UInt8](repeating: 0,count: width*height*4)
            target.getBytes(&pixels,bytesPerRow: width*4,from: MTLRegionMake2D(0,0,width,height),mipmapLevel: 0)
            return pixels
        }
        let clear = try render(settings: s,water: [water],rain: airborne)
        s.glassRainRefraction = 1
        let wet = try render(settings: s,water: [water],rain: airborne)
        var wetChanges = 0, dryChanges = 0, dryVisible = 0
        for y in 0..<height { for x in 0..<width {
            let p=(y*width+x)*4
            if abs(Int(clear[p+2])-Int(wet[p+2])) > 15 {
                if hypot(Double(x)-256,Double(y)-144) < 95 { wetChanges += 1 }
                else { dryChanges += 1 }
            }
            if x < 130 && wet[p+2] > 40 { dryVisible += 1 }
        } }
        #expect(wetChanges > 200)
        #expect(dryChanges == 0)
        #expect(dryVisible > 100)
        #expect(renderer.composedRainCount == 2)
        s.rainEnabled = false
        let noRain = try render(settings: s,water: [water],rain: airborne)
        #expect(renderer.composedRainCount == 0 && zip(wet,noRain).filter { abs(Int($0)-Int($1)) > 20 }.count > 500)
        let brightCenter = (125..<163).reduce(0) { count,y in
            count + (237..<275).filter { x in noRain[(y*width+x)*4+2] > 5 }.count
        }
        #expect(brightCenter < 10, "A specular highlight must not fill a flat triangular sector through the drop center")
        s.rainEnabled = true
        let dry = try render(settings: s,water: [],rain: airborne)
        #expect(dry[(height/2*width+Int(350.0/1920*512))*4+3] > 80)
        #expect(dry[3] == 0)
    }

    @Test @MainActor func metalReallyRefractsBlursUpdatesSourceAndLeavesDryPixelsTransparent() throws {
        let renderer = try #require(WallpaperGlassRainRenderer(), "A Metal device and compiling glass shaders are required")
        let device = renderer.device, queue = try #require(device.makeCommandQueue())
        let width = 512, height = 288
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let size = CGSize(width: width, height: height), rect = CGRect(origin: .zero, size: size)
        let drop = WallpaperGlassRainSimulation.Instance(ellipse: SIMD4(960,540,330,330), optics: SIMD4(1,0,0,0))
        var s = settings(); s.glassRainBlur = 0; s.glassRainRefraction = 0
        func render(_ image: CIImage, revision: UInt64, settings: WallpaperEffectsSettings) throws -> [UInt8] {
            let buffer = try #require(queue.makeCommandBuffer())
            try renderer.encode(command: buffer, target: target,
                source: .init(image: image, gravity: .resize, revision: revision, label: "test"),
                settings: settings, size: size, contentFrame: rect, instances: [drop])
            buffer.commit(); buffer.waitUntilCompleted()
            #expect(buffer.status == .completed)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0)
            return bytes
        }
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: rect)
        let redTop = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0,y: height/2,width: width,height: height/2)).composited(over: blue)
        let upright = try render(redTop, revision: 1, settings: s)
        let top = (height/2 - 30) * width * 4 + width/2 * 4
        let bottom = (height/2 + 30) * width * 4 + width/2 * 4
        #expect(upright[top+2] > 180 && upright[top] < 10, "Upper red background must remain upright")
        #expect(upright[bottom] > 180 && upright[bottom+2] < 10)
        #expect(upright[3] == 0 && upright[(height * width - 1) * 4 + 3] == 0)
        let stripes = try pattern(width: width, height: height)
        let clear = try render(CIImage(cgImage: stripes), revision: 2, settings: s)
        s.glassRainRefraction = 1
        let refracted = try render(CIImage(cgImage: stripes), revision: 2, settings: s)
        #expect(zip(clear, refracted).filter { abs(Int($0)-Int($1)) > 20 }.count > 3000)
        s.glassRainBlur = 1
        let blurred = try render(CIImage(cgImage: stripes), revision: 2, settings: s)
        #expect(zip(refracted, blurred).filter { abs(Int($0)-Int($1)) > 15 }.count > 1000)
        let changed = try render(blue, revision: 3, settings: s)
        #expect(changed[top] > 180 && changed[top+2] < 10, "The next media frame must replace the cached wallpaper")
        if let path = ProcessInfo.processInfo.environment["AURAFLOW_GLASS_ARTIFACTS"] {
            try exportScene(renderer: renderer, queue: queue, directory: path)
        }
        #expect(WallpaperGlassRainRenderer.renderSize(size: CGSize(width: 5120,height: 2880), scale: 2) == CGSize(width: 1920,height: 1080))
    }

    @Test @MainActor func liveIOSurfaceChangesAndStaticSourcesCacheWithoutCapturingAWindow() throws {
        let surface = try #require(IOSurfaceCreate([kIOSurfaceWidth: 64,kIOSurfaceHeight: 32,
            kIOSurfaceBytesPerElement: 4,kIOSurfaceBytesPerRow: 256,kIOSurfacePixelFormat: UInt32(0x42475241)] as CFDictionary))
        let content = NSView(frame: CGRect(x: 0,y: 0,width: 640,height: 320))
        let source = WallpaperGlassFrameSource()
        let first = try #require(source.current(content: content, surfaceID: IOSurfaceGetID(surface), sequence: 1, imageURL: nil, at: 0))
        let same = try #require(source.current(content: content, surfaceID: IOSurfaceGetID(surface), sequence: 1, imageURL: nil, at: 0.1))
        #expect(first.revision == same.revision && first.label == "rendered-frame")
        let next = try #require(source.current(content: content, surfaceID: IOSurfaceGetID(surface), sequence: 2, imageURL: nil, at: 0.2))
        #expect(next.revision != first.revision)
        source.stop()
        content.wantsLayer = true; content.layer?.contents = try pattern(width: 64,height: 32)
        let image = try #require(source.current(content: content,surfaceID: nil,sequence: nil,imageURL: nil,at: 1))
        let cached = source.current(content: content,surfaceID: nil,sequence: nil,imageURL: nil,at: 100)
        #expect(image.revision == cached?.revision && image.label == "image")
        content.layer?.contentsGravity = .resizeAspect
        #expect(source.current(content: content,surfaceID: nil,sequence: nil,imageURL: nil,at: 100.1)?.gravity == .resizeAspect)
        source.stop(); content.layer?.contents = nil
        #expect(source.current(content: content,surfaceID: nil,sequence: nil,imageURL: nil,at: 101) == nil)
        #expect(content.window == nil && source.submittedSnapshots == 0)
    }

    @Test @MainActor func videoFrameOutputsDetachOnAllSuspensionsAndResumeWithoutWindowActions() async throws {
        let file = try await videoFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let player = AVPlayer(url: file); player.isMuted = true
        let content = NSView(frame: CGRect(x: 0,y: 0,width: 640,height: 360)); content.wantsLayer = true
        content.layer?.addSublayer(AVPlayerLayer(player: player))
        let source = WallpaperGlassFrameSource()
        player.play()
        defer { source.stop(); player.pause() }
        var frame: WallpaperGlassFrameSource.Frame?
        let deadline = Date().addingTimeInterval(5)
        while frame == nil && Date() < deadline {
            frame = source.current(content: content,surfaceID: nil,sequence: nil,imageURL: nil,at: Date.timeIntervalSinceReferenceDate)
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(frame?.label == "video" && source.hasVideoOutput)
        #expect(player.currentItem?.outputs.count == 1)
        content.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        content.layer?.addSublayer(AVPlayerLayer(player: player))
        #expect(source.current(content: content,surfaceID: nil,sequence: nil,imageURL: nil,at: Date.timeIntervalSinceReferenceDate+1)?.label == "video")
        #expect(player.currentItem?.outputs.count == 1, "Rebuilding a leaf must keep the existing video output")
        source.stop()
        #expect(player.currentItem?.outputs.isEmpty == true)
        let view = WallpaperEffectsView(content: content,store: nil)
        view.update(settings: settings())
        for reason in ["hidden","saver","locked","unknownLock","sleep","playback","motion"] {
            var active = WallpaperEffectsActivity()
            view.applyActivity(active)
            view.renderFrame(deltaTime: 1.0/30,cursor: nil)
            #expect(player.currentItem?.outputs.count == 1)
            switch reason {
            case "hidden": active.windowVisible = false
            case "saver": active.screenSaverActive = true
            case "locked": active.sessionLocked = true
            case "unknownLock": active.sessionLocked = nil
            case "sleep": active.sleeping = true
            case "playback": active.playbackPaused = true
            default: active.reduceMotion = true
            }
            view.applyActivity(active)
            #expect(player.currentItem?.outputs.isEmpty == true && !view.isAnimating && view.status.glassReady == false)
        }
        #expect(view.window == nil)
    }

    private func pattern(width: Int,height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.02,green: 0.05,blue: 0.15,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: width,height: height))
        for x in stride(from: 0,to: width,by: 8) {
            context.setFillColor(CGColor(red: 0.9,green: 0.1,blue: 0.55,alpha: 1)); context.fill(CGRect(x: x,y: 0,width: 3,height: height))
        }
        return try #require(context.makeImage())
    }

    @MainActor private func videoFile() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Glass-\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url,fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video,outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,AVVideoWidthKey: 32,AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String: 32,kCVPixelBufferHeightKey as String: 32])
        writer.add(input); try #require(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var pixel: CVPixelBuffer?
            try #require(CVPixelBufferPoolCreatePixelBuffer(nil,try #require(adaptor.pixelBufferPool),&pixel) == kCVReturnSuccess)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer,[])
            memset(CVPixelBufferGetBaseAddress(buffer),160,CVPixelBufferGetBytesPerRow(buffer)*32)
            CVPixelBufferUnlockBaseAddress(buffer,[])
            try #require(adaptor.append(buffer,withPresentationTime: CMTime(value: Int64(i),timescale: 30)))
        }
        input.markAsFinished(); await writer.finishWriting()
        try #require(writer.status == .completed)
        return url
    }

    @MainActor private func exportScene(renderer: WallpaperGlassRainRenderer, queue: MTLCommandQueue, directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory,withIntermediateDirectories: true)
        // An optional real wallpaper path is read only for local visual verification.
        let image: CGImage
        if let path = ProcessInfo.processInfo.environment["AURAFLOW_GLASS_WALLPAPER"], let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL,nil),
           let loaded = CGImageSourceCreateImageAtIndex(source,0,nil) { image = loaded }
        else { image = try pattern(width: 1920,height: 1080) }
        let size = CGSize(width: 1920,height: 1080), rect = CGRect(origin: .zero,size: size)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,width: 1920,height: 1080,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget,.shaderRead]
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        var simulation = WallpaperGlassRainSimulation()
        var s = settings()
        for _ in 0..<600 { simulation.advance(deltaTime: 1.0/30,aspect: 16.0/9,settings: s) }
        s.rainEnabled = true; s.rainAmount = 0.7; s.rainColor = .cyan
        let rain = WallpaperRainLayer()
        var motion = WallpaperEffectsMotion()
        for _ in 0..<60 {
            motion.advance(settings: s,cursor: nil,deltaTime: 1.0/30)
            rain.render(settings: s,motion: motion,size: size,scale: 1)
        }
        let command = try #require(queue.makeCommandBuffer())
        try renderer.encode(command: command,target: target,source: .init(image: CIImage(cgImage: image),gravity: .resizeAspectFill,revision: 999,label: "artifact"),
            settings: s,size: size,contentFrame: rect,instances: simulation.instances,airRain: rain.airRainInstances)
        command.commit(); command.waitUntilCompleted()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: 1920,pixelsHigh: 1080,bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 1920*4,bitsPerPixel: 32))
        var bytes = [UInt8](repeating: 0,count: 1920*1080*4)
        target.getBytes(&bytes,bytesPerRow: 1920*4,from: MTLRegionMake2D(0,0,1920,1080),mipmapLevel: 0)
        let dst = try #require(bitmap.bitmapData)
        for p in stride(from: 0,to: bytes.count,by: 4) { dst[p]=bytes[p+2]; dst[p+1]=bytes[p+1]; dst[p+2]=bytes[p]; dst[p+3]=bytes[p+3] }
        var gpuTimes: [Double] = []
        let started = Date()
        for i in 0..<60 {
            simulation.advance(deltaTime: 1.0/30,aspect: 16.0/9,settings: s)
            let measured = try #require(queue.makeCommandBuffer())
            try renderer.encode(command: measured,target: target,
                source: .init(image: CIImage(cgImage: image),gravity: .resizeAspectFill,revision: UInt64(1000+i),label: "benchmark"),
                settings: s,size: size,contentFrame: rect,instances: simulation.instances,airRain: rain.airRainInstances)
            measured.commit(); measured.waitUntilCompleted()
            try #require(measured.status == .completed)
            gpuTimes.append((measured.gpuEndTime-measured.gpuStartTime)*1000)
        }
        print("Glass benchmark 1920x1080, 60 changing frames: GPU mean \(gpuTimes.reduce(0,+)/60) ms, max \(gpuTimes.max() ?? 0) ms; CPU+GPU wall mean \(Date().timeIntervalSince(started)*1000/60) ms")
        let overlay = try #require(bitmap.cgImage)
        let context = try #require(CGContext(data: nil,width: 1920,height: 1080,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image,in: rect); context.draw(overlay,in: rect)
        let final = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        try final.representation(using: .png,properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("rain-on-glass.png"))
    }
}
