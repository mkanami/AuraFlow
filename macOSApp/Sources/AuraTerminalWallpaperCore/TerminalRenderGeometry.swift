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
        pixelWidth: Double,
        pixelHeight: Double,
        fontSize: Double
    ) -> (columns: Int, rows: Int) {
        let cellWidth = max(fontSize * 0.62, 1)
        let lineHeight = max(fontSize * 1.25, 1)
        return (
            min(max(Int(pixelWidth / cellWidth), 40), 1000),
            min(max(Int(pixelHeight / lineHeight), 20), 500)
        )
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
