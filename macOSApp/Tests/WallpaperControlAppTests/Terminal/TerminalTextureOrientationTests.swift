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
    let width = Int(ceil(metrics.width * 4))
    let height = Int(ceil(metrics.height * 2))

    for glyph in ["~", "^", "/", "A"] {
        var grid = TerminalGrid(columns: 4, rows: 2)
        grid.put(glyph)
        let pixels = CoreTextGlyphAtlas().render(
            snapshot: grid.snapshot(),
            configuration: configuration,
            width: width,
            height: height,
            fontPixelScale: 1
        )
        let inkRows = pixels.withUnsafeBytes { rawBuffer -> [Int] in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return (0..<height).filter { row in
                (0..<width).contains { column in
                    let offset = (row * width + column) * 4
                    return bytes[offset] > 20 || bytes[offset + 1] > 20 || bytes[offset + 2] > 20
                }
            }
        }
        #expect(!inkRows.isEmpty)
        #expect((inkRows.min() ?? height) < Int(metrics.height * 0.75))
        #expect((inkRows.max() ?? height) <= Int(ceil(metrics.height)) + 1)
    }
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
