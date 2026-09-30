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
            Color.black
            if let sharedFrame = model.sharedFrame {
                TerminalIOSurfacePreview(descriptor: sharedFrame, sequence: model.frameSequence)
            } else if let snapshot = model.snapshot, let configuration = model.configuration {
                TerminalSnapshotPreview(snapshot: snapshot, configuration: configuration)
                    .id(model.previewGeneration)
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
        .clipped()
    }
}

private struct TerminalIOSurfacePreview: NSViewRepresentable {
    let descriptor: TerminalSharedFrameDescriptor
    let sequence: UInt64

    func makeNSView(context: Context) -> TerminalIOSurfacePreviewView {
        TerminalIOSurfacePreviewView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    }

    func updateNSView(_ view: TerminalIOSurfacePreviewView, context: Context) {
        view.display(descriptor: descriptor, sequence: sequence)
    }
}

private final class TerminalIOSurfacePreviewView: MTKView {
    private let renderPipeline: MTLRenderPipelineState?
    private let commandQueue: MTLCommandQueue?
    private var surface: IOSurfaceRef?
    private var sourceTexture: MTLTexture?
    private var descriptor: TerminalSharedFrameDescriptor?
    private var lastSequence: UInt64 = 0

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

    func display(descriptor newDescriptor: TerminalSharedFrameDescriptor, sequence: UInt64) {
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
        guard sequence != lastSequence else { return }
        lastSequence = sequence
        needsDisplay = true
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
        var sourceAspect = Float(sourceTexture.width) / Float(max(sourceTexture.height, 1))
        var destinationAspect = Float(drawable.texture.width) / Float(max(drawable.texture.height, 1))
        sourceAspect = max(sourceAspect, 0.001)
        destinationAspect = max(destinationAspect, 0.001)
        var fitScale = SIMD2<Float>(1, 1)
        if sourceAspect > destinationAspect {
            fitScale.y = destinationAspect / sourceAspect
        } else {
            fitScale.x = sourceAspect / destinationAspect
        }
        encoder.setVertexBytes(&fitScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
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
            logicalSize: NSScreen.main?.frame.size ?? CGSize(width: 1530, height: 960),
            device: device
        )
    }

    func updateNSView(_ view: NSView, context: Context) {
        // A preview always fits its viewport; wallpaper Fill/Stretch settings
        // must not crop the preview or distort terminal cells.
        var render = configuration.render
        render.scaleMode = .fit
        (view as? TerminalMetalView)?.update(snapshot: snapshot, configuration: render)
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        (view as? TerminalMetalView)?.setRendererPaused(true)
    }
}
