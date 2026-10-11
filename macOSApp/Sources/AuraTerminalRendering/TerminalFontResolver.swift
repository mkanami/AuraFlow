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
    private static let cacheLock = NSLock()
    private static var cachedFonts: [Key: CTFont] = [:]

    static func font(family: String, size: CGFloat, bold: Bool = false) -> CTFont {
        let normalizedFamily = family.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Key(family: normalizedFamily, size: size, bold: bold)
        cacheLock.lock()
        let cached = cachedFonts[key]
        cacheLock.unlock()
        if let cached { return cached }
        let font = resolveFont(family: normalizedFamily, size: size, bold: bold)
        cacheLock.lock()
        // Font-size sliders must not retain an unbounded set of fonts.
        if cachedFonts.count >= 64 { cachedFonts.removeAll(keepingCapacity: true) }
        cachedFonts[key] = font
        cacheLock.unlock()
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
