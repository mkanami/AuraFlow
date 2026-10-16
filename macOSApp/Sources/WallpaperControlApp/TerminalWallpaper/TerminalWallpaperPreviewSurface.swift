import AppKit
import AuraTerminalRendering
import AuraTerminalWallpaperCore
import Combine
import CoreText
import IOSurface
import Metal
import MetalKit
import SwiftUI

struct TerminalWallpaperPreviewSurface: View {
    let model: TerminalWallpaperPreviewModel
    @StateObject private var presentation: TerminalPreviewPresentationModel

    init(model: TerminalWallpaperPreviewModel) {
        self.model = model
        _presentation = StateObject(wrappedValue: TerminalPreviewPresentationModel(model: model))
    }

    var body: some View {
        ZStack {
            let render = presentation.state.configuration?.render ?? TerminalRenderConfiguration()
            Color(red: render.background.red * render.backgroundOpacity,
                  green: render.background.green * render.backgroundOpacity,
                  blue: render.background.blue * render.backgroundOpacity)
            if presentation.state.hasSharedFrame {
                TerminalIOSurfacePreview(model: model)
            } else if presentation.state.hasSnapshot, let configuration = presentation.state.configuration {
                TerminalSnapshotPreview(model: model, configuration: configuration)
                    .id(presentation.state.generation)
            } else if let previewError = presentation.state.error {
                VStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .font(.system(size: 36, weight: .regular))
                    Text(previewError)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding(24)
            }
        }
        // Window resizing scales the existing canvas, like image/video previews.
        // It must not expand the PTY and expose blank, not-yet-painted cells.
        .clipped()
    }
}

/// Only structural changes enter SwiftUI. Animation frames go straight to the
/// existing AppKit/Metal leaf, leaving scrolling and window layout out of that path.
@MainActor
final class TerminalPreviewPresentationModel: ObservableObject {
    struct State: Equatable {
        var configuration: TerminalWallpaperConfig?
        var hasSharedFrame: Bool
        var hasSnapshot: Bool
        var error: String?
        var generation: UInt64
    }

    @Published private(set) var state: State
    private var observation: AnyCancellable?

    init(model: TerminalWallpaperPreviewModel) {
        state = State(configuration: model.configuration, hasSharedFrame: model.sharedFrame != nil,
            hasSnapshot: model.snapshot != nil, error: model.previewError, generation: model.previewGeneration)
        observation = Publishers.CombineLatest3(model.$configuration, model.$previewError, model.$previewGeneration)
            .combineLatest(model.$sharedFrame.map { $0 != nil }.removeDuplicates(),
                           model.$snapshot.map { $0 != nil }.removeDuplicates())
            .map { values, shared, snapshot in
                State(configuration: values.0, hasSharedFrame: shared, hasSnapshot: snapshot,
                      error: values.1, generation: values.2)
            }
            .removeDuplicates()
            .sink { [weak self] state in
                guard self?.state != state else { return }
                self?.state = state
            }
    }
}

private struct TerminalIOSurfacePreview: NSViewRepresentable {
    let model: TerminalWallpaperPreviewModel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalIOSurfacePreviewView {
        let view = TerminalIOSurfacePreviewView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        context.coordinator.attach(model, to: view)
        return view
    }

    func updateNSView(_ view: TerminalIOSurfacePreviewView, context: Context) {
        context.coordinator.attach(model, to: view)
    }

    static func dismantleNSView(_ view: TerminalIOSurfacePreviewView, coordinator: Coordinator) {
        coordinator.observation = nil
    }

    @MainActor final class Coordinator {
        weak var model: TerminalWallpaperPreviewModel?
        var observation: AnyCancellable?

        func attach(_ model: TerminalWallpaperPreviewModel, to view: TerminalIOSurfacePreviewView) {
            guard self.model !== model else { return }
            self.model = model
            observation = Publishers.CombineLatest3(model.$sharedFrame, model.$frameSequence, model.$configuration)
                .sink { [weak view] descriptor, sequence, configuration in
                    guard let view, let descriptor else { return }
                    let render = configuration?.render ?? TerminalRenderConfiguration()
                    view.clearColor = MTLClearColor(red: render.background.red * render.backgroundOpacity,
                        green: render.background.green * render.backgroundOpacity,
                        blue: render.background.blue * render.backgroundOpacity, alpha: 1)
                    view.display(descriptor: descriptor, sequence: sequence, scaleMode: render.scaleMode)
                }
        }
    }
}

final class TerminalIOSurfacePreviewView: MTKView {
    private let renderPipeline: MTLRenderPipelineState?
    private let commandQueue: MTLCommandQueue?
    private var surface: IOSurfaceRef?
    private var sourceTexture: MTLTexture?
    private var descriptor: TerminalSharedFrameDescriptor?
    private(set) var lastSequence: UInt64 = 0
    private var scaleMode: TerminalScaleMode = .fill

    override init(frame: CGRect, device: MTLDevice?) {
        let resolvedDevice = device ?? MTLCreateSystemDefaultDevice()
        commandQueue = resolvedDevice?.makeCommandQueue()
        if let resolvedDevice,
           let library = try? resolvedDevice.makeLibrary(source: Self.shader, options: nil),
           let vertex = library.makeFunction(name: "preview_vertex"),
           let fragment = library.makeFunction(name: "preview_fragment") {
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertex
            pipelineDescriptor.fragmentFunction = fragment
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            renderPipeline = try? resolvedDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } else {
            renderPipeline = nil
        }
        super.init(frame: frame, device: resolvedDevice)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        colorPixelFormat = .bgra8Unorm
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(descriptor newDescriptor: TerminalSharedFrameDescriptor, sequence: UInt64,
                 scaleMode newMode: TerminalScaleMode) {
        let descriptorChanged = descriptor != newDescriptor
        let modeChanged = scaleMode != newMode
        scaleMode = newMode
        if descriptor != newDescriptor {
            descriptor = newDescriptor
            surface = IOSurfaceLookup(newDescriptor.surfaceID)
            if let surface, let device {
                let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: newDescriptor.width,
                    height: newDescriptor.height,
                    mipmapped: false
                )
                textureDescriptor.usage = [.shaderRead]
                textureDescriptor.storageMode = .shared
                sourceTexture = device.makeTexture(
                    descriptor: textureDescriptor,
                    iosurface: surface,
                    plane: 0
                )
            } else {
                sourceTexture = nil
            }
        }
        guard sequence != lastSequence || descriptorChanged || modeChanged else { return }
        lastSequence = sequence
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true // Static output must also adapt when resized.
    }

    override func draw(_ rect: NSRect) {
        guard let drawable = currentDrawable,
              let renderPipeline,
              let sourceTexture,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass(for: drawable))
        else { return }
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        let presentation = TerminalRenderGeometry.presentationScale(
            sourceWidth: sourceTexture.width, sourceHeight: sourceTexture.height,
            targetWidth: drawable.texture.width, targetHeight: drawable.texture.height, mode: scaleMode)
        var scale = SIMD2<Float>(Float(presentation.x), Float(presentation.y))
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func renderPass(for drawable: CAMetalDrawable) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        return pass
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct PreviewVertex { float4 position [[position]]; float2 uv; };
    vertex PreviewVertex preview_vertex(uint index [[vertex_id]], const device float2 *scale [[buffer(0)]]) {
        const float2 positions[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
        const float2 coordinates[4] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };
        PreviewVertex out;
        out.position = float4(positions[index] * scale[0], 0, 1);
        out.uv = coordinates[index];
        return out;
    }
    fragment float4 preview_fragment(PreviewVertex input [[stage_in]], texture2d<float> frame [[texture(0)]]) {
        constexpr sampler frameSampler(filter::linear, address::clamp_to_edge);
        return frame.sample(frameSampler, input.uv);
    }
    """
}

private struct TerminalSnapshotPreview: NSViewRepresentable {
    let model: TerminalWallpaperPreviewModel
    let configuration: TerminalWallpaperConfig

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        guard let device = MTLCreateSystemDefaultDevice(), let snapshot = model.snapshot else { return NSView() }
        let view = TerminalMetalView(
            frame: .zero,
            logicalSize: Self.sourceSize(snapshot: snapshot, render: configuration.render),
            device: device
        )
        context.coordinator.attach(model, to: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let view = view as? TerminalMetalView { context.coordinator.attach(model, to: view) }
    }

    static func update(_ view: TerminalMetalView, snapshot: TerminalGridSnapshot, configuration: TerminalWallpaperConfig) {
        // The renderer presents the full source canvas using the selected mode.
        let render = TerminalWallpaperCanvas.renderConfiguration(
            command: configuration.command, render: configuration.render, snapshot: snapshot)
        let background = TerminalRGBA(red: configuration.render.background.red * configuration.render.backgroundOpacity,
            green: configuration.render.background.green * configuration.render.backgroundOpacity,
            blue: configuration.render.background.blue * configuration.render.backgroundOpacity)
        view.update(snapshot: snapshot, configuration: render, presentationBackground: background)
    }

    static func sourceSize(snapshot: TerminalGridSnapshot, render: TerminalRenderConfiguration) -> CGSize {
        if render.pixelMode == .fixed {
            return CGSize(width: render.fixedWidth ?? 1920, height: render.fixedHeight ?? 1080)
        }
        let metrics = TerminalFontMetrics.cellMetrics(for: render)
        return CGSize(width: Double(snapshot.columns) * metrics.width, height: Double(snapshot.rows) * metrics.height)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.observation = nil
        (view as? TerminalMetalView)?.setRendererPaused(true)
    }

    @MainActor final class Coordinator {
        weak var model: TerminalWallpaperPreviewModel?
        var observation: AnyCancellable?

        func attach(_ model: TerminalWallpaperPreviewModel, to view: TerminalMetalView) {
            guard self.model !== model else { return }
            self.model = model
            observation = model.$snapshot.combineLatest(model.$configuration)
                .sink { [weak view] snapshot, configuration in
                    guard let view, let snapshot, let configuration else { return }
                    TerminalSnapshotPreview.update(view, snapshot: snapshot, configuration: configuration)
                }
        }
    }
}
