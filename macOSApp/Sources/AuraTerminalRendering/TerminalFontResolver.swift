import AppKit
import CoreText
import Foundation

enum TerminalFontResolver {
    static let systemMonospaceFamily = "System Monospace"

    static func font(family: String, size: CGFloat, bold: Bool = false) -> CTFont {
        let normalizedFamily = family.trimmingCharacters(in: .whitespacesAndNewlines)
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
