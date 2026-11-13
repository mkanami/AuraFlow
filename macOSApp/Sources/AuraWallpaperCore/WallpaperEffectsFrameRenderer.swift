import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import Metal
import QuartzCore

/// Renders the shared Desktop layers and glass shader into encoder buffers.
/// No window, screen capture, or system presentation is involved.
@MainActor final class WallpaperEffectsFrameRenderer {
    let size: CGSize
    let device: MTLDevice
    let context: CIContext
    private let queue: MTLCommandQueue
    private let settings: WallpaperEffectsSettings
    private let root = CALayer()
    private let content = CALayer()
    private let overlay = WallpaperEffectsOverlay()
    private var motion = WallpaperEffectsMotion()
    private var simulation = WallpaperGlassRainSimulation()
    private let glass: WallpaperGlassRainRenderer?
    private let glassTarget: MTLTexture?
    private let blend: MTLRenderPipelineState
    private var cache: CVMetalTextureCache!
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var revision: UInt64 = 0
    private(set) var rainCount = 0
    private(set) var dropCount = 0

    init(size: CGSize, settings: WallpaperEffectsSettings) throws {
        self.size = size
        var ambient = settings.normalized()
        // A native movie has no pointer input. Use the same gentle ambient
        // motion as the Desktop's cursor-independent setting.
        ambient.reactsToCursor = false
        self.settings = ambient
        glass = ambient.enabled && ambient.glassRainEnabled && ambient.glassRainIntensity > 0 ? WallpaperGlassRainRenderer() : nil
        guard let device = glass?.device ?? MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw AerialLockScreenInstallerError.aerialVideoPreparationFailed("Metal is unavailable.")
        }
        self.device = device; self.queue = queue
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 p [[position]]; float2 uv; };
        vertex V wallpaperQuad(uint i [[vertex_id]]) {
            const float2 p[4]={float2(-1,1),float2(1,1),float2(-1,-1),float2(1,-1)};
            V v; v.p=float4(p[i],0,1); v.uv=float2((p[i].x+1)*.5,(1-p[i].y)*.5); return v;
        }
        fragment float4 water(V v [[stage_in]], texture2d<float> image [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge); return image.sample(s,v.uv);
        }
        """, options: nil)
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = library.makeFunction(name: "wallpaperQuad")
        pipeline.fragmentFunction = library.makeFunction(name: "water")
        let attachment = pipeline.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm; attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one; attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one; attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        blend = try device.makeRenderPipelineState(descriptor: pipeline)
        if glass != nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: Int(size.width), height: Int(size.height), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            glassTarget = device.makeTexture(descriptor: descriptor)
        } else { glassTarget = nil }
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw AerialLockScreenInstallerError.aerialVideoPreparationFailed("Could not create the video texture cache.")
        }
        root.frame = CGRect(origin: .zero, size: size); root.masksToBounds = true
        root.backgroundColor = NSColor.black.cgColor
        content.contentsGravity = .resize; content.contentsScale = 1
        root.addSublayer(content); root.addSublayer(overlay)
        for _ in 0..<30 { motion.advance(settings: ambient, cursor: nil, deltaTime: 1.0/30) }
    }

    func render(image: CIImage, into buffer: CVPixelBuffer, deltaTime: Double, scaleMode: WallpaperScaleMode) throws {
        revision &+= 1
        let viewport = CGRect(origin: .zero, size: size)
        let base = Self.fit(image, to: size, mode: scaleMode)
        var filtered = base
        for filter in WallpaperEffectsFilters.make(settings: settings) {
            filter.setValue(filtered.clampedToExtent(), forKey: kCIInputImageKey)
            if let output = filter.outputImage { filtered = output.cropped(to: viewport) }
        }
        guard let image = context.createCGImage(filtered, from: viewport, format: .BGRA8, colorSpace: colorSpace) else {
            throw AerialLockScreenInstallerError.aerialVideoPreparationFailed("Could not render the wallpaper frame.")
        }
        motion.advance(settings: settings, cursor: nil, deltaTime: deltaTime)
        if revision == 1 || revision.isMultiple(of: 60) {
            let tiny = base.transformed(by: CGAffineTransform(scaleX: 8/size.width, y: 4/size.height))
            if let sample = context.createCGImage(tiny, from: CGRect(x: 0, y: 0, width: 8, height: 4)),
               let lighting = WallpaperRainLighting.analyze(sample) { overlay.rainLighting = lighting }
        }
        let frame = motion.contentFrame(in: size, settings: settings)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.frame = frame; content.contents = image
        overlay.render(settings: settings, motion: motion, size: size, scale: 1)
        overlay.isHidden = !settings.hasAnimatedEffects
        overlay.setRainComposited(glass != nil)
        CATransaction.commit(); CATransaction.flush()
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let bitmap = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            throw AerialLockScreenInstallerError.aerialVideoPreparationFailed("Could not compose the encoder frame.")
        }
        root.render(in: bitmap)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var reference: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm,
            Int(size.width), Int(size.height), 0, &reference) == kCVReturnSuccess,
              let reference, let texture = CVMetalTextureGetTexture(reference) else {
            throw AerialLockScreenInstallerError.aerialVideoPreparationFailed("Could not access the encoder frame.")
        }
        guard let command = queue.makeCommandBuffer() else { throw CancellationError() }
        if let glass, let glassTarget {
            simulation.advance(deltaTime: deltaTime, aspect: size.width/size.height, settings: settings)
            let air = overlay.airRainInstances
            try glass.encode(command: command, target: glassTarget,
                source: .init(image: base, gravity: .resize, revision: revision, label: "native-lock-screen"),
                settings: settings, size: size, contentFrame: frame, instances: simulation.instances, airRain: air)
            rainCount = air.count; dropCount = simulation.beads.count + simulation.runners.count
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .load; pass.colorAttachments[0].storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw CancellationError() }
            encoder.setRenderPipelineState(blend); encoder.setFragmentTexture(glassTarget, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4); encoder.endEncoding()
        }
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        withExtendedLifetime(reference) {}
    }

    static func fit(_ image: CIImage, to size: CGSize, mode: WallpaperScaleMode) -> CIImage {
        let source = image.extent
        let sx = size.width/source.width, sy = size.height/source.height
        let x: CGFloat, y: CGFloat
        switch mode {
        case .stretch: x = sx; y = sy
        case .fit: x = min(sx,sy); y = x
        case .fill: x = max(sx,sy); y = x
        }
        let transformed = image.transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
            .transformed(by: CGAffineTransform(scaleX: x, y: y))
            .transformed(by: CGAffineTransform(translationX: (size.width-source.width*x)/2, y: (size.height-source.height*y)/2))
        let rect = CGRect(origin: .zero, size: size)
        return transformed.composited(over: CIImage(color: .black).cropped(to: rect)).cropped(to: rect)
    }
}
