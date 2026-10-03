import SwiftUI

/// Expand normally in small windows, then taper toward a comfortable desktop width.
enum MainControlPanelMetrics {
    static func width(availableWidth: CGFloat) -> CGFloat {
        let available = max(0, availableWidth)
        let extra = max(0, available - 900)
        return min(available, 900 + 280 * extra / (280 + extra))
    }

    static func buttonHeight(panelWidth: CGFloat, isVeryCompactByHeight: Bool) -> CGFloat {
        guard !isVeryCompactByHeight else { return 22 }
        let progress = min(max((panelWidth - 900) / 200, 0), 1)
        let eased = progress * progress * (3 - 2 * progress)
        // Large windows need only a little extra breathing room, not oversized controls.
        return 22 + 2 * eased
    }
}

private struct MainControlButtonHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 22
}

extension EnvironmentValues {
    var mainControlButtonHeight: CGFloat {
        get { self[MainControlButtonHeightKey.self] }
        set { self[MainControlButtonHeightKey.self] = newValue }
    }
}

/// Five stable actions per row: playback + source, then utilities + library.
struct MainControlRowLayout: Layout {
    enum Row { case playback, library }

    static let buttonHeight: CGFloat = 22
    static let utilityButtonWidth: CGFloat = 32
    static let spacing: CGFloat = 8
    let row: Row
    var height: CGFloat = buttonHeight

    static func usesCompactTitles(contentWidth: CGFloat) -> Bool {
        contentWidth < 900
    }

    func frames(width: CGFloat, idealWidths: [CGFloat]) -> [CGRect] {
        guard idealWidths.count == 5 else { return [] }
        let width = max(0, width)
        let spacing = Self.spacing
        switch row {
        case .playback:
            let preferred = max(104, idealWidths.prefix(4).max() ?? 0)
            let sourceMinimum = idealWidths[4]
            let buttonWidth = min(preferred, max(0, (width - sourceMinimum - spacing * 4) / 4))
            let remaining = max(0, width - buttonWidth * 4 - spacing * 4)
            let sourceWidth = min(remaining, max(sourceMinimum, 228))
            return (0..<4).map {
                CGRect(x: CGFloat($0) * (buttonWidth + spacing), y: 0, width: buttonWidth, height: height)
            } + [CGRect(x: width - sourceWidth, y: 0, width: sourceWidth, height: height)]
        case .library:
            let utilityWidth = Self.utilityButtonWidth
            let libraryWidth = max(0, (width - utilityWidth * 2 - spacing * 4) / 3)
            return (0..<2).map {
                CGRect(x: CGFloat($0) * (utilityWidth + spacing),
                       y: 0, width: utilityWidth, height: height)
            } + (0..<3).map {
                CGRect(x: (utilityWidth + spacing) * 2 + CGFloat($0) * (libraryWidth + spacing),
                       y: 0, width: libraryWidth, height: height)
            }
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = idealWidths(subviews)
        return CGSize(width: proposal.width ?? (ideals.reduce(0, +) + Self.spacing * 4),
                      height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = frames(width: bounds.width, idealWidths: idealWidths(subviews))
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func idealWidths(_ subviews: Subviews) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(.unspecified).width }
    }
}
