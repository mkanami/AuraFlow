import AppKit
import AuraTerminalRendering
import AuraTerminalWallpaperCore
import SwiftUI
import Testing
@testable import WallpaperControlApp

@Suite(.serialized) @MainActor
struct TerminalPreviewWindowResizeTests {
    @Test(arguments: [TerminalScaleMode.fill, .fit])
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
        let metrics = TerminalFontMetrics.cellMetrics(for: config.render)
        let sourceAspect = Double(initial.columns) * metrics.width / (Double(initial.rows) * metrics.height)
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
            #expect(abs(frame.width / frame.height - sourceAspect) < 0.01)
            #expect(abs(frame.midX - viewport.midX) < 1 && abs(frame.midY - viewport.midY) < 1)
            if mode == .fill {
                #expect(frame.width >= viewport.width - 1 && frame.height >= viewport.height - 1,
                        "Fill must cover the entire window without an inset after wide and tall resizes")
            } else {
                #expect(frame.width <= viewport.width + 1 && frame.height <= viewport.height + 1)
            }
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
