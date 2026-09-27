@testable import AuraTerminalWallpaperAgent
import AuraTerminalWallpaperCore
import Foundation
import Metal
import Testing

@Test func terminalTextureKeepsTopAndBottomRowsUpright() {
    let topLeft = TerminalTextureOrientation.fullScreenQuad.first {
        $0.position == SIMD2<Float>(-1, 1)
    }
    let bottomLeft = TerminalTextureOrientation.fullScreenQuad.first {
        $0.position == SIMD2<Float>(-1, -1)
    }

    // A marker in terminal row zero must sample the top of the texture and
    // one in the last row must sample the bottom.
    #expect(topLeft?.uv == SIMD2<Float>(0, 0))
    #expect(bottomLeft?.uv == SIMD2<Float>(0, 1))
}

@Test func coreTextGlyphsStayInsideTheirTerminalRow() {
    let configuration = TerminalRenderConfiguration(fontSize: 18, textScale: 1)
    let metrics = TerminalFontMetrics.cellMetrics(for: configuration)
    for glyph in ["~", "^", "/", "A"] {
        let mask = CoreTextGlyphAtlas(atlasSize: 512).rasterizeForTesting(
            text: glyph,
            fontSize: configuration.effectiveFontSize,
            cellWidth: Int(ceil(metrics.width)),
            cellHeight: Int(ceil(metrics.height))
        )
        let inkRows = mask.pixels.withUnsafeBytes { rawBuffer -> [Int] in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return (0..<mask.height).filter { row in
                (0..<mask.width).contains { column in
                    bytes[row * mask.width + column] > 20
                }
            }
        }
        #expect(!inkRows.isEmpty)
        #expect((inkRows.min() ?? mask.height) >= 0)
        #expect((inkRows.max() ?? mask.height) < mask.height)
    }
}

@Test func terminalMetalPreparationUpdatesOnlyChangedCells() {
    let configuration = TerminalRenderConfiguration(fontSize: 12, textScale: 1)
    let metrics = TerminalFontMetrics.cellMetrics(for: configuration)
    let width = Int(ceil(metrics.width * 20))
    let height = Int(ceil(metrics.height * 4))
    let renderer = CoreTextGlyphAtlas(atlasSize: 1024)
    var grid = TerminalGrid(columns: 20, rows: 4)

    let initial = renderer.prepare(
        snapshot: grid.snapshot(),
        configuration: configuration,
        width: width,
        height: height,
        fontPixelScale: 1
    )
    #expect(initial.fullInstances != nil)
    #expect(initial.instanceCount == 80)

    grid.put("A")
    let changed = renderer.prepare(
        snapshot: grid.snapshot(),
        configuration: configuration,
        width: width,
        height: height,
        fontPixelScale: 1
    )
    #expect(changed.fullInstances == nil)
    #expect(changed.instanceUpdates.count == 1)
    #expect(changed.requiresPresentation)

    grid.setCursorVisible(false)
    let unchangedCells = renderer.prepare(
        snapshot: grid.snapshot(),
        configuration: configuration,
        width: width,
        height: height,
        fontPixelScale: 1
    )
    #expect(unchangedCells.instanceUpdates.isEmpty)
    #expect(!unchangedCells.requiresPresentation)
}

@Test @MainActor func terminalRendererCoalescesRapidSnapshotsToNewestRevision() async throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let view = TerminalMetalView(
        frame: CGRect(x: 0, y: 0, width: 240, height: 90),
        logicalSize: CGSize(width: 240, height: 90),
        device: device
    )
    var grid = TerminalGrid(columns: 20, rows: 4)
    let configuration = TerminalRenderConfiguration(fontSize: 12, textScale: 1)
    for index in 0..<40 {
        grid.moveCursor(column: index % 20, row: index / 20)
        grid.put("X")
        view.update(snapshot: grid.snapshot(), configuration: configuration)
    }

    let latestRevision = grid.snapshot().revision
    let deadline = Date().addingTimeInterval(3)
    while view.displayedRevision != latestRevision && Date() < deadline {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(view.displayedRevision == latestRevision)
}
