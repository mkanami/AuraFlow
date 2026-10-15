import AppKit
import CoreText
import Foundation

enum TerminalFontResolver {
    static let systemMonospaceFamily = "System Monospace"
    private struct Key: Hashable {
        let family: String
        let size: CGFloat
        let bold: Bool
    }
    // The shared cache owns its lock; every dictionary access below holds it.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var values: [Key: CTFont] = [:]
    }
    private static let cache = Cache()

    static func font(family: String, size: CGFloat, bold: Bool = false) -> CTFont {
        let normalizedFamily = family.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Key(family: normalizedFamily, size: size, bold: bold)
        cache.lock.lock()
        let cached = cache.values[key]
        cache.lock.unlock()
        if let cached { return cached }
        let font = resolveFont(family: normalizedFamily, size: size, bold: bold)
        cache.lock.lock()
        // Font-size sliders must not retain an unbounded set of fonts.
        if cache.values.count >= 64 { cache.values.removeAll(keepingCapacity: true) }
        cache.values[key] = font
        cache.lock.unlock()
        return font
    }

    private static func resolveFont(family normalizedFamily: String, size: CGFloat, bold: Bool) -> CTFont {
        let usesSystemMonospace = [
            systemMonospaceFamily,
            "monospace",
            ".AppleSystemUIFontMonospaced",
        ].contains { $0.caseInsensitiveCompare(normalizedFamily) == .orderedSame }

        let baseFont: CTFont
        if usesSystemMonospace {
            let weight: NSFont.Weight = bold ? .bold : .regular
            baseFont = NSFont.monospacedSystemFont(ofSize: size, weight: weight) as CTFont
        } else {
            baseFont = CTFontCreateWithName(
                (normalizedFamily.isEmpty ? "System Monospace" : normalizedFamily) as CFString,
                size,
                nil
            )
        }

        guard bold, !usesSystemMonospace,
              let boldFont = CTFontCreateCopyWithSymbolicTraits(
                baseFont,
                size,
                nil,
                .traitBold,
                .traitBold
              )
        else {
            return baseFont
        }
        return boldFont
    }
}
