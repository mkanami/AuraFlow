import Foundation

/// Evidence collected from the original video, not its poster or site's tags.
/// Keeping it separate also prevents stale cached cards from inheriting approval.
struct MusicCatalogReview: Codable, Sendable {
    let id: String
    let sourcePageURL: URL
    let previewImageURL: URL
    let originalURL: URL
    let width: Int
    let height: Int
    let fps: Double
    let sampledFrames: Int
    let firstFrameReviewed: Bool
    let posterReviewed: Bool
    let audio: String
    let soundtrackID: String?

    static func bundled() -> [String: Self] {
        guard let url = AppResources.bundle?.url(forResource: "music-catalog-review", withExtension: "json"),
              let data = try? Data(contentsOf: url), let records = try? JSONDecoder().decode([Self].self, from: data)
        else { return [:] }
        return Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func matches(_ item: CatalogWallpaper) -> Bool {
        id == item.id && sourcePageURL == item.sourcePageURL && previewImageURL == item.previewImageURL &&
            soundtrackID == item.soundtrackID && width >= 1920 && height >= 1080 && fps >= 23.5 && sampledFrames >= 6 &&
            firstFrameReviewed && posterReviewed
    }
}
