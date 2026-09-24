import AppKit
import AuraTerminalWallpaperCore
import CoreText
import Metal
import MetalKit

final class TerminalMetalView: MTKView {
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private let logicalSize: CGSize
    private let rasterQueue = DispatchQueue(label: "com.andrijvergeles.auraflow.terminal-raster", qos: .userInitiated)
    private var texture: MTLTexture?
    private var snapshot: TerminalGridSnapshot?
    private var renderConfiguration = TerminalRenderConfiguration()
    private let frameRenderer = CoreTextGlyphAtlas()
    private var rasterInFlight = false
    private var rasterizedRevision: UInt64?
    private var rasterEpoch: UInt64 = 0
    private var requestedSize: TerminalPixelSize?

    var displayedRevision: UInt64? { rasterizedRevision }

    init(frame: CGRect, logicalSize: CGSize, device: MTLDevice) {
        self.logicalSize = logicalSize
        commandQueue = device.makeCommandQueue()!
        let library = try! device.makeLibrary(source: Self.shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "terminal_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "terminal_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineState = try! device.makeRenderPipelineState(descriptor: descriptor)

        let vertices = TerminalTextureOrientation.fullScreenQuad
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<TerminalMetalVertex>.stride * vertices.count,
            options: .storageModeShared
        )!
        super.init(frame: frame, device: device)
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = renderConfiguration.maxFPS
        autoresizingMask = [.width, .height]
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(snapshot: TerminalGridSnapshot, configuration: TerminalRenderConfiguration) {
        let normalized = configuration.normalized()
        if normalized == renderConfiguration,
           let currentSnapshot = self.snapshot,
           snapshot.revision < currentSnapshot.revision {
            return
        }
        if normalized != renderConfiguration {
            rasterEpoch &+= 1
            rasterizedRevision = nil
            texture = nil
        }
        self.snapshot = snapshot
        renderConfiguration = normalized
        preferredFramesPerSecond = renderConfiguration.maxFPS
        scheduleRasterization()
    }

    override func draw(_ rect: NSRect) {
        scheduleRasterization()
        guard let drawable = currentDrawable,
              let texture
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

    private func scheduleRasterization() {
        guard let snapshot else { return }
        let pixelSize = TerminalRenderGeometry.pixelSize(
            configuration: renderConfiguration,
            drawableWidth: max(Int(drawableSize.width), 1),
            drawableHeight: max(Int(drawableSize.height), 1)
        )
        if requestedSize != pixelSize {
            requestedSize = pixelSize
            rasterEpoch &+= 1
            rasterizedRevision = nil
            texture = nil
        }
        guard !rasterInFlight, rasterizedRevision != snapshot.revision else { return }
        rasterInFlight = true
        let epoch = rasterEpoch
        let configuration = renderConfiguration
        let width = pixelSize.width
        let height = pixelSize.height
        let fontPixelScale = TerminalRenderGeometry.pixelScaleFactor(
            pixelWidth: width,
            pixelHeight: height,
            logicalWidth: logicalSize.width,
            logicalHeight: logicalSize.height
        )
        rasterQueue.async { [weak self] in
            guard let self else { return }
            let bytes = self.frameRenderer.render(
                snapshot: snapshot,
                configuration: configuration,
                width: width,
                height: height,
                fontPixelScale: fontPixelScale
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rasterInFlight = false
                if self.rasterEpoch == epoch {
                    self.upload(bytes, width: width, height: height)
                    self.rasterizedRevision = snapshot.revision
                    self.needsDisplay = true
                }
                if self.snapshot?.revision != self.rasterizedRevision {
                    self.scheduleRasterization()
                }
            }
        }
    }

    private func upload(_ bytes: Data, width: Int, height: Int) {
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
        guard let texture else { return }
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: width * 4
            )
        }
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

final class CoreTextGlyphAtlas {
    private struct GlyphKey: Hashable {
        let text: String
        let fontFamily: String
        let fontSize: Int
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let dim: Bool
        let bold: Bool
    }

    private var lineCache: [GlyphKey: CTLine] = [:]
    private static let blockQuadrants: [UInt32: UInt8] = [
        0x2596: 0b0100, 0x2597: 0b1000, 0x2598: 0b0001, 0x2599: 0b1101,
        0x259A: 0b1001, 0x259B: 0b0111, 0x259C: 0b1011, 0x259D: 0b0010,
        0x259E: 0b0110, 0x259F: 0b1110,
    ]
    private let palette = TerminalPalette.kittyDefault16

    func render(
        snapshot: TerminalGridSnapshot,
        configuration: TerminalRenderConfiguration,
        width: Int,
        height: Int,
        fontPixelScale: Double
    ) -> Data {
        var pixels = Data(repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { rawBuffer in
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }
            drawFrame(
                snapshot: snapshot,
                configuration: configuration,
                width: width,
                height: height,
                fontPixelScale: fontPixelScale,
                context: context
            )
        }
        return pixels
    }

    private func drawFrame(
        snapshot: TerminalGridSnapshot,
        configuration: TerminalRenderConfiguration,
        width: Int,
        height: Int,
        fontPixelScale: Double,
        context: CGContext
    ) {
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

        let rasterFontSize = configuration.effectiveFontSize * fontPixelScale
        let font = TerminalFontResolver.font(
            family: configuration.fontFamily,
            size: CGFloat(rasterFontSize)
        )
        let ascent = CTFontGetAscent(font)
        let cellMetrics = TerminalFontMetrics.cellMetrics(
            font: font,
            cellSpacing: CGFloat(configuration.cellSpacing * fontPixelScale)
        )
        let lineHeight = CGFloat(cellMetrics.height)
        let cellWidth = CGFloat(cellMetrics.width)
        let layout = TerminalRenderGeometry.layout(
            columns: snapshot.columns,
            rows: snapshot.rows,
            cellWidth: Double(cellWidth),
            lineHeight: Double(lineHeight),
            targetWidth: Double(width),
            targetHeight: Double(height),
            mode: configuration.scaleMode
        )
        let scale = layout.scale
        let offsetX = CGFloat(layout.offsetX)
        let offsetY = CGFloat(layout.offsetY)

        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        // CoreText's glyph coordinate system is y-up even after the grid is
        // flipped to y-down. Without this, punctuation lands in the next row.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
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
                    defaultColor: palette[7],
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
                    size: rasterFontSize,
                    color: foreground,
                    dim: cell.style.attributes.contains(.dim),
                    bold: cell.style.attributes.contains(.bold),
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
        bold: Bool,
        opacity: CGFloat
    ) -> CTLine {
        let key = GlyphKey(
            text: text,
            fontFamily: family,
            fontSize: Int((size * 10).rounded()),
            red: UInt8(min(max(color.red * 255, 0), 255)),
            green: UInt8(min(max(color.green * 255, 0), 255)),
            blue: UInt8(min(max(color.blue * 255, 0), 255)),
            dim: dim,
            bold: bold
        )
        if let cached = lineCache[key] {
            return cached
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: bold
                ? TerminalFontResolver.font(family: family, size: CGFloat(size), bold: true)
                : font,
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
