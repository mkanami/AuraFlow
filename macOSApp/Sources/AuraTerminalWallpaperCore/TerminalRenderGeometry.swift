import Foundation

public struct TerminalPixelSize: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(width, 1)
        self.height = max(height, 1)
    }
}

public struct TerminalScaleFactors: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = max(x, 0.0001)
        self.y = max(y, 0.0001)
    }
}

public struct TerminalRenderLayout: Equatable, Sendable {
    public let scale: TerminalScaleFactors
    public let drawnWidth: Double
    public let drawnHeight: Double
    public let offsetX: Double
    public let offsetY: Double

    public init(
        scale: TerminalScaleFactors,
        drawnWidth: Double,
        drawnHeight: Double,
        offsetX: Double,
        offsetY: Double
    ) {
        self.scale = scale
        self.drawnWidth = drawnWidth
        self.drawnHeight = drawnHeight
        self.offsetX = offsetX
        self.offsetY = offsetY
    }
}

public enum TerminalRenderGeometry {
    public static func pixelSize(
        configuration: TerminalRenderConfiguration,
        drawableWidth: Int,
        drawableHeight: Int
    ) -> TerminalPixelSize {
        let width = configuration.pixelMode == .fixed
            ? configuration.fixedWidth ?? drawableWidth
            : drawableWidth
        let height = configuration.pixelMode == .fixed
            ? configuration.fixedHeight ?? drawableHeight
            : drawableHeight
        return TerminalPixelSize(width: width, height: height)
    }

    public static func automaticGrid(
        logicalWidth: Double,
        logicalHeight: Double,
        cellWidth: Double,
        lineHeight: Double
    ) -> (columns: Int, rows: Int) {
        let safeCellWidth = max(cellWidth.isFinite ? cellWidth : 1, 1)
        let safeLineHeight = max(lineHeight.isFinite ? lineHeight : 1, 1)
        let safeLogicalWidth = max(logicalWidth.isFinite ? logicalWidth : 1, 1)
        let safeLogicalHeight = max(logicalHeight.isFinite ? logicalHeight : 1, 1)
        return (
            min(max(Int(safeLogicalWidth / safeCellWidth), 40), 1000),
            min(max(Int(safeLogicalHeight / safeLineHeight), 20), 500)
        )
    }

    /// Builds the final centered content layout from the same cell metrics used
    /// to rasterize glyphs. Font scaling belongs in those metrics; it must not
    /// be multiplied again after `fit` has selected a scale.
    public static func layout(
        columns: Int,
        rows: Int,
        cellWidth: Double,
        lineHeight: Double,
        targetWidth: Double,
        targetHeight: Double,
        mode: TerminalScaleMode
    ) -> TerminalRenderLayout {
        let contentWidth = Double(max(columns, 1)) * max(cellWidth, 0.0001)
        let contentHeight = Double(max(rows, 1)) * max(lineHeight, 0.0001)
        let scale = scaleFactors(
            contentWidth: contentWidth,
            contentHeight: contentHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight,
            mode: mode
        )
        let drawnWidth = contentWidth * scale.x
        let drawnHeight = contentHeight * scale.y
        return TerminalRenderLayout(
            scale: scale,
            drawnWidth: drawnWidth,
            drawnHeight: drawnHeight,
            offsetX: (targetWidth - drawnWidth) * 0.5,
            offsetY: (targetHeight - drawnHeight) * 0.5
        )
    }

    /// Converts point-sized fonts into the pixel coordinates used by the
    /// Metal/CoreGraphics render target. A fixed output resolution may have a
    /// different pixel density from the native display, so derive the density
    /// from the actual target texture rather than assuming Retina is always 2x.
    public static func pixelScaleFactor(
        pixelWidth: Int,
        pixelHeight: Int,
        logicalWidth: Double,
        logicalHeight: Double
    ) -> Double {
        let horizontal = Double(max(pixelWidth, 1)) / max(logicalWidth, 1)
        let vertical = Double(max(pixelHeight, 1)) / max(logicalHeight, 1)
        return max(min(horizontal, vertical), 0.01)
    }

    public static func scaleFactors(
        contentWidth: Double,
        contentHeight: Double,
        targetWidth: Double,
        targetHeight: Double,
        mode: TerminalScaleMode
    ) -> TerminalScaleFactors {
        let safeContentWidth = max(contentWidth, 0.0001)
        let safeContentHeight = max(contentHeight, 0.0001)
        let x = max(targetWidth, 0) / safeContentWidth
        let y = max(targetHeight, 0) / safeContentHeight
        switch mode {
        case .fit:
            let scale = min(x, y)
            return TerminalScaleFactors(x: scale, y: scale)
        case .fill:
            let scale = max(x, y)
            return TerminalScaleFactors(x: scale, y: scale)
        case .stretch:
            return TerminalScaleFactors(x: x, y: y)
        }
    }
}
