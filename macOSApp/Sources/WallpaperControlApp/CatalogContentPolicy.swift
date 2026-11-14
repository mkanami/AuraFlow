import Foundation

/// Exclude branded media rather than cropping, blurring or painting over it.
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

    static func allows(_ wallpaper: CatalogWallpaper) -> Bool {
        allows(id: wallpaper.id, title: wallpaper.title, page: wallpaper.sourcePageURL, poster: wallpaper.previewImageURL)
    }

    static func allows(_ wallpaper: DownloadedCatalogWallpaper) -> Bool {
        allows(id: wallpaper.wallpaperID, title: wallpaper.title, page: wallpaper.sourcePageURL, poster: wallpaper.previewImageURL)
    }

    private static func allows(id: String, title: String, page: URL?, poster: URL?) -> Bool {
        let fields = [id, title, page?.absoluteString ?? "", poster?.absoluteString ?? ""].map(normalized)
        let text = fields.joined(separator: " ")
        let compact = text.filter { $0.isLetter || $0.isNumber }
        if compact.contains("hdsoundi") || compact.contains("wherewordsfailmusicspeaks") { return false }
        // This entire upload family consists of music-channel covers and
        // bumpers. Renaming one page must not bring the family back via search.
        let brandingText = text.replacingOccurrences(of: #"\b(?:no|without)[\s-]+watermarks?\b|\bwatermark[\s-]+free\b"#,
                                                     with: "", options: .regularExpression)
        if brandingText.range(of: #"[♬♫♪][\s-]*live[\s-]*wallpaper|\bwatermark(?:ed)?\b|\bnightcore\b"#,
                      options: .regularExpression) != nil { return false }
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
