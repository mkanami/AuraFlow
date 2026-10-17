import AppKit
import Combine
import IOSurface
import Metal
import AuraTerminalRendering
import AuraTerminalWallpaperCore
import SwiftUI
import Testing
@testable import WallpaperControlApp

@Suite(.serialized) @MainActor
struct TerminalPreviewWindowResizeTests {
    @Test func explicitFramesRetireDrawablesWithoutAppKitInvalidations() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = TerminalMetalView(frame: .init(x: 0, y: 0, width: 160, height: 80),
            logicalSize: .init(width: 160, height: 80), device: device)
        let window = NSWindow(contentRect: renderer.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer
        window.orderFrontRegardless()
        defer { window.close() }
        // Only explicit frame delivery drives rendering. AppKit must not
        // accidentally recycle the drawable on behalf of the animation.
        renderer.enableSetNeedsDisplay = false
        // Acquiring a drawable also works in the UI test host when macOS
        // reports its windows occluded. Exercise its lifetime independently
        // of whether WindowServer currently exposes the test window.
        _ = try #require(renderer.currentDrawable)
        var deliveredFrames = 0
        var drawableIDs: [Int] = []
        renderer.onSharedFrame = { _, _ in
            deliveredFrames += 1
            // Reading this reserves the drawable for the next frame. A proper
            // MTKView draw cycle must release it after submitting that frame.
            if let drawable = renderer.currentDrawable { drawableIDs.append(drawable.drawableID) }
        }
        var parser = VTParser(columns: 8, rows: 4)
        let render = TerminalRenderConfiguration(pixelMode: .fixed, fixedWidth: 160, fixedHeight: 80,
            columns: 8, rows: 4, fontSize: 12, maxFPS: 30)
        for index in 0..<24 {
            let previousCount = deliveredFrames
            parser.feed(Data("\u{1B}[\(index % 2 == 0 ? 41 : 44)m\u{1B}[2J".utf8))
            renderer.update(snapshot: parser.grid.snapshot(), configuration: render)
            let deadline = Date().addingTimeInterval(2)
            while deliveredFrames == previousCount && Date() < deadline {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            #expect(deliveredFrames > previousCount)
        }
        #expect(drawableIDs.count >= 24)
        // A drawable's ID identifies a presentation, not its reusable texture.
        // IOSurface publication alone cannot detect repeatedly presenting the
        // same drawable while the actual desktop stops advancing.
        #expect(Set(drawableIDs).count >= 20)
    }

    @Test func preparedFramesPublishWithoutAnAppKitDisplayPass() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = TerminalMetalView(frame: .init(x: 0, y: 0, width: 160, height: 80),
            logicalSize: .init(width: 160, height: 80), device: device)
        let window = NSWindow(contentRect: renderer.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer
        defer { window.close() }
        // An occluded desktop window cannot depend on AppKit's opportunistic
        // display invalidations. Do not show the window or call draw() here.
        #expect(!window.occlusionState.contains(.visible))
        var latestPixel: [UInt8] = []
        var lastSequence: UInt64 = 0
        renderer.onSharedFrame = { descriptor, sequence in
            guard let surface = IOSurfaceLookup(descriptor.surfaceID) else { return }
            IOSurfaceLock(surface, .readOnly, nil)
            let offset = (descriptor.height / 2) * IOSurfaceGetBytesPerRow(surface) + descriptor.width / 2 * 4
            let bytes = IOSurfaceGetBaseAddress(surface).advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            latestPixel = Array(UnsafeBufferPointer(start: bytes, count: 4))
            lastSequence = sequence
            IOSurfaceUnlock(surface, .readOnly, nil)
        }
        var parser = VTParser(columns: 8, rows: 4)
        let render = TerminalRenderConfiguration(pixelMode: .fixed, fixedWidth: 160, fixedHeight: 80,
            columns: 8, rows: 4, fontSize: 12, maxFPS: 30)
        // BGRA channel indices for red, green, blue.
        for (ansi, channel) in [(41, 2), (42, 1), (44, 0)] {
            parser.feed(Data("\u{1B}[\(ansi)m\u{1B}[2J".utf8))
            let previousSequence = lastSequence
            renderer.update(snapshot: parser.grid.snapshot(), configuration: render)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if lastSequence > previousSequence, latestPixel.count == 4,
                   latestPixel[channel] > latestPixel[(channel + 1) % 3],
                   latestPixel[channel] > latestPixel[(channel + 2) % 3] { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(lastSequence > previousSequence)
            let pixel = try #require(latestPixel.count == 4 ? latestPixel : nil)
            #expect(pixel[channel] > pixel[(channel + 1) % 3])
            #expect(pixel[channel] > pixel[(channel + 2) % 3])
        }
    }

    @Test func animatedFramesReachMetalWithoutInvalidatingSwiftUIComposition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraDirectFrames-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
        let model = TerminalWallpaperPreviewModel(selectionStore: selection,
            runtimeStore: .init(appSupportURL: root.appendingPathComponent("runtime")), windowIsVisible: { true })
        let config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh", arguments: ["-c",
            "i=0; while :; do printf '\\033[H%08d' $i; i=$((i+1)); sleep 0.02; done"]),
            render: .init(columns: 80, rows: 24, maxFPS: 30))
        selection.selectTerminal(config)
        defer { selection.selectVideo() }
        let hosting = NSHostingView(rootView: TerminalWallpaperPreviewSurface(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        let deadline = Date().addingTimeInterval(4)
        while model.snapshot == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let renderer = try #require(findRenderer(in: hosting))
        let presentation = TerminalPreviewPresentationModel(model: model)
        var compositionUpdates = 0
        var snapshots = 0
        var frames = 0
        let uiObservation = presentation.objectWillChange.sink { compositionUpdates += 1 }
        let frameObservation = model.$snapshot.dropFirst().sink { _ in snapshots += 1 }
        defer { uiObservation.cancel(); frameObservation.cancel() }
        renderer.onSharedFrame = { _, _ in frames += 1 }
        for _ in 0..<30 {
            renderer.draw(renderer.bounds)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(snapshots >= 5)
        #expect(frames >= 5)
        #expect(compositionUpdates == 0)
        #expect(findRenderer(in: hosting) === renderer)
        var changed = config
        changed.render.scaleMode = .stretch
        selection.selectTerminal(changed)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(presentation.state.configuration?.render.scaleMode == .stretch)
        #expect(compositionUpdates > 0)
        #expect(findRenderer(in: hosting) === renderer)
        selection.selectVideo()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!presentation.state.hasSnapshot && !presentation.state.hasSharedFrame)
    }

    @Test func sharedFramesReachExistingViewWithoutSwiftUIFrameUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraSharedDirectFrames-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalWallpaperRuntimeStore(appSupportURL: root.appendingPathComponent("runtime"),
            launchAgentURL: root.appendingPathComponent("agent.plist"))
        let surface = try #require(IOSurfaceCreate([
            kIOSurfaceWidth: 4, kIOSurfaceHeight: 4, kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: 64, kIOSurfaceAllocSize: 256,
            kIOSurfacePixelFormat: UInt32(0x42475241),
        ] as CFDictionary))
        let descriptor = TerminalSharedFrameDescriptor(surfaceID: IOSurfaceGetID(surface),
            width: 4, height: 4, agentPID: Int(getpid()))
        let config = TerminalWallpaperConfig(command: .init(executable: "/usr/bin/true"))
        try store.saveConfig(config)
        try store.savePID()
        try store.saveSharedFrameDescriptor(descriptor)
        let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
        selection.selectTerminal(config)
        defer { selection.selectVideo() }
        let model = TerminalWallpaperPreviewModel(selectionStore: selection, runtimeStore: store,
            windowIsVisible: { true })
        let hosting = NSHostingView(rootView: TerminalWallpaperPreviewSurface(model: model))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.orderOut(nil); window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        func sharedView(_ view: NSView) -> TerminalIOSurfacePreviewView? {
            if let view = view as? TerminalIOSurfacePreviewView { return view }
            return view.subviews.lazy.compactMap(sharedView).first
        }
        let renderer = try #require(sharedView(hosting))
        let presentation = TerminalPreviewPresentationModel(model: model)
        var compositionUpdates = 0
        let observation = presentation.objectWillChange.sink { compositionUpdates += 1 }
        defer { observation.cancel() }
        // Visibility refresh requests the current surface again, using exactly
        // the same frame publisher as installed wallpaper notifications.
        for _ in 0..<100 { model.previewVisibilityDidChange() }
        #expect(renderer.lastSequence == model.frameSequence)
        #expect(renderer.lastSequence >= 100)
        #expect(sharedView(hosting) === renderer)
        #expect(compositionUpdates == 0)
        #expect(!model.previewProcessIsRunning)
        withExtendedLifetime(surface) {}
    }

    @Test func nyancatPreviewHasNoBlackRightOrBottomEdgeAfterResize() async throws {
        guard let executable = TerminalExecutableLocator.resolve("nyancat") else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraNyanEdges-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
        let model = TerminalWallpaperPreviewModel(selectionStore: selection,
            runtimeStore: .init(appSupportURL: root.appendingPathComponent("runtime")), windowIsVisible: { true })
        let config = TerminalWallpaperConfig(command: .init(executable: executable, arguments: ["-n", "-s"]))
        selection.selectTerminal(config)
        defer { selection.selectVideo() }
        try await Task.sleep(nanoseconds: 600_000_000)
        let snapshot = try #require(model.snapshot)
        // The real CLI leaves both of these cells untouched in its odd-width grid.
        #expect(snapshot.cell(column: snapshot.columns - 1, row: 0).style.background == .default)
        #expect(snapshot.cell(column: 0, row: snapshot.rows - 1).style.background == .default)
        let hosting = NSHostingView(rootView: TerminalWallpaperPreviewSurface(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.orderOut(nil); window.close() }
        for size in [CGSize(width: 760, height: 480), CGSize(width: 1480, height: 540), CGSize(width: 540, height: 960)] {
            window.setContentSize(size)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            let renderer = try #require(findRenderer(in: hosting))
            var frame: (Data, Int, Int)?
            renderer.onLockScreenFrame = { frame = ($0, $1, $2) }
            renderer.setLockScreenCaptureEnabled(true)
            let deadline = Date().addingTimeInterval(4)
            while frame == nil && Date() < deadline {
                renderer.draw(renderer.bounds)
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let (pixels, width, height) = try #require(frame)
            // GPU readback is BGRA. Check the reserved column and row, and their
            // intersection, rather than accepting a merely nonempty frame.
            for (x, y) in [(width - 1, height / 2), (width / 2, height - 1), (width - 1, height - 1)] {
                let offset = (y * width + x) * 4
                #expect(abs(Int(pixels[offset]) - 95) <= 1)
                #expect(pixels[offset + 1] == 0 && pixels[offset + 2] == 0)
            }
            renderer.setLockScreenCaptureEnabled(false)
            #expect(selection.terminalConfiguration == config.normalized())
            #expect(model.snapshot?.columns == snapshot.columns && model.snapshot?.rows == snapshot.rows)
        }
    }

    @Test(arguments: TerminalScaleMode.allCases)
    func resizingScalesExistingCanvasWithoutExpandingTerminal(mode: TerminalScaleMode) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuraPreviewWindowResize-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = WallpaperPreviewSelectionStore(selectionURL: root.appendingPathComponent("selection.json"))
        let model = TerminalWallpaperPreviewModel(selectionStore: selection,
            runtimeStore: .init(appSupportURL: root.appendingPathComponent("runtime")), windowIsVisible: { true })
        // An incremental animation paints its initial canvas only once. Enlarging
        // its PTY would create the unpainted region shown in the reported bug.
        let script = "printf '\\033[45m'; i=0; while [ $i -lt 1920 ]; do printf ' '; i=$((i+1)); done; while :; do sleep 0.1; done"
        let config = TerminalWallpaperConfig(command: .init(executable: "/bin/sh", arguments: ["-c", script]),
            render: .init(columns: 80, rows: 24, fontSize: 18, scaleMode: mode, textScale: 1))
        selection.selectTerminal(config)
        defer { selection.selectVideo() }
        let hosting = NSHostingView(rootView: TerminalWallpaperPreviewSurface(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.orderOut(nil); window.close() }
        let deadline = Date().addingTimeInterval(4)
        while model.snapshot == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let initial = try #require(model.snapshot)
        let generation = model.previewGeneration
        var firstRenderer: TerminalMetalView?
        for size in [CGSize(width: 760, height: 480), CGSize(width: 1480, height: 540), CGSize(width: 540, height: 960), CGSize(width: 760, height: 480)] {
            window.setContentSize(size)
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 150_000_000)
            hosting.layoutSubtreeIfNeeded()
            let renderer = try #require(findRenderer(in: hosting))
            if let firstRenderer { #expect(renderer === firstRenderer) }
            else { firstRenderer = renderer }
            let frame = renderer.convert(renderer.bounds, to: hosting)
            let viewport = hosting.bounds
            // Every mode uses the full viewport. The GPU scales the source
            // inside it; the view hierarchy must not apply another Fit/Fill.
            #expect(abs(frame.width - viewport.width) < 1 && abs(frame.height - viewport.height) < 1)
            #expect(abs(frame.midX - viewport.midX) < 1 && abs(frame.midY - viewport.midY) < 1)
            #expect(model.snapshot?.columns == initial.columns && model.snapshot?.rows == initial.rows)
            #expect(model.previewGeneration == generation)
            #expect(selection.terminalConfiguration == config.normalized())
        }
    }

    private func findRenderer(in view: NSView) -> TerminalMetalView? {
        if let renderer = view as? TerminalMetalView { return renderer }
        for child in view.subviews {
            if let renderer = findRenderer(in: child) { return renderer }
        }
        return nil
    }
}
