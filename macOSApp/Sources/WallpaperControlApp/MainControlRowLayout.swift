import SwiftUI

/// Five stable actions per row: playback + source, then library + utilities.
struct MainControlRowLayout: Layout {
    enum Row { case playback, library }

    static let buttonHeight: CGFloat = 32
    static let spacing: CGFloat = 8
    let row: Row

    static func usesCompactTitles(contentWidth: CGFloat) -> Bool {
        contentWidth < 900
    }

    func frames(width: CGFloat, idealWidths: [CGFloat]) -> [CGRect] {
        guard idealWidths.count == 5 else { return [] }
        let width = max(0, width)
        let spacing = Self.spacing
        let height = Self.buttonHeight
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
            let libraryWidth = max(0, (width - height * 2 - spacing * 4) / 3)
            return (0..<3).map {
                CGRect(x: CGFloat($0) * (libraryWidth + spacing), y: 0, width: libraryWidth, height: height)
            } + (0..<2).map {
                CGRect(x: width - height * 2 - spacing + CGFloat($0) * (height + spacing),
                       y: 0, width: height, height: height)
            }
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideals = idealWidths(subviews)
        return CGSize(width: proposal.width ?? (ideals.reduce(0, +) + Self.spacing * 4),
                      height: Self.buttonHeight)
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
