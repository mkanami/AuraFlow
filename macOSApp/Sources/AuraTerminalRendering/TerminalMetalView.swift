import AppKit
import AuraTerminalWallpaperCore
import CoreText
import CoreVideo
import Darwin
import IOSurface
import Metal
import MetalKit

struct TerminalMetalCellInstance: Sendable {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float>
    var foreground: SIMD4<Float>
    var background: SIMD4<Float>
    var flags: SIMD4<UInt32>
}

struct TerminalGlyphAtlasUpdate: Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var pixels: Data
}

struct TerminalInstanceUpdate: Sendable {
    var index: Int
    var value: TerminalMetalCellInstance
}

struct TerminalPreparedFrame: Sendable {
    var revision: UInt64
    var width: Int
    var height: Int
    var atlasGeneration: UInt64
    var atlasUpdates: [TerminalGlyphAtlasUpdate]
    var fullInstances: Data?
    var instanceUpdates: [TerminalInstanceUpdate]
    var instanceCount: Int
    var background: SIMD4<Float>

    var requiresPresentation: Bool {
        fullInstances != nil || !atlasUpdates.isEmpty || !instanceUpdates.isEmpty
    }
}

// Accessed only on a view's preparationQueue; kept separate from the
// main-actor MTKView so preparing glyphs never reads UI-isolated state.
private final class TerminalFramePreparationState: @unchecked Sendable {
    let renderer: CoreTextGlyphAtlas
    var epoch: UInt64?
    init(atlasSize: Int) { renderer = CoreTextGlyphAtlas(atlasSize: atlasSize) }
}

// Retains the exact readback buffer until GPU completion. The callback only
// reads it after Metal signals completion; the view does not reuse it in flight.
private struct TerminalReadbackBuffer: @unchecked Sendable {
    let buffer: MTLBuffer
}

public final class TerminalMetalView: MTKView {
    private static let atlasSize = 2048

    private let commandQueue: MTLCommandQueue
    private let cellPipeline: MTLRenderPipelineState
    private let presentPipeline: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private var presentationBackground = TerminalRGBA.black
    private let preparationQueue = DispatchQueue(
        label: "com.andrijvergeles.auraflow.terminal-frame-prepare",
        qos: .userInitiated
    )
    private let preparationState = TerminalFramePreparationState(atlasSize: TerminalMetalView.atlasSize)
    private var frameTexture: MTLTexture?
    private var frameSurface: IOSurfaceRef?
    private var frameSurfaceDescriptor: TerminalSharedFrameDescriptor?
    private var sharedFrameSequence: UInt64 = 0
    private var atlasTexture: MTLTexture?
    private var uploadedAtlasGeneration: UInt64?
    private var instanceBuffer: MTLBuffer?
    private var instanceBufferCapacity = 0
    private var snapshot: TerminalGridSnapshot?
    private var renderConfiguration = TerminalRenderConfiguration()
    private var preparedFrame: TerminalPreparedFrame?
    private var rasterInFlight = false
    private var rasterizedRevision: UInt64?
    private var rasterEpoch: UInt64 = 0
    private var requestedSize: TerminalPixelSize?
    private var rendererPaused = false
    private var gpuFrameInFlight = false
    private var presentationPending = false
    private var pendingInstallation: (frame: TerminalPreparedFrame, epoch: UInt64)?
    private var lockScreenCaptureEnabled = false
    private var lockCaptureSeedPending = false
    private var lockCaptureInFlight = false
    private var lockCapturePending = false
    private var lockCaptureGeneration: UInt64 = 0
    private var lockCaptureBuffer: MTLBuffer?
    private var lockCaptureBufferCapacity = 0

    public var onLockScreenFrame: ((Data, Int, Int) -> Void)?
    public var onSharedFrame: ((TerminalSharedFrameDescriptor, UInt64) -> Void)?
    var displayedRevision: UInt64? { rasterizedRevision }

    public init(frame: CGRect, logicalSize: CGSize, device: MTLDevice) {
        commandQueue = device.makeCommandQueue()!
        let library = try! device.makeLibrary(source: Self.shaderSource, options: nil)
        cellPipeline = Self.makePipeline(
            device: device,
            library: library,
            vertexName: "terminal_cell_vertex",
            fragmentName: "terminal_cell_fragment"
        )
        presentPipeline = Self.makePipeline(
            device: device,
            library: library,
            vertexName: "terminal_present_vertex",
            fragmentName: "terminal_present_fragment"
        )

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

    public required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    public func update(snapshot: TerminalGridSnapshot, configuration: TerminalRenderConfiguration,
                       presentationBackground: TerminalRGBA? = nil) {
        let normalized = configuration.normalized()
        let background = presentationBackground ?? TerminalRGBA(
            red: normalized.background.red * normalized.backgroundOpacity,
            green: normalized.background.green * normalized.backgroundOpacity,
            blue: normalized.background.blue * normalized.backgroundOpacity)
        if self.presentationBackground != background {
            self.presentationBackground = background
            needsDisplay = true
        }
        if normalized == renderConfiguration,
           let currentSnapshot = self.snapshot,
           snapshot.revision < currentSnapshot.revision {
            return
        }
        var previousRasterConfiguration = renderConfiguration
        previousRasterConfiguration.scaleMode = normalized.scaleMode
        let modeChanged = normalized.scaleMode != renderConfiguration.scaleMode
        if normalized != previousRasterConfiguration {
            rasterEpoch &+= 1
            rasterizedRevision = nil
            preparedFrame = nil
            frameTexture = nil
            atlasTexture = nil
            requestedSize = nil
        }
        self.snapshot = snapshot
        renderConfiguration = normalized
        preferredFramesPerSecond = normalized.maxFPS
        if !rendererPaused || lockCaptureSeedPending { schedulePreparation() }
        if modeChanged {
            needsDisplay = true
            if gpuFrameInFlight { presentationPending = true }
        }
    }

    public func setRendererPaused(_ paused: Bool) {
        guard rendererPaused != paused else { return }
        rendererPaused = paused
        if paused {
            rasterEpoch &+= 1
            isPaused = true
        } else {
            isPaused = true
            schedulePreparation()
            if preparedFrame != nil { needsDisplay = true }
        }
    }

    public func setLockScreenCaptureEnabled(_ enabled: Bool) {
        guard lockScreenCaptureEnabled != enabled else { return }
        lockScreenCaptureEnabled = enabled
        lockCaptureGeneration &+= 1
        if enabled {
            captureCurrentTexture()
        } else {
            lockCapturePending = false
        }
    }

    public func requestLockScreenSeedCapture(refresh: Bool = false) {
        guard !lockScreenCaptureEnabled, refresh || !lockCaptureSeedPending else { return }
        if refresh { lockCaptureGeneration &+= 1 }
        lockCaptureSeedPending = true
        // Preparation can be finished while the texture still contains the
        // preceding (or uninitialized) frame. Read back only inside draw(),
        // after the current cells have actually been rendered into the texture.
        schedulePreparation()
        needsDisplay = true
    }

    public override func draw(_ rect: NSRect) {
        schedulePreparation()
        if gpuFrameInFlight {
            // AppKit consumes needsDisplay even when this pass cannot draw.
            // Remember it so a static final frame is not stranded indefinitely.
            presentationPending = true
            return
        }
        guard (!rendererPaused || lockCaptureSeedPending),
              let frameTexture,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }
        // The desktop window is occluded behind the secure Lock Screen. Its
        // drawable is not the clock for the shared surface: render offscreen
        // while locked, so neither AppKit occlusion nor nextDrawable stalls it.
        let drawable = lockScreenCaptureEnabled ? nil : currentDrawable
        guard lockScreenCaptureEnabled || drawable != nil else { return }

        let cellPass = MTLRenderPassDescriptor()
        cellPass.colorAttachments[0].texture = frameTexture
        cellPass.colorAttachments[0].loadAction = .clear
        cellPass.colorAttachments[0].storeAction = .store
        cellPass.colorAttachments[0].clearColor = clearColor
        guard let cellEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: cellPass) else { return }
        cellEncoder.setRenderPipelineState(cellPipeline)
        if let instanceBuffer, let atlasTexture,
           let preparedFrame, preparedFrame.instanceCount > 0 {
            cellEncoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
            cellEncoder.setFragmentTexture(atlasTexture, index: 0)
            cellEncoder.drawPrimitives(
                type: .triangleStrip,
                vertexStart: 0,
                vertexCount: 4,
                instanceCount: preparedFrame.instanceCount
            )
        }
        cellEncoder.endEncoding()

        let seedFrameIsCurrent = rasterizedRevision == snapshot?.revision
        if lockScreenCaptureEnabled || (lockCaptureSeedPending && seedFrameIsCurrent) {
            appendLockScreenReadback(to: commandBuffer, from: frameTexture)
        }

        if let drawable {
            let presentPass = MTLRenderPassDescriptor()
            presentPass.colorAttachments[0].texture = drawable.texture
            presentPass.colorAttachments[0].loadAction = .clear
            presentPass.colorAttachments[0].storeAction = .store
            presentPass.colorAttachments[0].clearColor = MTLClearColor(
                red: presentationBackground.red, green: presentationBackground.green,
                blue: presentationBackground.blue, alpha: 1)
            guard let presentEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: presentPass) else { return }
            presentEncoder.setRenderPipelineState(presentPipeline)
            presentEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            let presentation = TerminalRenderGeometry.presentationScale(
                sourceWidth: frameTexture.width, sourceHeight: frameTexture.height,
                targetWidth: drawable.texture.width, targetHeight: drawable.texture.height,
                mode: renderConfiguration.scaleMode)
            var presentationScale = SIMD2<Float>(Float(presentation.x), Float(presentation.y))
            presentEncoder.setVertexBytes(&presentationScale, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            presentEncoder.setFragmentTexture(frameTexture, index: 0)
            presentEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            presentEncoder.endEncoding()
            commandBuffer.present(drawable)
        }
        let publishedDescriptor = frameSurfaceDescriptor
        if publishedDescriptor != nil {
            sharedFrameSequence &+= 1
            let sequence = sharedFrameSequence
            commandBuffer.addCompletedHandler { [weak self] completedBuffer in
                guard completedBuffer.status == .completed,
                      let publishedDescriptor else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.frameSurfaceDescriptor == publishedDescriptor else { return }
                    self.onSharedFrame?(publishedDescriptor, sequence)
                }
            }
        }
        gpuFrameInFlight = true
        commandBuffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.gpuFrameInFlight = false
                if let pending = self.pendingInstallation {
                    self.pendingInstallation = nil
                    self.accept(pending.frame, epoch: pending.epoch)
                } else {
                    self.schedulePreparation()
                }
                if self.presentationPending {
                    self.presentationPending = false
                    if self.lockScreenCaptureEnabled { self.draw(self.bounds) }
                    else { self.needsDisplay = true }
                }
            }
        }
        commandBuffer.commit()
    }

    private func schedulePreparation() {
        guard (!rendererPaused || lockCaptureSeedPending), let snapshot else { return }
        let metrics = TerminalFontMetrics.cellMetrics(for: renderConfiguration)
        let sourceWidth = Double(snapshot.columns) * metrics.width
        let sourceHeight = Double(snapshot.rows) * metrics.height
        let density = NSScreen.main?.backingScaleFactor ?? 1
        let pixelSize = TerminalRenderGeometry.sourcePixelSize(
            configuration: renderConfiguration,
            columns: snapshot.columns, rows: snapshot.rows,
            cellWidth: metrics.width, lineHeight: metrics.height,
            pixelDensity: density
        )
        if requestedSize != pixelSize {
            requestedSize = pixelSize
            rasterEpoch &+= 1
            rasterizedRevision = nil
            preparedFrame = nil
            frameTexture = nil
        }
        guard !rasterInFlight, pendingInstallation == nil,
              rasterizedRevision != snapshot.revision,
              preparedFrame?.revision != snapshot.revision else { return }

        rasterInFlight = true
        let epoch = rasterEpoch
        let configuration = renderConfiguration
        let width = pixelSize.width
        let height = pixelSize.height
        let fontPixelScale = TerminalRenderGeometry.pixelScaleFactor(
            pixelWidth: width,
            pixelHeight: height,
            logicalWidth: sourceWidth,
            logicalHeight: sourceHeight
        )
        let state = preparationState
        preparationQueue.async { [weak self] in
            if state.epoch != epoch {
                state.renderer.invalidate()
                state.epoch = epoch
            }
            let prepared = state.renderer.prepare(
                snapshot: snapshot,
                configuration: configuration,
                width: width,
                height: height,
                fontPixelScale: fontPixelScale
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.rasterInFlight = false
                self.accept(prepared, epoch: epoch)
            }
        }
    }

    private func accept(_ prepared: TerminalPreparedFrame, epoch: UInt64) {
        guard (!rendererPaused || lockCaptureSeedPending), rasterEpoch == epoch else {
            schedulePreparation()
            return
        }
        // Shared buffers/atlas must not be mutated while Metal reads them.
        guard !gpuFrameInFlight else {
            pendingInstallation = (prepared, epoch)
            return
        }
        // Consume every prepared delta, even if a newer snapshot arrived.
        // Only snapshots that have not entered preparation may be coalesced.
        install(prepared)
        rasterizedRevision = prepared.revision
        if prepared.requiresPresentation || lockCaptureSeedPending {
            if lockScreenCaptureEnabled { draw(bounds) }
            else { needsDisplay = true }
        }
        if snapshot?.revision != prepared.revision { schedulePreparation() }
    }

    private func install(_ prepared: TerminalPreparedFrame) {
        guard let device else { return }
        clearColor = MTLClearColor(
            red: Double(prepared.background.x),
            green: Double(prepared.background.y),
            blue: Double(prepared.background.z),
            alpha: 1
        )
        if frameTexture?.width != prepared.width || frameTexture?.height != prepared.height {
            frameSurface = nil
            frameSurfaceDescriptor = nil
            let bytesPerRow = ((prepared.width * 4 + 63) / 64) * 64
            let surfaceProperties: [String: Any] = [
                kIOSurfaceWidth as String: prepared.width,
                kIOSurfaceHeight as String: prepared.height,
                kIOSurfaceBytesPerElement as String: 4,
                kIOSurfaceBytesPerRow as String: bytesPerRow,
                kIOSurfacePixelFormat as String: OSType(0x42475241), // BGRA
                kIOSurfaceAllocSize as String: bytesPerRow * prepared.height,
                // Required by the existing IOSurface ID transport to the Lock Screen.
                "IOSurfaceIsGlobal": true,
            ]
            guard let surface = IOSurfaceCreate(surfaceProperties as CFDictionary) else { return }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: prepared.width,
                height: prepared.height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            guard let sharedTexture = device.makeTexture(
                descriptor: descriptor,
                iosurface: surface,
                plane: 0
            ) else { return }
            frameSurface = surface
            frameTexture = sharedTexture
            frameSurfaceDescriptor = TerminalSharedFrameDescriptor(
                surfaceID: IOSurfaceGetID(surface),
                width: prepared.width,
                height: prepared.height,
                agentPID: Int(getpid())
            )
            sharedFrameSequence = 0
        }
        if atlasTexture == nil || uploadedAtlasGeneration != prepared.atlasGeneration {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: Self.atlasSize,
                height: Self.atlasSize,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            atlasTexture = device.makeTexture(descriptor: descriptor)
            uploadedAtlasGeneration = prepared.atlasGeneration
            if let atlasTexture {
                let zeroes = Data(repeating: 0, count: Self.atlasSize * Self.atlasSize)
                zeroes.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    atlasTexture.replace(
                        region: MTLRegionMake2D(0, 0, Self.atlasSize, Self.atlasSize),
                        mipmapLevel: 0,
                        withBytes: baseAddress,
                        bytesPerRow: Self.atlasSize
                    )
                }
            }
        }
        if let atlasTexture {
            for update in prepared.atlasUpdates {
                update.pixels.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    atlasTexture.replace(
                        region: MTLRegionMake2D(update.x, update.y, update.width, update.height),
                        mipmapLevel: 0,
                        withBytes: baseAddress,
                        bytesPerRow: update.width
                    )
                }
            }
        }
        if let fullInstances = prepared.fullInstances {
            ensureInstanceBuffer(device: device, byteCount: fullInstances.count)
            if let instanceBuffer, !fullInstances.isEmpty {
                fullInstances.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    instanceBuffer.contents().copyMemory(from: baseAddress, byteCount: fullInstances.count)
                }
            }
        } else if let instanceBuffer {
            for update in prepared.instanceUpdates {
                withUnsafeBytes(of: update.value) { bytes in
                    guard let baseAddress = bytes.baseAddress else { return }
                    instanceBuffer.contents()
                        .advanced(by: update.index * MemoryLayout<TerminalMetalCellInstance>.stride)
                        .copyMemory(from: baseAddress, byteCount: MemoryLayout<TerminalMetalCellInstance>.stride)
                }
            }
        }
        self.preparedFrame = prepared
    }

    private func ensureInstanceBuffer(device: MTLDevice, byteCount: Int) {
        guard byteCount > 0 else { return }
        if instanceBufferCapacity < byteCount {
            instanceBufferCapacity = max(byteCount, max(instanceBufferCapacity * 2, 4096))
            instanceBuffer = device.makeBuffer(length: instanceBufferCapacity, options: .storageModeShared)
        }
    }

    private func captureCurrentTexture() {
        guard lockScreenCaptureEnabled || lockCaptureSeedPending else { return }
        if !lockScreenCaptureEnabled, lockCaptureSeedPending,
           rasterizedRevision != snapshot?.revision {
            schedulePreparation()
            needsDisplay = true
            return
        }
        guard !lockCaptureInFlight else {
            lockCapturePending = true
            return
        }
        guard let frameTexture, let commandBuffer = commandQueue.makeCommandBuffer() else {
            needsDisplay = true
            return
        }
        appendLockScreenReadback(to: commandBuffer, from: frameTexture)
        commandBuffer.commit()
    }

    private func appendLockScreenReadback(to commandBuffer: MTLCommandBuffer, from texture: MTLTexture) {
        guard lockScreenCaptureEnabled || lockCaptureSeedPending else { return }
        guard !lockCaptureInFlight else {
            lockCapturePending = true
            return
        }
        guard let device, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        let width = texture.width
        let height = texture.height
        let bytesPerRow = ((width * 4 + 255) / 256) * 256
        let requiredBytes = bytesPerRow * height
        if lockCaptureBufferCapacity < requiredBytes {
            lockCaptureBufferCapacity = requiredBytes
            lockCaptureBuffer = device.makeBuffer(length: requiredBytes, options: .storageModeShared)
        }
        guard let lockCaptureBuffer else { return }
        lockCaptureInFlight = true
        let captureGeneration = lockCaptureGeneration
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: lockCaptureBuffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: requiredBytes
        )
        blit.endEncoding()
        let readback = TerminalReadbackBuffer(buffer: lockCaptureBuffer)
        commandBuffer.addCompletedHandler { [weak self] commandBuffer in
            guard let self else { return }
            let pixels: Data?
            if commandBuffer.status == .completed {
                pixels = Self.copyPixels(
                    from: readback.buffer.contents(),
                    width: width,
                    height: height,
                    bytesPerRow: bytesPerRow
                )
            } else {
                pixels = nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lockCaptureInFlight = false
                let retryCapture = self.lockCapturePending
                self.lockCapturePending = false
                guard self.lockCaptureGeneration == captureGeneration,
                      self.lockScreenCaptureEnabled || self.lockCaptureSeedPending,
                      let pixels else {
                    if self.lockCaptureSeedPending {
                        // A refreshed static seed belongs to the final raster,
                        // not a texture captured before the child completed.
                        self.needsDisplay = true
                    } else if retryCapture && self.lockScreenCaptureEnabled {
                        self.captureCurrentTexture()
                    }
                    return
                }
                self.onLockScreenFrame?(pixels, width, height)
                self.lockCaptureSeedPending = false
                if retryCapture && self.lockScreenCaptureEnabled { self.captureCurrentTexture() }
            }
        }
    }

    nonisolated private static func copyPixels(from source: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int) -> Data {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    destinationBase.advanced(by: row * width * 4),
                    source.advanced(by: row * bytesPerRow),
                    width * 4
                )
            }
        }
        return pixels
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexName: String,
        fragmentName: String
    ) -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertexName)
        descriptor.fragmentFunction = library.makeFunction(name: fragmentName)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try! device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct TerminalVertex {
        float2 position;
        float2 uv;
    };

    struct TerminalCellInstance {
        float4 rect;
        float4 uv;
        float4 foreground;
        float4 background;
        uint4 flags;
    };

    struct TerminalCellOutput {
        float4 position [[position]];
        float2 uv;
        float2 local;
        float4 foreground;
        float4 background;
        uint4 flags;
    };

    struct TerminalPresentOutput {
        float4 position [[position]];
        float2 uv;
    };

    vertex TerminalCellOutput terminal_cell_vertex(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        const device TerminalCellInstance *cells [[buffer(0)]]) {
        const float2 corners[4] = {
            float2(0.0, 0.0), float2(1.0, 0.0),
            float2(0.0, 1.0), float2(1.0, 1.0)
        };
        TerminalCellInstance cell = cells[instanceID];
        float2 corner = corners[vertexID];
        TerminalCellOutput output;
        output.position = float4(
            cell.rect.x + corner.x * cell.rect.z,
            cell.rect.y - corner.y * cell.rect.w,
            0.0,
            1.0
        );
        output.uv = cell.uv.xy + corner * cell.uv.zw;
        output.local = corner;
        output.foreground = cell.foreground;
        output.background = cell.background;
        output.flags = cell.flags;
        return output;
    }

    fragment float4 terminal_cell_fragment(
        TerminalCellOutput input [[stage_in]],
        texture2d<float> glyphAtlas [[texture(0)]]) {
        constexpr sampler glyphSampler(filter::linear, address::clamp_to_edge);
        float coverage = 0.0;
        if ((input.flags.x & 1u) != 0u) {
            coverage = glyphAtlas.sample(glyphSampler, input.uv).r;
        }
        if ((input.flags.y & 1u) != 0u && input.local.y > 0.92) {
            coverage = 1.0;
        }
        return mix(input.background, input.foreground, clamp(coverage, 0.0, 1.0));
    }

    vertex TerminalPresentOutput terminal_present_vertex(
        const device TerminalVertex *vertices [[buffer(0)]],
        const device float2 *scale [[buffer(1)]],
        uint vertexID [[vertex_id]]) {
        TerminalPresentOutput output;
        output.position = float4(vertices[vertexID].position * scale[0], 0.0, 1.0);
        output.uv = vertices[vertexID].uv;
        return output;
    }

    fragment float4 terminal_present_fragment(
        TerminalPresentOutput input [[stage_in]],
        texture2d<float> frame [[texture(0)]]) {
        constexpr sampler frameSampler(filter::linear, address::clamp_to_edge);
        return frame.sample(frameSampler, input.uv);
    }
    """
}

final class CoreTextGlyphAtlas {
    private struct GlyphKey: Hashable {
        var text: String
        var bold: Bool
        var width: Int
    }

    private struct GlyphRegion {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    private struct Signature: Equatable {
        var family: String
        var fontSize: Int
        var cellWidth: Int
        var cellHeight: Int
    }

    private let atlasSize: Int
    private var entries: [GlyphKey: GlyphRegion] = [:]
    private var cursorX = 1
    private var cursorY = 1
    private var rowHeight = 0
    private var signature: Signature?
    private(set) var generation: UInt64 = 0
    private var cachedConfiguration: TerminalRenderConfiguration?
    private var cachedOutputSize: (width: Int, height: Int)?
    private var cachedGridSize: (columns: Int, rows: Int)?
    private var cachedCells: [TerminalCell] = []
    private var cachedInstances: [TerminalMetalCellInstance] = []
    private struct MetricsKey: Equatable {
        let family: String
        let size: Double
        let spacing: Double
    }
    private var rasterMetrics: (key: MetricsKey, value: TerminalCellMetrics)?
    private static let palette = TerminalPalette.kittyDefault16
    private static let blockQuadrants: [UInt32: UInt8] = [
        0x2596: 0b0100, 0x2597: 0b1000, 0x2598: 0b0001, 0x2599: 0b1101,
        0x259A: 0b1001, 0x259B: 0b0111, 0x259C: 0b1011, 0x259D: 0b0010,
        0x259E: 0b0110, 0x259F: 0b1110,
    ]

    init(atlasSize: Int) {
        self.atlasSize = atlasSize
    }

    func invalidate() {
        signature = nil
        cachedConfiguration = nil
    }

    func prepare(
        snapshot: TerminalGridSnapshot,
        configuration: TerminalRenderConfiguration,
        width: Int,
        height: Int,
        fontPixelScale: Double
    ) -> TerminalPreparedFrame {
        let rasterFontSize = configuration.effectiveFontSize * fontPixelScale
        let font = TerminalFontResolver.font(
            family: configuration.fontFamily,
            size: CGFloat(rasterFontSize)
        )
        let ascent = CTFontGetAscent(font)
        let metricsKey = MetricsKey(family: configuration.fontFamily, size: rasterFontSize,
                                    spacing: configuration.cellSpacing * fontPixelScale)
        let metrics: TerminalCellMetrics
        if let cached = rasterMetrics, cached.key == metricsKey {
            metrics = cached.value
        } else {
            metrics = TerminalFontMetrics.cellMetrics(font: font, cellSpacing: CGFloat(metricsKey.spacing))
            rasterMetrics = (metricsKey, metrics)
        }
        let cellWidth = CGFloat(metrics.width)
        let lineHeight = CGFloat(metrics.height)
        let currentSignature = Signature(
            family: configuration.fontFamily,
            fontSize: Int((rasterFontSize * 100).rounded()),
            cellWidth: Int(ceil(cellWidth)),
            cellHeight: Int(ceil(lineHeight))
        )
        if signature != currentSignature {
            signature = currentSignature
            entries.removeAll(keepingCapacity: true)
            cursorX = 1
            cursorY = 1
            rowHeight = 0
            generation &+= 1
        }

        let background = configuration.background
        let baseColor = SIMD4<Float>(
            Float(background.red * configuration.backgroundOpacity),
            Float(background.green * configuration.backgroundOpacity),
            Float(background.blue * configuration.backgroundOpacity),
            1
        )
        let layout = TerminalRenderGeometry.layout(
            columns: snapshot.columns,
            rows: snapshot.rows,
            cellWidth: Double(cellWidth),
            lineHeight: Double(lineHeight),
            targetWidth: Double(width),
            targetHeight: Double(height),
            // Rasterize the complete grid into the source canvas. The final
            // viewport, not this reusable texture, owns Fit/Fill/Stretch.
            mode: .fit
        )
        let fontScaleX = CGFloat(layout.scale.x)
        let fontScaleY = CGFloat(layout.scale.y)
        let offsetX = CGFloat(layout.offsetX)
        let offsetY = CGFloat(layout.offsetY)
        let requiresFullUpload = cachedConfiguration != configuration
            || cachedOutputSize?.width != width
            || cachedOutputSize?.height != height
            || cachedGridSize?.columns != snapshot.columns
            || cachedGridSize?.rows != snapshot.rows
            || cachedInstances.count != snapshot.columns * snapshot.rows
        if requiresFullUpload {
            let count = snapshot.columns * snapshot.rows
            cachedCells = Array(repeating: TerminalCell(), count: count)
            cachedInstances = Array(repeating: TerminalMetalCellInstance(
                rect: .zero,
                uv: .zero,
                foreground: .zero,
                background: baseColor,
                flags: .zero
            ), count: count)
            cachedConfiguration = configuration
            cachedOutputSize = (width, height)
            cachedGridSize = (snapshot.columns, snapshot.rows)
        }
        var updates: [TerminalGlyphAtlasUpdate] = []
        var instanceUpdates: [TerminalInstanceUpdate] = []
        instanceUpdates.reserveCapacity(min(snapshot.cells.count, 256))

        for row in 0..<snapshot.rows {
            for column in 0..<snapshot.columns {
                let index = row * snapshot.columns + column
                let cell = snapshot.cell(column: column, row: row)
                guard requiresFullUpload || cachedCells[index] != cell else { continue }
                cachedCells[index] = cell
                if cell.width == 0 {
                    let originX = offsetX + CGFloat(column) * cellWidth * fontScaleX
                    let originY = offsetY + CGFloat(row) * lineHeight * fontScaleY
                    let hidden = TerminalMetalCellInstance(
                        rect: SIMD4<Float>(
                            Float(-1 + 2 * originX / CGFloat(width)),
                            Float(1 - 2 * originY / CGFloat(height)),
                            0,
                            Float(2 * lineHeight * fontScaleY / CGFloat(height))
                        ),
                        uv: .zero,
                        foreground: .zero,
                        background: baseColor,
                        flags: SIMD4<UInt32>(0, 0, 1, 0)
                    )
                    cachedInstances[index] = hidden
                    instanceUpdates.append(TerminalInstanceUpdate(index: index, value: hidden))
                    continue
                }
                let hasGlyph = !cell.text.isEmpty && cell.text != " "
                var foreground = cell.style.foreground.resolved(
                    defaultColor: Self.palette[7],
                    palette: Self.palette
                )
                var cellBackground = cell.style.background.resolved(
                    defaultColor: background,
                    palette: Self.palette
                )
                if cell.style.attributes.contains(.inverse) {
                    swap(&foreground, &cellBackground)
                }
                let usesBaseBackground = cell.style.background == .default
                    && !cell.style.attributes.contains(.inverse)
                let resolvedBackground = usesBaseBackground
                    ? baseColor
                    : Self.composite(cellBackground, over: baseColor)
                let dim = cell.style.attributes.contains(.dim) ? Float(0.55) : Float(1)
                let foregroundVector = SIMD4<Float>(
                    Float(foreground.red) * dim,
                    Float(foreground.green) * dim,
                    Float(foreground.blue) * dim,
                    1
                )
                var uv = SIMD4<Float>(repeating: 0)
                var glyphFlag: UInt32 = 0
                if hasGlyph {
                    let key = GlyphKey(
                        text: cell.text,
                        bold: cell.style.attributes.contains(.bold),
                        width: max(cell.width, 1)
                    )
                    if let region = ensureGlyph(
                        key,
                        font: font,
                        family: configuration.fontFamily,
                        fontSize: rasterFontSize,
                        widthUnits: max(cell.width, 1),
                        cellWidth: cellWidth,
                        lineHeight: lineHeight,
                        ascent: ascent,
                        updates: &updates
                    ) {
                        uv = textureCoordinates(for: region)
                        glyphFlag = 1
                    }
                }

                let originX = offsetX + CGFloat(column) * cellWidth * fontScaleX
                let originY = offsetY + CGFloat(row) * lineHeight * fontScaleY
                let cellPixelWidth = cellWidth * CGFloat(max(cell.width, 1)) * fontScaleX
                let cellPixelHeight = lineHeight * fontScaleY
                let rect = SIMD4<Float>(
                    Float(-1 + 2 * originX / CGFloat(width)),
                    Float(1 - 2 * originY / CGFloat(height)),
                    Float(2 * cellPixelWidth / CGFloat(width)),
                    Float(2 * cellPixelHeight / CGFloat(height))
                )
                let underlineFlag: UInt32 = cell.style.attributes.contains(.underline) ? 1 : 0
                let instance = TerminalMetalCellInstance(
                    rect: rect,
                    uv: uv,
                    foreground: foregroundVector,
                    background: resolvedBackground,
                    flags: SIMD4<UInt32>(glyphFlag, underlineFlag, 0, 0)
                )
                cachedInstances[index] = instance
                instanceUpdates.append(TerminalInstanceUpdate(index: index, value: instance))
            }
        }
        let fullInstances = requiresFullUpload
            ? cachedInstances.withUnsafeBufferPointer { buffer in
                Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<TerminalMetalCellInstance>.stride)
            }
            : nil
        return TerminalPreparedFrame(
            revision: snapshot.revision,
            width: width,
            height: height,
            atlasGeneration: generation,
            atlasUpdates: updates,
            fullInstances: fullInstances,
            instanceUpdates: instanceUpdates,
            instanceCount: snapshot.columns * snapshot.rows,
            background: baseColor
        )
    }

    func rasterizeForTesting(
        text: String,
        family: String = "System Monospace",
        fontSize: Double = 18,
        cellWidth: Int = 24,
        cellHeight: Int = 40
    ) -> (pixels: Data, width: Int, height: Int) {
        let font = TerminalFontResolver.font(family: family, size: CGFloat(fontSize))
        return Self.makeGlyphMask(
            text: text,
            font: font,
            width: max(cellWidth, 1),
            height: max(cellHeight, 1),
            ascent: CTFontGetAscent(font)
        )
    }

    private func ensureGlyph(
        _ key: GlyphKey,
        font: CTFont,
        family: String,
        fontSize: Double,
        widthUnits: Int,
        cellWidth: CGFloat,
        lineHeight: CGFloat,
        ascent: CGFloat,
        updates: inout [TerminalGlyphAtlasUpdate]
    ) -> GlyphRegion? {
        if let region = entries[key] { return region }
        let glyphFont = key.bold
            ? TerminalFontResolver.font(family: family, size: CGFloat(fontSize), bold: true)
            : font
        let glyphWidth = max(Int(ceil(cellWidth * CGFloat(widthUnits))), 1)
        let glyphHeight = max(Int(ceil(lineHeight)), 1)
        let mask = Self.makeGlyphMask(
            text: key.text,
            font: glyphFont,
            width: glyphWidth,
            height: glyphHeight,
            ascent: CTFontGetAscent(glyphFont)
        )
        guard let region = allocate(width: mask.width, height: mask.height) else { return nil }
        entries[key] = region
        updates.append(TerminalGlyphAtlasUpdate(
            x: region.x,
            y: region.y,
            width: region.width,
            height: region.height,
            pixels: mask.pixels
        ))
        return region
    }

    private func allocate(width: Int, height: Int) -> GlyphRegion? {
        let paddedWidth = width + 2
        let paddedHeight = height + 2
        if cursorX + paddedWidth > atlasSize {
            cursorX = 1
            cursorY += rowHeight
            rowHeight = 0
        }
        guard cursorY + paddedHeight <= atlasSize else { return nil }
        let region = GlyphRegion(x: cursorX + 1, y: cursorY + 1, width: width, height: height)
        cursorX += paddedWidth
        rowHeight = max(rowHeight, paddedHeight)
        return region
    }

    private func textureCoordinates(for region: GlyphRegion) -> SIMD4<Float> {
        let minX = Float(region.x) + 0.5
        let minY = Float(region.y) + 0.5
        let spanX = Float(max(region.width - 1, 0))
        let spanY = Float(max(region.height - 1, 0))
        return SIMD4<Float>(
            minX / Float(atlasSize),
            minY / Float(atlasSize),
            spanX / Float(atlasSize),
            spanY / Float(atlasSize)
        )
    }

    private static func composite(_ color: TerminalRGBA, over base: SIMD4<Float>) -> SIMD4<Float> {
        let alpha = Float(color.alpha)
        return SIMD4<Float>(
            Float(color.red) * alpha + base.x * (1 - alpha),
            Float(color.green) * alpha + base.y * (1 - alpha),
            Float(color.blue) * alpha + base.z * (1 - alpha),
            1
        )
    }

    private static func makeGlyphMask(
        text: String,
        font: CTFont,
        width: Int,
        height: Int,
        ascent: CGFloat
    ) -> (pixels: Data, width: Int, height: Int) {
        if let scalar = text.unicodeScalars.first,
           text.unicodeScalars.count == 1,
           (0x2580...0x259F).contains(scalar.value) {
            return (blockMask(scalar: scalar.value, width: width, height: height), width, height)
        }
        var pixels = Data(repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.white.cgColor,
                ])
            )
            context.textPosition = CGPoint(x: 0, y: ascent)
            CTLineDraw(line, context)
        }
        return (pixels, width, height)
    }

    private static func blockMask(scalar: UInt32, width: Int, height: Int) -> Data {
        var mask = Data(repeating: 0, count: width * height)
        func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, value: UInt8 = 255) {
            let left = min(max(x0, 0), width)
            let top = min(max(y0, 0), height)
            let right = min(max(x1, left), width)
            let bottom = min(max(y1, top), height)
            guard left < right, top < bottom else { return }
            for y in top..<bottom {
                for x in left..<right { mask[y * width + x] = value }
            }
        }
        switch scalar {
        case 0x2580:
            fill(0, 0, width, height / 2)
        case 0x2581...0x2587:
            let eighths = Int(scalar - 0x2580)
            fill(0, height * (8 - eighths) / 8, width, height)
        case 0x2588:
            fill(0, 0, width, height)
        case 0x2589...0x258F:
            let eighths = Int(0x2590 - scalar)
            fill(0, 0, width * eighths / 8, height)
        case 0x2590:
            fill(width / 2, 0, width, height)
        case 0x2591...0x2593:
            let value: UInt8 = scalar == 0x2591 ? 64 : (scalar == 0x2592 ? 128 : 192)
            fill(0, 0, width, height, value: value)
        case 0x2594:
            fill(0, 0, width, height / 8)
        case 0x2595:
            fill(width - width / 8, 0, width, height)
        case 0x2596...0x259F:
            let bits = Self.blockQuadrants[scalar] ?? 0
            for row in 0..<2 {
                for column in 0..<2 {
                    guard bits & UInt8(1 << (row * 2 + column)) != 0 else { continue }
                    fill(column * width / 2, row * height / 2,
                         (column + 1) * width / 2, (row + 1) * height / 2)
                }
            }
        default:
            break
        }
        return mask
    }
}
