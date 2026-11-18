import Foundation

/// Exclude text-bearing media rather than masking it with a different poster.
/// The registry includes visually reviewed source pages and poster aliases.
enum CatalogContentPolicy {
    private struct Exclusion: Decodable {
        let id: String
        let sourcePageURL: URL?
        let previewImageURL: URL?
    }
    private static let exclusions: [Exclusion] = {
        guard let url = Bundle.module.url(forResource: "catalog-content-exclusions", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Exclusion].self, from: data)) ?? []
    }()
    private static let ids = Set(exclusions.map { normalized($0.id) })
    private static let pages = Set(exclusions.compactMap { $0.sourcePageURL.map(urlKey) })
    private static let posters = Set(exclusions.compactMap { $0.previewImageURL.map(urlKey) })
    // Rules and the bundled registry are immutable for the life of the app.
    // Include all inspected metadata, so changing a title/page/poster cannot
    // reuse an old approval. NSCache bounds memory and supports provider tasks.
    private static let decisions = DecisionCache()

    // NSCache synchronizes lookups and insertion. Keep it private and exchange
    // immutable String/Bool values rather than sharing SDK objects with callers.
    private final class DecisionCache: @unchecked Sendable {
        private let cache = NSCache<NSString, NSNumber>()
        init() {
            cache.countLimit = 2048
            cache.totalCostLimit = 4 * 1024 * 1024
        }
        func value(forKey key: String) -> Bool? { cache.object(forKey: key as NSString)?.boolValue }
        func store(_ value: Bool, forKey key: String) {
            cache.setObject(NSNumber(value: value), forKey: key as NSString, cost: key.utf16.count * 2)
        }
    }
    private static let watermarkFree = try! NSRegularExpression(pattern: #"\b(?:no|without)[\s-]+watermarks?\b|\bwatermark[\s-]+free\b"#)
    private static let branded = try! NSRegularExpression(pattern: #"[♬♫♪][\s-]*live[\s-]*wallpaper|\bwatermark(?:ed)?\b|\bnightcore\b"#)
    private static let warningPoster = try! NSRegularExpression(pattern: #"(?:^|[/_.-])nsfw(?:[/_.-]|$)"#)

    static func allows(_ wallpaper: CatalogWallpaper) -> Bool {
        allows(id: wallpaper.id, title: wallpaper.title, page: wallpaper.sourcePageURL, poster: wallpaper.previewImageURL)
    }

    static func allows(_ wallpaper: DownloadedCatalogWallpaper) -> Bool {
        allows(id: wallpaper.wallpaperID, title: wallpaper.title, page: wallpaper.sourcePageURL, poster: wallpaper.previewImageURL)
    }

    private static func allows(id: String, title: String, page: URL?, poster: URL?) -> Bool {
        let raw = [id, title, page?.absoluteString ?? "", poster?.absoluteString ?? ""]
        let key = raw.joined(separator: "\u{0}")
        if let decision = decisions.value(forKey: key) { return decision }
        let allowed = evaluate(id: id, page: page, poster: poster, fields: raw.map(normalized))
        decisions.store(allowed, forKey: key)
        return allowed
    }

    private static func evaluate(id: String, page: URL?, poster: URL?, fields: [String]) -> Bool {
        // A warning image is not an approved artwork preview. Catch new IDs
        // and cache aliases too, rather than hiding the warning behind an
        // unreviewed frame from the video.
        if let poster {
            let path = normalized(poster.path)
            if warningPoster.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil { return false }
        }
        let text = fields.joined(separator: " ")
        let compact = text.filter { $0.isLetter || $0.isNumber }
        if compact.contains("hdsoundi") || compact.contains("wherewordsfailmusicspeaks") { return false }
        // This entire upload family consists of music-channel covers and
        // bumpers. Renaming one page must not bring the family back via search.
        if text.contains("watermark") || text.contains("nightcore") || text.contains(where: { "♬♫♪".contains($0) }) {
            let brandingText = watermarkFree.stringByReplacingMatches(in: text,
                range: NSRange(text.startIndex..., in: text), withTemplate: "")
            if branded.firstMatch(in: brandingText, range: NSRange(brandingText.startIndex..., in: brandingText)) != nil { return false }
        }
        if ids.contains(normalized(id)) { return false }
        if let page, pages.contains(urlKey(page)) { return false }
        if let poster, posters.contains(urlKey(poster)) { return false }
        return true
    }

    static func validate(_ wallpaper: CatalogWallpaper) throws {
        guard allows(wallpaper) else { throw ExcludedArtwork() }
    }

    private static func normalized(_ value: String) -> String {
        (value.removingPercentEncoding ?? value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func urlKey(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        parts?.query = nil
        return normalized(parts?.string ?? url.absoluteString).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private struct ExcludedArtwork: LocalizedError {
        var errorDescription: String? { "This wallpaper is no longer available in the catalog." }
    }
}
