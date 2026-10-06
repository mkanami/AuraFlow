import AppKit
import AuraTerminalRendering
import AuraTerminalWallpaperCore
import CoreText
import IOSurface
import Metal
import MetalKit
import SwiftUI

struct TerminalWallpaperPreviewSurface: View {
    @ObservedObject var model: TerminalWallpaperPreviewModel

    var body: some View {
        ZStack {
            let render = model.configuration?.render ?? TerminalRenderConfiguration()
            Color(red: render.background.red * render.backgroundOpacity,
                  green: render.background.green * render.backgroundOpacity,
                  blue: render.background.blue * render.backgroundOpacity)
            if let sharedFrame = model.sharedFrame {
                TerminalIOSurfacePreview(descriptor: sharedFrame, sequence: model.frameSequence,
                    scaleMode: model.configuration?.render.scaleMode ?? .fill)
                    .padding(8) // Keep glyphs inside the window's rounded corners.
            } else if let snapshot = model.snapshot, let configuration = model.configuration {
                GeometryReader { viewport in
                    TerminalSnapshotPreview(snapshot: snapshot, configuration: configuration)
                        .id(model.previewGeneration)
                        .aspectRatio(TerminalSnapshotPreview.sourceSize(snapshot: snapshot, render: configuration.render),
                                     contentMode: configuration.render.scaleMode == .fill ? .fill : .fit)
                        .frame(width: viewport.size.width, height: viewport.size.height)
                        .clipped()
                }
                .padding(8)
            } else if let previewError = model.previewError {
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

private struct TerminalIOSurfacePreview: NSViewRepresentable {
    let descriptor: TerminalSharedFrameDescriptor
    let sequence: UInt64
    let scaleMode: TerminalScaleMode

    func makeNSView(context: Context) -> TerminalIOSurfacePreviewView {
        TerminalIOSurfacePreviewView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    }

    func updateNSView(_ view: TerminalIOSurfacePreviewView, context: Context) {
        view.display(descriptor: descriptor, sequence: sequence, scaleMode: scaleMode)
    }
}

private final class TerminalIOSurfacePreviewView: MTKView {
    private let renderPipeline: MTLRenderPipelineState?
    private let commandQueue: MTLCommandQueue?
    private var surface: IOSurfaceRef?
    private var sourceTexture: MTLTexture?
    private var descriptor: TerminalSharedFrameDescriptor?
    private var lastSequence: UInt64 = 0
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
        // Preview never distorts cells, including a user-selected Stretch.
        let previewMode: TerminalScaleMode = newMode == .stretch ? .fit : newMode
        let modeChanged = scaleMode != previewMode
        scaleMode = previewMode
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
        let presentation = TerminalRenderGeometry.scaleFactors(
            contentWidth: Double(sourceTexture.width), contentHeight: Double(sourceTexture.height),
            targetWidth: Double(drawable.texture.width), targetHeight: Double(drawable.texture.height), mode: scaleMode)
        var scale = SIMD2<Float>(
            Float(Double(sourceTexture.width) * presentation.x / Double(drawable.texture.width)),
            Float(Double(sourceTexture.height) * presentation.y / Double(drawable.texture.height)))
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
    let snapshot: TerminalGridSnapshot
    let configuration: TerminalWallpaperConfig

    func makeNSView(context: Context) -> NSView {
        guard let device = MTLCreateSystemDefaultDevice() else { return NSView() }
        return TerminalMetalView(
            frame: .zero,
            logicalSize: Self.sourceSize(snapshot: snapshot, render: configuration.render),
            device: device
        )
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Rasterize the complete source canvas; the outer viewport handles
        // uniform Fill cropping, just as it does for ordinary wallpaper previews.
        var render = configuration.render
        render.scaleMode = .fit
        (view as? TerminalMetalView)?.update(snapshot: snapshot, configuration: render)
    }

    static func sourceSize(snapshot: TerminalGridSnapshot, render: TerminalRenderConfiguration) -> CGSize {
        if render.pixelMode == .fixed {
            return CGSize(width: render.fixedWidth ?? 1920, height: render.fixedHeight ?? 1080)
        }
        let metrics = TerminalFontMetrics.cellMetrics(for: render)
        return CGSize(width: Double(snapshot.columns) * metrics.width, height: Double(snapshot.rows) * metrics.height)
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? TerminalMetalView)?.setRendererPaused(true)
    }
}
