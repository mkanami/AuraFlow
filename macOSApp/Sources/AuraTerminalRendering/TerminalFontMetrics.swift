import CoreText
import Foundation
import AuraTerminalWallpaperCore

public struct TerminalCellMetrics: Equatable {
    public let width: Double
    public let height: Double
}

public enum TerminalFontMetrics {
    private struct Key: Hashable {
        let family: String
        let size: Double
        let spacing: Double
    }
    // The shared cache owns its lock; every dictionary access below holds it.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var values: [Key: TerminalCellMetrics] = [:]
    }
    private static let cache = Cache()

    public static func cellMetrics(for configuration: TerminalRenderConfiguration) -> TerminalCellMetrics {
        cellMetrics(
            family: configuration.fontFamily,
            pointSize: configuration.effectiveFontSize,
            cellSpacing: configuration.cellSpacing
        )
    }

    static func cellMetrics(
        family: String,
        pointSize: Double,
        cellSpacing: Double = 0
    ) -> TerminalCellMetrics {
        let key = Key(family: family, size: max(pointSize, 1), spacing: max(cellSpacing, 0))
        cache.lock.lock()
        let cached = cache.values[key]
        cache.lock.unlock()
        if let cached { return cached }
        let font = TerminalFontResolver.font(
            family: family,
            size: CGFloat(max(pointSize, 1))
        )
        let metrics = cellMetrics(font: font, cellSpacing: CGFloat(max(cellSpacing, 0)))
        cache.lock.lock()
        if cache.values.count >= 64 { cache.values.removeAll(keepingCapacity: true) }
        cache.values[key] = metrics
        cache.lock.unlock()
        return metrics
    }

    static func cellMetrics(font: CTFont, cellSpacing: CGFloat = 0) -> TerminalCellMetrics {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "M", attributes: [.font: font])
        )
        let glyphWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font)
        let spacing = max(cellSpacing, 0)
        return TerminalCellMetrics(
            width: Double(max(glyphWidth + spacing, 1)),
            height: Double(max(lineHeight + spacing, 1))
        )
    }
}
