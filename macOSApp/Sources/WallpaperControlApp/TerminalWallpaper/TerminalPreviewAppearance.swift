import AppKit
import AuraTerminalRendering
import AuraTerminalWallpaperCore
import IOSurface
import Metal
import QuartzCore
import SwiftUI

private struct TerminalPreviewMaterialKey: EnvironmentKey {
    static let defaultValue = false
}

private struct TerminalPreviewTitleKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var terminalPreviewUsesRegularGlass: Bool {
        get { self[TerminalPreviewMaterialKey.self] }
        set { self[TerminalPreviewMaterialKey.self] = newValue }
    }

    var terminalPreviewTitle: String? {
        get { self[TerminalPreviewTitleKey.self] }
        set { self[TerminalPreviewTitleKey.self] = newValue }
    }
}

/// Pure admission policy: one small readback at most each second, never for a
/// hidden window or the same frame, and never more than one GPU job in flight.
struct TerminalAppearanceSampleBudget {
    private(set) var lastFrame: String?
    private(set) var lastTime: TimeInterval = -.infinity
    private(set) var inFlight = false

    mutating func reserve(frame: String, visible: Bool, at time: TimeInterval) -> Bool {
        guard visible, !inFlight, frame != lastFrame, time - lastTime >= 1 else { return false }
        lastFrame = frame
        lastTime = time
        inFlight = true
        return true
    }

    mutating func complete() { inFlight = false }
}

@MainActor
final class TerminalPreviewAppearanceModel: ObservableObject {
    @Published private(set) var sourceKey: String?
    @Published private(set) var appearance = AdaptiveGlassAppearance.emptyState
    private var pendingTone: AdaptiveTextTone?
    private var pendingCount = 0

    static func sourceKey(configuration: TerminalWallpaperConfig?, generation: UInt64, shared: TerminalSharedFrameDescriptor?) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let configuration,
              let command = try? encoder.encode(configuration.command),
              let render = try? encoder.encode(configuration.render) else { return nil }
        return command.base64EncodedString() + render.base64EncodedString()
            + "|\(generation)|\(shared?.generation ?? "preview")"
    }

    static func fallback(for configuration: TerminalWallpaperConfig?) -> AdaptiveGlassAppearance {
        guard let render = configuration?.render else { return .emptyState }
        let color = render.background
        let luminance = (0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue) * render.backgroundOpacity
        var result = AdaptiveGlassAppearance.emptyState
        result.textTone = luminance > 0.5 ? .dark : .light
        return result
    }

    func setSource(_ key: String?, configuration: TerminalWallpaperConfig?) {
        guard sourceKey != key else { return }
        sourceKey = key
        appearance = Self.fallback(for: configuration)
        pendingTone = nil
        pendingCount = 0
    }

    func receive(_ candidate: AdaptiveGlassAppearance, source: String) {
        guard sourceKey == source else { return }
        if candidate.textTone == appearance.textTone {
            pendingTone = nil
            pendingCount = 0
            if appearance != candidate { appearance = candidate }
        } else {
            pendingCount = pendingTone == candidate.textTone ? pendingCount + 1 : 1
            pendingTone = candidate.textTone
            guard pendingCount >= 2 else { return }
            appearance = candidate
            pendingTone = nil
            pendingCount = 0
        }
    }

    static func resolved(kind: WallpaperPreviewKind, video: AdaptiveGlassAppearance,
                         terminal: AdaptiveGlassAppearance) -> AdaptiveGlassAppearance {
        kind == .terminal ? terminal : video
    }

    static func title(for command: TerminalCommandConfiguration?) -> String? {
        guard let command else { return nil }
        return TerminalWallpaperCatalog.items.first { $0.id == command.catalogItemID }?.title
            ?? URL(fileURLWithPath: command.executable).lastPathComponent
    }
}

/// Reads the preview's existing surface. It never drives the PTY or changes
/// its render configuration; both preview-only and active-agent frames use
/// the same downsampler and contrast analyzer.
struct TerminalPreviewAppearanceObserver: NSViewRepresentable {
    let sourceKey: String
    let configuration: TerminalWallpaperConfig
    let descriptor: TerminalSharedFrameDescriptor?
    let sequence: UInt64
    @ObservedObject var model: TerminalPreviewAppearanceModel

    func makeNSView(context: Context) -> TerminalAppearanceObserverView {
        TerminalAppearanceObserverView()
    }

    func updateNSView(_ view: TerminalAppearanceObserverView, context: Context) {
        view.configure(source: sourceKey, configuration: configuration, model: model)
        if let descriptor {
            view.detachRenderer()
            view.sample(descriptor: descriptor, sequence: sequence)
        } else {
            // SwiftUI attaches AppKit children after updateNSView returns.
            DispatchQueue.main.async { [weak view] in view?.attachPreviewRenderer() }
        }
    }

    static func dismantleNSView(_ view: TerminalAppearanceObserverView, coordinator: ()) {
        view.invalidate()
    }
}

@MainActor
final class TerminalAppearanceObserverView: NSView {
    private var source: String?
    private var epoch = UUID()
    private weak var model: TerminalPreviewAppearanceModel?
    private weak var renderer: TerminalMetalView?
    private var originalFrameCallback: ((TerminalSharedFrameDescriptor, UInt64) -> Void)?
    private var budget = TerminalAppearanceSampleBudget()
    private let sampler = TerminalAppearanceGPUSampler()

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(source: String, configuration: TerminalWallpaperConfig, model: TerminalPreviewAppearanceModel) {
        self.model = model
        guard self.source != source else { return }
        detachRenderer()
        self.source = source
        epoch = UUID()
        budget = TerminalAppearanceSampleBudget()
        DispatchQueue.main.async { [weak self, weak model] in
            guard self?.source == source else { return }
            // Avoid publishing ObservableObject changes during SwiftUI's
            // NSViewRepresentable update pass. The view shows its fallback
            // synchronously until this source is ready.
            model?.setSource(source, configuration: configuration)
        }
    }

    func invalidate() {
        detachRenderer()
        source = nil
        epoch = UUID()
    }

    func detachRenderer() {
        renderer?.onSharedFrame = originalFrameCallback
        renderer = nil
        originalFrameCallback = nil
    }

    func attachPreviewRenderer() {
        guard source != nil, renderer == nil, let root = window?.contentView else { return }
        func find(_ node: NSView) -> TerminalMetalView? {
            if let renderer = node as? TerminalMetalView { return renderer }
            for child in node.subviews { if let result = find(child) { return result } }
            return nil
        }
        guard let found = find(root) else { return }
        renderer = found
        originalFrameCallback = found.onSharedFrame
        let original = originalFrameCallback
        found.onSharedFrame = { [weak self] descriptor, sequence in
            original?(descriptor, sequence)
            self?.sample(descriptor: descriptor, sequence: sequence)
        }
    }

    func sample(descriptor: TerminalSharedFrameDescriptor, sequence: UInt64) {
        guard let source, let window else { return }
        let visible = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        let frame = "\(descriptor.generation):\(sequence)"
        guard budget.reserve(frame: frame, visible: visible, at: CACurrentMediaTime()) else { return }
        let epoch = self.epoch
        let accepted = sampler.sample(descriptor: descriptor, viewport: bounds.size) { [weak self] candidate in
            DispatchQueue.main.async {
                guard let self, self.epoch == epoch else { return }
                self.budget.complete()
                if let candidate { self.model?.receive(candidate, source: source) }
            }
        }
        if !accepted { budget.complete() }
    }
}

/// Only 144x90 BGRA pixels (~51 KiB) cross to the CPU, asynchronously after
/// the GPU finishes. Textures, pipeline and queue are reused across samples.
final class TerminalAppearanceGPUSampler: @unchecked Sendable {
    static let width = 144
    static let height = 90
    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let output: MTLTexture?
    private var surface: IOSurfaceRef?
    private var surfaceID: UInt32?
    private var input: MTLTexture?
    private let analysisQueue = DispatchQueue(label: "com.andrijvergeles.auraflow.terminal-contrast", qos: .utility)
    private let lock = NSLock()
    private var busy = false

    init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        queue = device?.makeCommandQueue()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: Self.width, height: Self.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        output = device?.makeTexture(descriptor: descriptor)
        if let device, let library = try? device.makeLibrary(source: Self.shader, options: nil) {
            let pipeline = MTLRenderPipelineDescriptor()
            pipeline.vertexFunction = library.makeFunction(name: "contrast_vertex")
            pipeline.fragmentFunction = library.makeFunction(name: "contrast_fragment")
            pipeline.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.pipeline = try? device.makeRenderPipelineState(descriptor: pipeline)
        } else { pipeline = nil }
    }

    func sample(descriptor: TerminalSharedFrameDescriptor, viewport: CGSize,
                completion: @escaping (AdaptiveGlassAppearance?) -> Void) -> Bool {
        lock.lock()
        guard !busy else { lock.unlock(); return false }
        busy = true
        lock.unlock()
        var submitted = false
        defer { if !submitted { finish() } }
        guard let device, let pipeline, let output, let command = queue?.makeCommandBuffer() else { return false }
        if surfaceID != descriptor.surfaceID {
            surfaceID = descriptor.surfaceID
            surface = IOSurfaceLookup(descriptor.surfaceID)
            input = nil
            if let surface {
                let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                    width: descriptor.width, height: descriptor.height, mipmapped: false)
                desc.usage = [.shaderRead]
                desc.storageMode = .shared
                input = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0)
            }
        }
        guard let input else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        let sourceAspect = Float(input.width) / Float(input.height)
        let targetAspect = Float(max(viewport.width, 1) / max(viewport.height, 1))
        var fit = SIMD2<Float>(1, 1)
        if sourceAspect > targetAspect { fit.y = targetAspect / sourceAspect }
        else { fit.x = sourceAspect / targetAspect }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&fit, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(input, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        let analysisQueue = self.analysisQueue
        command.addCompletedHandler { [self] buffer in
            guard buffer.status == .completed else { finish(); completion(nil); return }
            analysisQueue.async {
                defer { self.finish() }
                var bytes = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
                output.getBytes(&bytes, bytesPerRow: Self.width * 4,
                    from: MTLRegionMake2D(0, 0, Self.width, Self.height), mipmapLevel: 0)
                let provider = CGDataProvider(data: Data(bytes) as CFData)
                guard let provider,
                      let image = CGImage(width: Self.width, height: Self.height,
                        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Self.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                            .union(.byteOrder32Little), provider: provider, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent) else { completion(nil); return }
                completion(AdaptiveContrastAnalyzer.appearance(for: image))
            }
        }
        submitted = true
        command.commit()
        return true
    }

    private func finish() {
        lock.lock(); defer { lock.unlock() }
        busy = false
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct SampleVertex { float4 position [[position]]; float2 uv; };
    vertex SampleVertex contrast_vertex(uint id [[vertex_id]], constant float2 &fit [[buffer(0)]]) {
        const float2 p[4] = {float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1)};
        const float2 u[4] = {float2(0,1), float2(1,1), float2(0,0), float2(1,0)};
        return {float4(p[id] * fit, 0, 1), u[id]};
    }
    fragment float4 contrast_fragment(SampleVertex in [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        // Area sampling preserves sparse bright glyphs better than one point
        // per output pixel, without any full-resolution CPU readback.
        float2 d = float2(1.0/144.0, 1.0/90.0) * 0.25;
        return (image.sample(s, in.uv-d) + image.sample(s, in.uv+d)
              + image.sample(s, in.uv+float2(d.x,-d.y)) + image.sample(s, in.uv+float2(-d.x,d.y))) * 0.25;
    }
    """
}
