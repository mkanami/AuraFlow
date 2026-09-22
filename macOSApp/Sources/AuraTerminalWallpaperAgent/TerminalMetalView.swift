import AppKit
import AuraTerminalWallpaperCore
import CoreText
import Metal
import MetalKit

final class TerminalMetalView: MTKView {
    private struct Vertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private var texture: MTLTexture?
    private var snapshot: TerminalGridSnapshot?
    private var renderConfiguration = TerminalRenderConfiguration()
    private let frameRenderer = CoreTextGlyphAtlas()

    init(frame: CGRect, device: MTLDevice) {
        commandQueue = device.makeCommandQueue()!
        let library = try! device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "terminal_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "terminal_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineState = try! device.makeRenderPipelineState(descriptor: descriptor)

        let vertices = [
            // CoreTextGlyphAtlas applies the CGContext y-transform while
            // laying out terminal rows. Keep row zero at the top at the final
            // texture blit instead of applying another vertical flip.
            Vertex(position: SIMD2(-1, -1), uv: SIMD2(0, 0)),
            Vertex(position: SIMD2(1, -1), uv: SIMD2(1, 0)),
            Vertex(position: SIMD2(-1, 1), uv: SIMD2(0, 1)),
            Vertex(position: SIMD2(1, 1), uv: SIMD2(1, 1)),
        ]
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<Vertex>.stride * vertices.count,
            options: .storageModeShared
        )!
        super.init(frame: frame, device: device)
        framebufferOnly = false
        isPaused = false
        enableSetNeedsDisplay = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = renderConfiguration.maxFPS
        autoresizingMask = [.width, .height]
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(snapshot: TerminalGridSnapshot, configuration: TerminalRenderConfiguration) {
        if let currentSnapshot = self.snapshot, snapshot.revision < currentSnapshot.revision {
            return
        }
        self.snapshot = snapshot
        renderConfiguration = configuration.normalized()
        preferredFramesPerSecond = renderConfiguration.maxFPS
        texture = nil
    }

    override func draw(_ rect: NSRect) {
        guard let drawable = currentDrawable,
              let snapshot,
              let texture = makeTexture(for: snapshot, drawableSize: drawable.texture)
        else {
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeTexture(for snapshot: TerminalGridSnapshot, drawableSize: MTLTexture) -> MTLTexture? {
        let nativeWidth = max(drawableSize.width, 1)
        let nativeHeight = max(drawableSize.height, 1)
        let pixelSize = TerminalRenderGeometry.pixelSize(
            configuration: renderConfiguration,
            drawableWidth: nativeWidth,
            drawableHeight: nativeHeight
        )
        let width = pixelSize.width
        let height = pixelSize.height
        if texture?.width != width || texture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            texture = device?.makeTexture(descriptor: descriptor)
        }
        guard let texture else { return nil }
        let bytes = frameRenderer.render(
            snapshot: snapshot,
            configuration: renderConfiguration,
            width: width,
            height: height
        )
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: width * 4
            )
        }
        return texture
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct TerminalVertex {
        float2 position;
        float2 uv;
    };

    struct TerminalOutput {
        float4 position [[position]];
        float2 uv;
    };

    vertex TerminalOutput terminal_vertex(
        const device TerminalVertex *vertices [[buffer(0)]],
        uint vertexID [[vertex_id]]) {
        TerminalOutput output;
        output.position = float4(vertices[vertexID].position, 0.0, 1.0);
        output.uv = vertices[vertexID].uv;
        return output;
    }

    fragment float4 terminal_fragment(
        TerminalOutput input [[stage_in]],
        texture2d<float> frame [[texture(0)]]) {
        constexpr sampler samplerState(filter::linear, address::clamp_to_edge);
        return frame.sample(samplerState, input.uv);
    }
    """
}

private final class CoreTextGlyphAtlas {
    private struct GlyphKey: Hashable {
        let text: String
        let fontFamily: String
        let fontSize: Int
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let dim: Bool
    }

    private var lineCache: [GlyphKey: CTLine] = [:]
    private static let blockQuadrants: [UInt32: UInt8] = [
        0x2596: 0b0100, 0x2597: 0b1000, 0x2598: 0b0001, 0x2599: 0b1101,
        0x259A: 0b1001, 0x259B: 0b0111, 0x259C: 0b1011, 0x259D: 0b0010,
        0x259E: 0b0110, 0x259F: 0b1110,
    ]
    private let palette: [TerminalRGBA] = [
        TerminalRGBA(red: 0.0, green: 0.0, blue: 0.0),
        TerminalRGBA(red: 0.8, green: 0.1, blue: 0.1),
        TerminalRGBA(red: 0.1, green: 0.75, blue: 0.2),
        TerminalRGBA(red: 0.8, green: 0.7, blue: 0.1),
        TerminalRGBA(red: 0.2, green: 0.4, blue: 0.9),
        TerminalRGBA(red: 0.7, green: 0.2, blue: 0.8),
        TerminalRGBA(red: 0.1, green: 0.75, blue: 0.75),
        TerminalRGBA(red: 0.8, green: 0.8, blue: 0.8),
        TerminalRGBA(red: 0.35, green: 0.35, blue: 0.35),
        TerminalRGBA(red: 1.0, green: 0.3, blue: 0.3),
        TerminalRGBA(red: 0.3, green: 1.0, blue: 0.35),
        TerminalRGBA(red: 1.0, green: 0.95, blue: 0.25),
        TerminalRGBA(red: 0.35, green: 0.55, blue: 1.0),
        TerminalRGBA(red: 1.0, green: 0.35, blue: 1.0),
        TerminalRGBA(red: 0.3, green: 1.0, blue: 1.0),
        TerminalRGBA(red: 1.0, green: 1.0, blue: 1.0),
    ]

    func render(
        snapshot: TerminalGridSnapshot,
        configuration: TerminalRenderConfiguration,
        width: Int,
        height: Int
    ) -> Data {
        var pixels = Data(repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = pixels.withUnsafeMutableBytes({ rawBuffer in
            CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            )
        }) else {
            return pixels
        }

        let background = configuration.background
        context.setFillColor(
            CGColor(
                srgbRed: background.red,
                green: background.green,
                blue: background.blue,
                alpha: background.alpha * configuration.backgroundOpacity
            )
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName(
            configuration.fontFamily as CFString,
            CGFloat(configuration.effectiveFontSize),
            nil
        )
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let lineHeight = max(ascent + descent + CGFloat(configuration.cellSpacing), 1)
        let sampleLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: "M", attributes: [.font: font])
        )
        let sampleWidth = max(CTLineGetTypographicBounds(sampleLine, nil, nil, nil), 1)
        let cellWidth = sampleWidth + CGFloat(configuration.cellSpacing)
        let contentWidth = max(CGFloat(snapshot.columns) * cellWidth, 1)
        let contentHeight = max(CGFloat(snapshot.rows) * lineHeight, 1)
        let baseScale = TerminalRenderGeometry.scaleFactors(
            contentWidth: contentWidth,
            contentHeight: contentHeight,
            targetWidth: CGFloat(width),
            targetHeight: CGFloat(height),
            mode: configuration.scaleMode
        )
        let fixedGridZoom = configuration.columns != nil && configuration.rows != nil
            ? configuration.textScale
            : 1
        let scale = TerminalScaleFactors(
            x: baseScale.x * fixedGridZoom,
            y: baseScale.y * fixedGridZoom
        )
        let drawnWidth = contentWidth * CGFloat(scale.x)
        let drawnHeight = contentHeight * CGFloat(scale.y)
        let offsetX = (CGFloat(width) - drawnWidth) * 0.5
        let offsetY = (CGFloat(height) - drawnHeight) * 0.5

        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: offsetX, y: offsetY)
        context.scaleBy(x: CGFloat(scale.x), y: CGFloat(scale.y))

        for row in 0..<snapshot.rows {
            for column in 0..<snapshot.columns {
                let cell = snapshot.cell(column: column, row: row)
                let rect = CGRect(
                    x: CGFloat(column) * cellWidth,
                    y: CGFloat(row) * lineHeight,
                    width: cellWidth * CGFloat(max(cell.width, 1)),
                    height: lineHeight
                )
                var foreground = cell.style.foreground.resolved(
                    defaultColor: TerminalRGBA(red: 0.9, green: 0.9, blue: 0.9),
                    palette: palette
                )
                var cellBackground = cell.style.background.resolved(
                    defaultColor: background,
                    palette: palette
                )
                if cell.style.attributes.contains(.inverse) {
                    swap(&foreground, &cellBackground)
                }
                if cell.style.background != .default {
                    fillPixelAligned(rect, color: cellBackground.cgColor, context: context)
                }
                guard !cell.text.isEmpty, cell.text != " " else { continue }
                let opacity = cell.style.attributes.contains(.dim) ? 0.55 : 1.0
                let glyphColor = foreground.cgColor.copy(alpha: foreground.alpha * opacity) ?? foreground.cgColor
                if drawBlockElement(cell.text, in: rect, context: context, color: glyphColor) {
                    continue
                }
                let line = lineFor(
                    text: cell.text,
                    font: font,
                    family: configuration.fontFamily,
                    size: configuration.fontSize,
                    color: foreground,
                    dim: cell.style.attributes.contains(.dim),
                    opacity: opacity
                )
                let baseline = rect.minY + ascent
                context.textPosition = CGPoint(x: rect.minX, y: baseline)
                CTLineDraw(line, context)
                if cell.style.attributes.contains(.underline) {
                    context.setStrokeColor(foreground.cgColor)
                    context.setLineWidth(max(1 / max(CGFloat(scale.x), 0.01), 1))
                    context.move(to: CGPoint(x: rect.minX, y: rect.maxY - 1))
                    context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 1))
                    context.strokePath()
                }
            }
        }
        context.restoreGState()
        return pixels
    }

    /// Terminal block elements represent pixel-sized fills, not font glyphs.
    /// Rasterizing them directly avoids font-specific gaps and tofu glyphs in
    /// full-screen visual TUIs such as lavat.
    private func drawBlockElement(
        _ text: String,
        in rect: CGRect,
        context: CGContext,
        color: CGColor
    ) -> Bool {
        guard text.unicodeScalars.count == 1,
              let scalar = text.unicodeScalars.first,
              (0x2580...0x259F).contains(scalar.value)
        else { return false }

        let halfWidth = rect.width / 2
        let halfHeight = rect.height / 2

        func fill(_ rect: CGRect, opacity: CGFloat = 1) {
            let fillColor = opacity == 1 ? color : (color.copy(alpha: color.alpha * opacity) ?? color)
            context.setFillColor(fillColor)
            context.fill(pixelAlignedRect(rect, context: context))
        }

        context.saveGState()
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        switch scalar.value {
        case 0x2580:
            fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: halfHeight))
        case 0x2581...0x2587:
            let eighths = CGFloat(scalar.value - 0x2580)
            fill(CGRect(
                x: rect.minX,
                y: rect.maxY - rect.height * eighths / 8,
                width: rect.width,
                height: rect.height * eighths / 8
            ))
        case 0x2588:
            fill(rect)
        case 0x2589...0x258F:
            let eighths = CGFloat(0x2590 - scalar.value)
            fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width * eighths / 8, height: rect.height))
        case 0x2590:
            fill(CGRect(x: rect.minX + halfWidth, y: rect.minY, width: halfWidth, height: rect.height))
        case 0x2591...0x2593:
            let opacity: CGFloat = scalar.value == 0x2591 ? 0.25 : (scalar.value == 0x2592 ? 0.5 : 0.75)
            fill(rect, opacity: opacity)
        case 0x2594:
            fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 8))
        case 0x2595:
            fill(CGRect(x: rect.maxX - rect.width / 8, y: rect.minY, width: rect.width / 8, height: rect.height))
        case 0x2596...0x259F:
            let mask = Self.blockQuadrants[scalar.value] ?? 0
            for row in 0..<2 {
                for column in 0..<2 {
                    let bit = UInt8(1 << (row * 2 + column))
                    guard mask & bit != 0 else { continue }
                    fill(CGRect(
                        x: rect.minX + CGFloat(column) * halfWidth,
                        y: rect.minY + CGFloat(row) * halfHeight,
                        width: halfWidth,
                        height: halfHeight
                    ))
                }
            }
        default:
            break
        }
        context.restoreGState()
        return true
    }

    private func fillPixelAligned(_ rect: CGRect, color: CGColor, context: CGContext) {
        context.saveGState()
        context.setAllowsAntialiasing(false)
        context.setShouldAntialias(false)
        context.setFillColor(color)
        context.fill(pixelAlignedRect(rect, context: context))
        context.restoreGState()
    }

    /// Snap fill edges to the bitmap's device pixels so adjacent terminal
    /// cells share exactly one raster boundary instead of antialiasing a
    /// translucent hairline between otherwise-solid block characters.
    private func pixelAlignedRect(_ rect: CGRect, context: CGContext) -> CGRect {
        let deviceRect = context.convertToDeviceSpace(rect).standardized
        let minX = deviceRect.minX.rounded()
        let minY = deviceRect.minY.rounded()
        let maxX = deviceRect.maxX.rounded()
        let maxY = deviceRect.maxY.rounded()
        let alignedDeviceRect = CGRect(
            x: minX,
            y: minY,
            width: max(maxX - minX, 0),
            height: max(maxY - minY, 0)
        )
        return context.convertToUserSpace(alignedDeviceRect).standardized
    }

    private func lineFor(
        text: String,
        font: CTFont,
        family: String,
        size: Double,
        color: TerminalRGBA,
        dim: Bool,
        opacity: CGFloat
    ) -> CTLine {
        let key = GlyphKey(
            text: text,
            fontFamily: family,
            fontSize: Int((size * 10).rounded()),
            red: UInt8(min(max(color.red * 255, 0), 255)),
            green: UInt8(min(max(color.green * 255, 0), 255)),
            blue: UInt8(min(max(color.blue * 255, 0), 255)),
            dim: dim
        )
        if let cached = lineCache[key] {
            return cached
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.cgColor.copy(alpha: opacity) as Any,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        if lineCache.count > 4096 {
            lineCache.removeAll(keepingCapacity: true)
        }
        lineCache[key] = line
        return line
    }

}

private extension TerminalRGBA {
    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
