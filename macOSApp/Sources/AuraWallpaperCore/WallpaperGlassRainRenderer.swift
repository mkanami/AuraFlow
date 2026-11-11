import AppKit
import AVFoundation
import CoreImage
import Metal
import QuartzCore
import OSLog

/// Falling rain, water normal map, then a shared refracted scene.
/// The transparent dry area leaves the original media renderer untouched.
@MainActor
final class WallpaperGlassRainRenderer {
    private static let logger = Logger(subsystem: "com.andrijvergeles.auraflow", category: "WallpaperGlassRain")
    let layer = CAMetalLayer()
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let context: CIContext
    private let mapPipeline: MTLRenderPipelineState
    private let airPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private var water: MTLTexture?
    private var airTexture: MTLTexture?
    private var airBuffer: MTLBuffer?
    private(set) var composedRainCount = 0
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
            let air = MTLRenderPipelineDescriptor()
            air.vertexFunction = library.makeFunction(name: "airRainVertex")
            air.fragmentFunction = library.makeFunction(name: "airRainFragment")
            air.colorAttachments[0].pixelFormat = .bgra8Unorm
            air.colorAttachments[0].isBlendingEnabled = true
            air.colorAttachments[0].sourceRGBBlendFactor = .one
            air.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            air.colorAttachments[0].sourceAlphaBlendFactor = .one
            air.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            airPipeline = try device.makeRenderPipelineState(descriptor: air)
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
        background = nil; water = nil; airTexture = nil; airBuffer = nil; composedRainCount = 0
        instanceBuffer = nil; uploadedSettings = nil
    }

    func render(source: WallpaperGlassFrameSource.Frame?, settings: WallpaperEffectsSettings,
                size: CGSize, contentFrame: CGRect, scale: CGFloat, at time: Double, airRain: [WallpaperAirRainInstance] = []) {
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
        let layerFrame = CGRect(origin: .zero, size: size)
        if layer.frame != layerFrame { layer.frame = layerFrame }
        if layer.contentsScale != scale { layer.contentsScale = scale }
        let target = Self.renderSize(size: size, scale: scale)
        if layer.drawableSize != target { layer.drawableSize = target }
        guard let drawable = layer.nextDrawable(), let command = queue.makeCommandBuffer() else { gate.release(); return }
        do {
            try encode(command: command, target: drawable.texture, source: source, settings: settings,
                size: size, contentFrame: contentFrame, instances: simulation.instances, airRain: airRain)
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
                instances: [WallpaperGlassRainSimulation.Instance], airRain: [WallpaperAirRainInstance] = []) throws {
        let width = target.width, height = target.height
        if water?.width != width || water?.height != height {
            let map = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            map.usage = [.renderTarget, .shaderRead]; map.storageMode = .private
            water = device.makeTexture(descriptor: map)
            let frame = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            frame.usage = [.shaderRead, .shaderWrite, .renderTarget]; frame.storageMode = .private
            background = device.makeTexture(descriptor: frame)
            airTexture = device.makeTexture(descriptor: frame)
            uploadedRevision = nil
        }
        guard let water, let background, let airTexture else { throw GlassError.resource }
        if uploadedRevision != source.revision || uploadedFrame != contentFrame || uploadedSettings != settings {
            let image = Self.wallpaperImage(source: source, target: CGSize(width: width, height: height),
                size: size, contentFrame: contentFrame, settings: settings)
            context.render(image, to: background, commandBuffer: command,
                bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            uploadedRevision = source.revision; uploadedFrame = contentFrame; uploadedSettings = settings
        }
        let byteCount = max(1, instances.count) * MemoryLayout<WallpaperGlassRainSimulation.Instance>.stride
        if (instanceBuffer?.length ?? 0) < byteCount {
            instanceBuffer = device.makeBuffer(length: max(byteCount, 2048 * MemoryLayout<WallpaperGlassRainSimulation.Instance>.stride), options: .storageModeShared)
        }
        guard let instanceBuffer else { throw GlassError.resource }
        if !instances.isEmpty {
            instances.withUnsafeBytes { bytes in
                instanceBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        var uniforms = SIMD4<Float>(Float(size.width / size.height * 1080), 1080,
            Float(settings.glassRainRefraction), Float(settings.glassRainBlur))
        let rain = settings.rainEnabled && settings.rainAmount > 0 ? airRain : []
        let rainBytes = max(1, rain.count) * MemoryLayout<WallpaperAirRainInstance>.stride
        if (airBuffer?.length ?? 0) < rainBytes {
            airBuffer = device.makeBuffer(length: max(rainBytes, 512 * 48), options: .storageModeShared)
        }
        guard let airBuffer else { throw GlassError.resource }
        if !rain.isEmpty {
            rain.withUnsafeBytes { airBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        }
        let airPass = MTLRenderPassDescriptor()
        airPass.colorAttachments[0].texture = airTexture
        airPass.colorAttachments[0].loadAction = .clear; airPass.colorAttachments[0].storeAction = .store
        airPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let airEncoder = command.makeRenderCommandEncoder(descriptor: airPass) else { throw GlassError.resource }
        airEncoder.label = "Falling rain behind the wet glass"
        airEncoder.setRenderPipelineState(airPipeline)
        airEncoder.setVertexBuffer(airBuffer, offset: 0, index: 0)
        airEncoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        if !rain.isEmpty { airEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: rain.count) }
        airEncoder.endEncoding()
        composedRainCount = rain.count
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
        composite.setFragmentTexture(airTexture, index: 2)
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
    struct Drop { float4 ellipse; float4 optics; float4 shape; };
    struct WaterVertex { float4 position [[position]]; float2 local; float strength; float angle; float trail; float radius; float length; float seed; float4 shape; };
    vertex WaterVertex dropVertex(uint v [[vertex_id]], uint i [[instance_id]],
        constant Drop *drops [[buffer(0)]], constant float4 &pane [[buffer(1)]]) {
        const float2 corners[6] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
        Drop d = drops[i]; float2 q = corners[v];
        float2 p = q * d.ellipse.zw;
        float c = cos(d.optics.y), s = sin(d.optics.y);
        p = float2(c*p.x-s*p.y,s*p.x+c*p.y) + d.ellipse.xy;
        WaterVertex o; o.position = float4(p.x/pane.x*2-1,1-p.y/pane.y*2,0,1);
        o.local=q; o.strength=d.optics.x; o.angle=d.optics.y; o.trail=d.optics.z; o.radius=d.ellipse.z/(d.shape.z>0?1.28f:1.0f); o.length=d.ellipse.w; o.seed=d.optics.w; o.shape=d.shape; return o;
    }
    fragment float4 dropMap(WaterVertex in [[stage_in]]) {
        float2 q=in.local;
        float2 n; float h; float edge;
        if((in.trail>0.5f && in.trail<1.5f) || in.trail>3.5f) {
            if(in.trail>3.5f) q.x/=mix(0.42f,1.0f,smoothstep(0.0f,0.9f,abs(q.y)));
            // A capsule's straight middle joins neighboring water segments without beads.
            float2 p=q*float2(in.radius,in.length);
            float2 cap=float2(p.x,sign(p.y)*max(0.0f,abs(p.y)-max(0.0f,in.length-in.radius)));
            float r=length(cap)/max(0.1f,in.radius);
            if(r>=1) discard_fragment();
            h=sqrt(max(0.0f,1-r*r)); edge=1-smoothstep(0.65f,1.0f,r);
            n=-cap/max(0.1f,in.radius)*(0.35f+0.65f*h);
        } else {
            // Each contact patch has its own fixed asymmetry and lobes. Padding
            // contains its full outline, so irregular beads never get clipped flat.
            if(in.shape.z>0) {
                q*=1.28f;
                q.x+=in.shape.y*q.y+sin(in.shape.x)*q.y*q.y*0.06f;
                float angle=atan2(q.y,q.x);
                float boundary=1+cos(angle*2+in.shape.x)*0.075f
                    +sin(angle*3-in.shape.x*0.7f)*in.shape.z+cos(angle+in.shape.x)*0.04f;
                q/=boundary;
            }
            // A continuous neck/shoulder response replaces the abrupt circle-to-teardrop switch.
            float flow=in.trail>1.5f?clamp(in.shape.w,0.0f,1.0f):0.0f;
            if(in.trail>2.5f) {
                // The attached lobe stretches a narrowing neck toward the receiver.
                q.x/=mix(1+0.06f*flow,1-0.65f*flow,smoothstep(-0.6f,0.9f,q.y));
            } else {
                q.x/=mix(1-0.38f*flow,1+0.04f*flow,smoothstep(-0.9f,0.6f,q.y));
            }
            float r2=dot(q,q); if(r2>=1) discard_fragment();
            h=sqrt(max(0.0f,1-r2)); edge=1-smoothstep(0.84f,1.0f,sqrt(r2));
            n=-q*(0.3f+0.7f*h);
        }
        float c=cos(in.angle),s=sin(in.angle); n=float2(c*n.x-s*n.y,s*n.x+c*n.y);
        return float4(n*in.strength*in.radius,h*in.strength,edge*in.strength);
    }
    struct AirDrop { float4 ellipse; float4 color; float4 optics; };
    struct AirVertex { float4 position [[position]]; float2 q; float4 color; float3 optics; };
    vertex AirVertex airRainVertex(uint v [[vertex_id]], uint i [[instance_id]],
        constant AirDrop *rain [[buffer(0)]], constant float4 &pane [[buffer(1)]]) {
        const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
        AirDrop d=rain[i]; float2 q=corners[v], p=q*d.ellipse.zw;
        float c=cos(d.optics.x),s=sin(d.optics.x);
        p=float2(c*p.x-s*p.y,s*p.x+c*p.y)+d.ellipse.xy;
        AirVertex o; o.position=float4(p.x/pane.x*2-1,1-p.y/pane.y*2,0,1);
        o.q=q; o.color=d.color; o.optics=d.optics.yzw; return o;
    }
    fragment float4 airRainFragment(AirVertex in [[stage_in]]) {
        float y=in.q.y/max(0.001f,in.optics.y);
        if(abs(y)>=1) return float4(0);
        float t=(y+1)*0.5f;
        float longitudinal=pow(sin(M_PI_F*t),0.7f);
        float taper=0.72f+0.28f*sin(M_PI_F*t);
        float x=in.q.x/max(0.001f,in.optics.x)/taper;
        float profile=exp(-x*x*2.6f)*0.9f+exp(-x*x/(1+in.optics.z*3))*in.optics.z*0.16f;
        float a=min(0.96f,profile*longitudinal)*in.color.a;
        return float4(in.color.rgb*a,a);
    }
    struct PaneVertex { float4 position [[position]]; float2 uv; };
    vertex PaneVertex paneVertex(uint v [[vertex_id]]) {
        float2 p=float2((v<<1)&2,v&2); PaneVertex o;
        o.position=float4(p*2-1,0,1); o.uv=float2(p.x,1-p.y); return o;
    }
    fragment float4 refractPane(PaneVertex in [[stage_in]], texture2d<float> background [[texture(0)]],
        texture2d<float> water [[texture(1)]], texture2d<float> rain [[texture(2)]], constant float4 &pane [[buffer(0)]]) {
        constexpr sampler linearSampler(coord::normalized,address::clamp_to_edge,filter::linear);
        float4 wet=water.sample(linearSampler,in.uv);
        // Lighting needs the curved surface slope, not a normalized XY direction:
        // the latter creates a bright triangular sector across the whole drop.
        float3 surfaceNormal=normalize(float3(-dfdx(wet.b)*8,-dfdy(wet.b)*8,0.5f));
        float alpha=min(0.98f,wet.a*0.97f);
        float4 dryRain=rain.sample(linearSampler,in.uv);
        if(alpha<0.001f) return dryRain;
        float2 pixel=1.0f/float2(background.get_width(),background.get_height());
        float2 offset=clamp(wet.rg,float2(-24),float2(24))*1.6f*pane.z*(float(background.get_height())/1080.0f)*pixel;
        float2 uv=in.uv+offset;
        float radius=pane.w*6;
        // Rain and wallpaper are sampled together at the refracted coordinates.
        // Sampling only the wallpaper would paint over, rather than refract, the storm.
        float3 color=float3(0);
        const float2 taps[5]={float2(0),float2(1,0),float2(-1,0),float2(0,1),float2(0,-1)};
        for(uint i=0;i<5;i++) {
            float2 at=uv+taps[i]*pixel*radius;
            float4 airborne=rain.sample(linearSampler,at);
            float3 scene=background.sample(linearSampler,at).rgb*(1-airborne.a)+airborne.rgb;
            color+=scene*(i==0?0.4f:0.15f);
        }
        float rim=pow(max(0.0f,dot(surfaceNormal,normalize(float3(-0.55f,-0.7f,0.6f)))),36.0f);
        // A bright upper meniscus and shaded lower edge keep clear water visible
        // on both dark and light artwork. Fade the band before the flat center;
        // thin trails retain their own, quieter refraction instead of a white wire.
        float meniscus=smoothstep(0.08f,0.3f,wet.b)*(1-smoothstep(0.55f,0.88f,wet.b));
        float beadPresence=smoothstep(0.45f,0.8f,wet.a);
        float lowerArc=smoothstep(-0.1f,0.65f,surfaceNormal.y);
        float upperArc=smoothstep(-0.1f,0.65f,-surfaceNormal.y);
        float shade=meniscus*beadPresence*(0.1f+lowerArc*0.26f);
        float edgeLight=meniscus*beadPresence*(0.035f+upperArc*0.2f);
        color=color*(1-shade)+float3(0.78f,0.88f,1.0f)*(edgeLight+rim*0.3f);
        return float4(color*alpha+dryRain.rgb*(1-alpha),alpha+dryRain.a*(1-alpha));
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
