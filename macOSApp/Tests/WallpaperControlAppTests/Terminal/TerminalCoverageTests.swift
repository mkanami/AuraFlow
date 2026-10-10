import AuraTerminalWallpaperCore
import AuraTerminalRendering
import Foundation
import Testing

@Test func terminalCoveragePreservesExplicitSavedScaleModes() throws {
    let decoder = JSONDecoder()
    for mode in TerminalScaleMode.allCases {
        let data = Data("{\"scaleMode\":\"\(mode.rawValue)\"}".utf8)
        #expect(try decoder.decode(TerminalRenderConfiguration.self, from: data).scaleMode == mode)
    }
}

@Test(arguments: [(3420, 2224), (1920, 1080), (3440, 1440), (1200, 1920), (760, 480)])
func terminalCoverageFillCropsCenteredSourceWithoutChangingGrid(width: Int, height: Int) {
    let render = TerminalRenderConfiguration(columns: 153, rows: 48, fontSize: 18, textScale: 1)
    let metrics = TerminalFontMetrics.cellMetrics(for: render)
    let grid = TerminalRenderGeometry.viewportGrid(configuration: render,
        logicalWidth: Double(width), logicalHeight: Double(height), cellWidth: metrics.width, lineHeight: metrics.height)
    let layout = TerminalRenderGeometry.layout(columns: grid.columns, rows: grid.rows,
        cellWidth: metrics.width, lineHeight: metrics.height,
        targetWidth: Double(width), targetHeight: Double(height), mode: TerminalRenderGeometry.contentScaleMode(.fill))
    #expect(layout.scale.x == layout.scale.y)
    #expect(layout.offsetX <= 0.001 && layout.offsetY <= 0.001)
    #expect(layout.drawnWidth >= Double(width) - 0.001)
    #expect(layout.drawnHeight >= Double(height) - 0.001)
    #expect(grid.columns == 153 && grid.rows == 48)
    #expect(abs(layout.offsetX * 2 + layout.drawnWidth - Double(width)) < 0.001)
    #expect(abs(layout.offsetY * 2 + layout.drawnHeight - Double(height)) < 0.001)
}

@Test(arguments: [(3420, 2224), (1920, 1080), (3440, 1440), (1200, 1920), (760, 480)])
func terminalCoverageTexturePresentationMatchesRasterPolicy(width: Int, height: Int) {
    // A fixed-size texture and an IOSurface use the same normalized quad.
    for mode in TerminalScaleMode.allCases {
        let scale = TerminalRenderGeometry.presentationScale(sourceWidth: 1920, sourceHeight: 1080,
            targetWidth: width, targetHeight: height, mode: mode)
        let x = scale.x * Double(width) / 1920
        let y = scale.y * Double(height) / 1080
        if mode == .fill || mode == .fit {
            if mode == .fill { #expect(scale.x >= 1 - 0.0001 && scale.y >= 1 - 0.0001) }
            else { #expect(scale.x <= 1 + 0.0001 && scale.y <= 1 + 0.0001) }
            #expect(abs(x - y) < 0.0001)
        } else {
            #expect(scale == TerminalScaleFactors(x: 1, y: 1))
        }
    }
}

@Test func terminalResponsiveGridPreservesFitStretchAndSavedDensity() {
    for mode in TerminalScaleMode.allCases {
        let config = TerminalRenderConfiguration(columns: 153, rows: 48, scaleMode: mode)
        let grid = TerminalRenderGeometry.viewportGrid(configuration: config,
            logicalWidth: 500, logicalHeight: 1200, cellWidth: 10, lineHeight: 20)
        #expect(grid.columns == 153 && grid.rows == 48)
        #expect(config.columns == 153 && config.rows == 48)
    }
    let grid = TerminalRenderGeometry.viewportGrid(configuration: .init(),
        logicalWidth: 800, logicalHeight: 600, cellWidth: 10, lineHeight: 20)
    #expect(grid.columns == 80 && grid.rows == 30)
}

@Test(arguments: [(Double.nan, Double.infinity), (0, -1), (Double.greatestFiniteMagnitude, 1)])
func terminalResponsiveGridBoundsInvalidAndExtremeViewports(width: Double, height: Double) {
    for render in [TerminalRenderConfiguration(), .init(columns: 153, rows: 48)] {
        let grid = TerminalRenderGeometry.viewportGrid(configuration: render,
            logicalWidth: width, logicalHeight: height, cellWidth: 10, lineHeight: 20)
        #expect((1...1000).contains(grid.columns) && (1...500).contains(grid.rows))
    }
}
