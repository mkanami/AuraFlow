import Foundation

/// A bounded, directional preview working set for the lazy catalog grid.
/// Keeping this calculation independent from SwiftUI makes fast-scroll
/// behavior deterministic and cheap to test.
struct CatalogPreviewViewportPlan: Equatable, Sendable {
    let visibleIDs: [String]
    let lookaheadIDs: [String]
    let protectedIDs: Set<String>
    let centerIndex: Int

    static func make(
        wallpaperIDs: [String],
        visibleIDs: Set<String>,
        previousCenterIndex: Int?
    ) -> CatalogPreviewViewportPlan? {
        guard !wallpaperIDs.isEmpty, !visibleIDs.isEmpty else { return nil }

        let indicesByID = Dictionary(
            uniqueKeysWithValues: wallpaperIDs.enumerated().map { ($0.element, $0.offset) }
        )
        let visibleIndices = visibleIDs.compactMap { indicesByID[$0] }.sorted()
        guard let firstVisible = visibleIndices.first,
              let lastVisible = visibleIndices.last else { return nil }

        let orderedVisibleIDs = visibleIndices.map { wallpaperIDs[$0] }
        let centerIndex = (firstVisible + lastVisible) / 2
        let isMovingForward = previousCenterIndex.map { centerIndex >= $0 } ?? true

        // At wide window sizes a single row can contain many cards. Use the
        // current visible count to cover roughly one full row ahead, while
        // bounding the amount of background network work.
        let directionalCount = min(18, max(8, visibleIndices.count))
        let reverseCount = min(4, max(2, visibleIndices.count / 3))

        let directionalRange: Range<Int>
        let reverseRange: Range<Int>
        if isMovingForward {
            directionalRange = boundedRange(
                from: lastVisible + 1,
                to: lastVisible + 1 + directionalCount,
                count: wallpaperIDs.count
            )
            reverseRange = boundedRange(
                from: firstVisible - reverseCount,
                to: firstVisible,
                count: wallpaperIDs.count
            )
        } else {
            directionalRange = boundedRange(
                from: firstVisible - directionalCount,
                to: firstVisible,
                count: wallpaperIDs.count
            )
            reverseRange = boundedRange(
                from: lastVisible + 1,
                to: lastVisible + 1 + reverseCount,
                count: wallpaperIDs.count
            )
        }

        var seen = Set(orderedVisibleIDs)
        let orderedLookaheadIndices = isMovingForward
            ? Array(directionalRange) + Array(reverseRange.reversed())
            : Array(directionalRange.reversed()) + Array(reverseRange)
        let lookaheadIDs = orderedLookaheadIndices.compactMap { index -> String? in
            let id = wallpaperIDs[index]
            return seen.insert(id).inserted ? id : nil
        }

        return CatalogPreviewViewportPlan(
            visibleIDs: orderedVisibleIDs,
            lookaheadIDs: lookaheadIDs,
            protectedIDs: Set(orderedVisibleIDs + lookaheadIDs),
            centerIndex: centerIndex
        )
    }

    private static func boundedRange(from lowerBound: Int, to upperBound: Int, count: Int) -> Range<Int> {
        let lower = min(count, max(0, lowerBound))
        let upper = min(count, max(lower, upperBound))
        return lower..<upper
    }
}
