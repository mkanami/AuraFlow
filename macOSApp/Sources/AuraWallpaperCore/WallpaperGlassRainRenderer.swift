import AppKit
import AVFoundation
import CoreImage
import Metal
import QuartzCore
import OSLog

/// Two GPU passes: additive water normal/height map, then refracted wallpaper.
/// The transparent dry area leaves the original media renderer untouched.
@MainActor
final class WallpaperGlassRainRenderer {
    private static let logger = Logger(subsystem: "com.andrijvergeles.auraflow", category: "WallpaperGlassRain")
    let layer = CAMetalLayer()
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    private let mapPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private var water: MTLTexture?
    private var background: MTLTexture?
    private var instanceBuffer: MTLBuffer?
    private var uploadedRevision: UInt64?
    private var uploadedFrame = CGRect.zero
    private var uploadedSettings: WallpaperEffectsSettings?
    private var loggedSource: String?
    private let gate = GlassFrameGate()
    private(set) var completedFrames: UInt64 = 0
    private(set) var simulation = WallpaperGlassRainSimulation()
    private var nextFrame = -Double.infinity
    private var lastTime: Double?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let map = MTLRenderPipelineDescriptor()
            map.vertexFunction = library.makeFunction(name: "dropVertex")
            map.fragmentFunction = library.makeFunction(name: "dropMap")
            map.colorAttachments[0].pixelFormat = .rgba16Float
            let blend = map.colorAttachments[0]!
            blend.isBlendingEnabled = true
            blend.sourceRGBBlendFactor = .one; blend.destinationRGBBlendFactor = .one
            blend.sourceAlphaBlendFactor = .one; blend.destinationAlphaBlendFactor = .one
            mapPipeline = try device.makeRenderPipelineState(descriptor: map)
            let composite = MTLRenderPipelineDescriptor()
            composite.vertexFunction = library.makeFunction(name: "paneVertex")
            composite.fragmentFunction = library.makeFunction(name: "refractPane")
            composite.colorAttachments[0].pixelFormat = .bgra8Unorm
            compositePipeline = try device.makeRenderPipelineState(descriptor: composite)
        } catch {
            Self.logger.error("Glass shader unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        self.device = device; self.queue = queue
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        layer.device = device; layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false; layer.framebufferOnly = true
        layer.maximumDrawableCount = 2; layer.allowsNextDrawableTimeout = true
        layer.name = "rain-on-glass"; layer.isHidden = true
    }

    func wantsFrame(at time: Double) -> Bool { time >= nextFrame }

    func stop() {
        let hadResources = background != nil || water != nil || lastTime != nil || !layer.isHidden
        lastTime = nil; nextFrame = -.infinity
        guard hadResources else { return }
        layer.isHidden = true
        uploadedRevision = nil; loggedSource = nil
        // A submitted command retains its resources until completion.
        background = nil; water = nil; instanceBuffer = nil; uploadedSettings = nil
    }

    func render(source: WallpaperGlassFrameSource.Frame?, settings: WallpaperEffectsSettings,
                size: CGSize, contentFrame: CGRect, scale: CGFloat, at time: Double) {
        guard settings.enabled, settings.glassRainEnabled, settings.glassRainIntensity > 0,
              size.width > 0, size.height > 0, let source else {
            if !layer.isHidden { layer.isHidden = true }
            lastTime = nil; nextFrame = time + 0.1; return
        }
        guard time >= nextFrame, gate.acquire() else { return }
        nextFrame = time + 1.0 / 30 - 0.001
        let dt = lastTime.map { min(0.1, max(0, time - $0)) } ?? 0
        lastTime = time
        simulation.advance(deltaTime: dt, aspect: size.width / size.height, settings: settings)
        layer.frame = CGRect(origin: .zero, size: size)
        layer.contentsScale = scale
        let target = Self.renderSize(size: size, scale: scale)
        layer.drawableSize = target
        guard let drawable = layer.nextDrawable(), let command = queue.makeCommandBuffer() else { gate.release(); return }
        do {
            try encode(command: command, target: drawable.texture, source: source, settings: settings,
                size: size, contentFrame: contentFrame, instances: simulation.instances)
        } catch {
            layer.isHidden = true; gate.release(); return
        }
        command.present(drawable)
        let gate = gate
        command.addCompletedHandler { [weak self] buffer in
            gate.release()
            DispatchQueue.main.async {
                guard let self else { return }
                if buffer.status == .completed { self.completedFrames &+= 1 }
                else { self.layer.isHidden = true }
            }
        }
        command.commit()
        layer.isHidden = false
        if loggedSource != source.label {
            loggedSource = source.label
            Self.logger.debug("Glass refraction ready source=\(source.label, privacy: .public) size=\(Int(target.width))x\(Int(target.height))")
        }
    }

    static func renderSize(size: CGSize, scale: CGFloat) -> CGSize {
        let factor = min(max(1, scale), 1920 / max(1, max(size.width, size.height)))
        return CGSize(width: max(1, (size.width * factor).rounded()), height: max(1, (size.height * factor).rounded()))
    }

    /// Also used by GPU regressions; no NSWindow or system presentation is needed.
    func encode(command: MTLCommandBuffer, target: MTLTexture, source: WallpaperGlassFrameSource.Frame,
                settings: WallpaperEffectsSettings, size: CGSize, contentFrame: CGRect,
                instances: [WallpaperGlassRainSimulation.Instance]) throws {
        let width = target.width, height = target.height
        if water?.width != width || water?.height != height {
            let map = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            map.usage = [.renderTarget, .shaderRead]; map.storageMode = .private
            water = device.makeTexture(descriptor: map)
            let frame = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            frame.usage = [.shaderRead, .shaderWrite, .renderTarget]; frame.storageMode = .private
            background = device.makeTexture(descriptor: frame)
            uploadedRevision = nil
        }
        guard let water, let background else { throw GlassError.resource }
        if uploadedRevision != source.revision || uploadedFrame != contentFrame || uploadedSettings != settings {
            let image = Self.wallpaperImage(source: source, target: CGSize(width: width, height: height),
                size: size, contentFrame: contentFrame, settings: settings)
            context.render(image, to: background, commandBuffer: command,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            uploadedRevision = source.revision; uploadedFrame = contentFrame; uploadedSettings = settings
        }
        let byteCount = max(1, instances.count) * MemoryLayout<WallpaperGlassRainSimulation.Instance>.stride
        if (instanceBuffer?.length ?? 0) < byteCount {
            instanceBuffer = device.makeBuffer(length: max(byteCount, 1536 * 32), options: .storageModeShared)
        }
        guard let instanceBuffer else { throw GlassError.resource }
        if !instances.isEmpty {
            instances.withUnsafeBytes { bytes in
                instanceBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        var uniforms = SIMD4<Float>(Float(size.width / size.height * 1080), 1080,
            Float(settings.glassRainRefraction), Float(settings.glassRainBlur))
        let mapPass = MTLRenderPassDescriptor()
        mapPass.colorAttachments[0].texture = water
        mapPass.colorAttachments[0].loadAction = .clear; mapPass.colorAttachments[0].storeAction = .store
        mapPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: mapPass) else { throw GlassError.resource }
        encoder.label = "Glass water normal map"
        encoder.setRenderPipelineState(mapPipeline)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        if !instances.isEmpty { encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count) }
        encoder.endEncoding()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare; pass.colorAttachments[0].storeAction = .store
        guard let composite = command.makeRenderCommandEncoder(descriptor: pass) else { throw GlassError.resource }
        composite.label = "Glass wallpaper refraction"
        composite.setRenderPipelineState(compositePipeline)
        composite.setFragmentTexture(background, index: 0)
        composite.setFragmentTexture(water, index: 1)
        composite.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        composite.endEncoding()
    }

    private static func wallpaperImage(source: WallpaperGlassFrameSource.Frame, target: CGSize, size: CGSize,
                                       contentFrame: CGRect, settings: WallpaperEffectsSettings) -> CIImage {
        let extent = source.image.extent
        let sx = size.width / max(1, extent.width), sy = size.height / max(1, extent.height)
        let factor = source.gravity == .resizeAspect ? min(sx, sy) : max(sx, sy)
        let scaling = source.gravity == .resize ? CGAffineTransform(scaleX: sx, y: sy) : CGAffineTransform(scaleX: factor, y: factor)
        var image = source.image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)).transformed(by: scaling)
        image = image.transformed(by: CGAffineTransform(translationX: (size.width - image.extent.width) / 2,
            y: (size.height - image.extent.height) / 2))
        let canvas = CGRect(origin: .zero, size: size)
        image = image.composited(over: CIImage(color: .black).cropped(to: canvas)).cropped(to: canvas)
        for filter in WallpaperEffectsFilters.make(settings: settings) {
            filter.setValue(image.clampedToExtent(), forKey: kCIInputImageKey)
            image = (filter.outputImage ?? image).cropped(to: canvas)
        }
        image = image.transformed(by: CGAffineTransform(scaleX: contentFrame.width / max(1, size.width), y: contentFrame.height / max(1, size.height)))
            .transformed(by: CGAffineTransform(translationX: contentFrame.minX, y: contentFrame.minY))
            .transformed(by: CGAffineTransform(scaleX: target.width / max(1, size.width), y: target.height / max(1, size.height)))
        // CI uses a bottom-left origin; Metal UVs use a top-left origin.
        return image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: target.height))
    }

    private enum GlassError: Error { case resource }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Drop { float4 ellipse; float4 optics; };
    struct WaterVertex { float4 position [[position]]; float2 local; float strength; float angle; float trail; float radius; };
    vertex WaterVertex dropVertex(uint v [[vertex_id]], uint i [[instance_id]],
        constant Drop *drops [[buffer(0)]], constant float4 &pane [[buffer(1)]]) {
        const float2 corners[6] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
        Drop d = drops[i]; float2 q = corners[v];
        float2 p = q * d.ellipse.zw;
        float c = cos(d.optics.y), s = sin(d.optics.y);
        p = float2(c*p.x-s*p.y,s*p.x+c*p.y) + d.ellipse.xy;
        WaterVertex o; o.position = float4(p.x/pane.x*2-1,1-p.y/pane.y*2,0,1);
        o.local=q; o.strength=d.optics.x; o.angle=d.optics.y; o.trail=d.optics.z; o.radius=d.ellipse.z; return o;
    }
    fragment float4 dropMap(WaterVertex in [[stage_in]]) {
        float2 q=in.local;
        if(in.trail>1.5f) q.x/=mix(0.70f,1.02f,smoothstep(-1.0f,1.0f,q.y));
        float r2 = dot(q,q); if(r2>=1) discard_fragment();
        float h = sqrt(max(0.0f,1-r2));
        float edge = 1-smoothstep(0.78f,1.0f,sqrt(r2));
        float2 n = -q*(0.35f+0.65f*h);
        float c=cos(in.angle),s=sin(in.angle); n=float2(c*n.x-s*n.y,s*n.x+c*n.y);
        return float4(n*in.strength*in.radius,h*in.strength,edge*in.strength);
    }
    struct PaneVertex { float4 position [[position]]; float2 uv; };
    vertex PaneVertex paneVertex(uint v [[vertex_id]]) {
        float2 p=float2((v<<1)&2,v&2); PaneVertex o;
        o.position=float4(p*2-1,0,1); o.uv=float2(p.x,1-p.y); return o;
    }
    fragment float4 refractPane(PaneVertex in [[stage_in]], texture2d<float> background [[texture(0)]],
        texture2d<float> water [[texture(1)]], constant float4 &pane [[buffer(0)]]) {
        constexpr sampler linearSampler(coord::normalized,address::clamp_to_edge,filter::linear);
        float4 wet=water.sample(linearSampler,in.uv);
        float alpha=min(0.97f,wet.a*0.92f); if(alpha<0.001f) return float4(0);
        float2 pixel=1.0f/float2(background.get_width(),background.get_height());
        float2 normal=wet.rg/max(1.0f,length(wet.rg));
        float2 offset=clamp(wet.rg,float2(-24),float2(24))*1.6f*pane.z*(float(background.get_height())/1080.0f)*pixel;
        float2 uv=in.uv+offset;
        float radius=pane.w*6;
        float3 color=background.sample(linearSampler,uv).rgb*0.4f;
        color+=background.sample(linearSampler,uv+float2(pixel.x,0)*radius).rgb*0.15f;
        color+=background.sample(linearSampler,uv-float2(pixel.x,0)*radius).rgb*0.15f;
        color+=background.sample(linearSampler,uv+float2(0,pixel.y)*radius).rgb*0.15f;
        color+=background.sample(linearSampler,uv-float2(0,pixel.y)*radius).rgb*0.15f;
        float rim=pow(max(0.0f,dot(normalize(float3(normal,0.6f)),normalize(float3(-0.6f,-0.8f,0.2f)))),18.0f);
        // Subtle clear-water edge; background supplies the color, never a white cursor streak.
        color=color*(1-min(0.1f,wet.b*0.045f))+float3(0.72f,0.84f,1.0f)*rim*0.22f;
        return float4(color*alpha,alpha);
    }
    """
}

/// The completion callback runs on a Metal thread; permit only one frame in flight.
private final class GlassFrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    func acquire() -> Bool { lock.lock(); defer { lock.unlock() }; guard !busy else { return false }; busy = true; return true }
    func release() { lock.lock(); busy = false; lock.unlock() }
}
