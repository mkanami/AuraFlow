import Foundation

actor MotionBGSAnimeNatureSource: WallpaperCatalogProviding, CatalogCacheClearing {
    private let baseURL = URL(string: "https://motionbgs.com/")!
    private let startPath = "tag:anime-nature/"
    private let session: URLSession

    init(session: URLSession = MotionBGSAnimeNatureSource.makeSession()) {
        self.session = session
    }

    func clearCache() async {
        if let cacheURL = try? catalogCacheURL() {
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    func loadCachedCatalog() async -> [CatalogWallpaper]? {
        guard let cacheURL = try? catalogCacheURL(),
              let data = try? Data(contentsOf: cacheURL),
              let envelope = try? JSONDecoder().decode(MotionBGSCatalogCacheEnvelope.self, from: data) else {
            return nil
        }
        return envelope.wallpapers.isEmpty ? nil : envelope.wallpapers
    }

    func fetchCatalog() async throws -> [CatalogWallpaper] {
        try await fetchCatalog(progress: { _ in })
    }

    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        let items = try await fetchListingItems { partialItems in
            await progress(Self.placeholderWallpapers(from: partialItems))
        }
        let wallpapers = Self.placeholderWallpapers(from: items)
        guard !wallpapers.isEmpty else {
            throw MotionBGSSourceError.unavailable("MotionBGS returned no Anime Nature wallpapers.")
        }
        try persistCatalog(wallpapers)
        return wallpapers
    }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        if let source = wallpaper.sources.first {
            return source.url
        }
        guard let pageURL = wallpaper.sourcePageURL else {
            throw URLError(.badURL)
        }
        let data = try await fetchData(pageURL)
        guard let html = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        let item = MotionBGSListItem(
            title: wallpaper.title,
            pageURL: pageURL,
            previewImageURL: wallpaper.previewImageURL
        )
        guard let resolvedWallpaper = MotionBGSParser.parseDetailPage(
            html: html,
            item: item,
            baseURL: baseURL
        ),
        let source = resolvedWallpaper.sources.first else {
            throw URLError(.fileDoesNotExist)
        }
        return source.url
    }

    private func fetchListingItems(
        progress: @escaping @Sendable ([MotionBGSListItem]) async -> Void
    ) async throws -> [MotionBGSListItem] {
        var currentPath: String? = startPath
        var items: [MotionBGSListItem] = []

        while let path = currentPath {
            let data = try await fetchData(baseURL.appending(path: path))
            guard let html = String(data: data, encoding: .utf8) else {
                break
            }
            let page = MotionBGSParser.parseListingPage(html: html, baseURL: baseURL)
            items.append(contentsOf: page.items)
            await progress(Self.deduplicateItems(items))
            currentPath = page.nextPath
        }

        return Self.deduplicateItems(items)
    }

    private func fetchData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw MotionBGSSourceError.unavailable("MotionBGS returned HTTP \(httpResponse.statusCode).")
        }
        return data
    }

    private func persistCatalog(_ wallpapers: [CatalogWallpaper]) throws {
        let envelope = MotionBGSCatalogCacheEnvelope(updatedAt: Date(), wallpapers: wallpapers)
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: try catalogCacheURL(), options: .atomic)
    }

    private func catalogCacheURL() throws -> URL {
        try catalogSupportDirectory().appendingPathComponent("motionbgs-anime-nature-cache.json")
    }

    private func catalogSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("AuraFlow", isDirectory: true)
            .appendingPathComponent("Catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func deduplicateItems(_ items: [MotionBGSListItem]) -> [MotionBGSListItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.pageURL.absoluteString).inserted }
    }

    private static func placeholderWallpapers(from items: [MotionBGSListItem]) -> [CatalogWallpaper] {
        deduplicateItems(items).map { item in
            CatalogWallpaper(
                id: "motionbgs-anime-nature-\(item.pageURL.lastPathComponent)",
                title: item.title,
                category: "Anime Nature",
                attribution: "MotionBGS",
                previewImageURL: item.previewImageURL,
                sourcePageURL: item.pageURL,
                sources: []
            )
        }
    }

    private static func shouldEmitProgress(foundCount: Int, previousCount: Int) -> Bool {
        guard foundCount > previousCount else { return false }
        return foundCount <= 8 || foundCount - previousCount >= 4
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 12
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

struct MotionBGSListItem: Hashable {
    let title: String
    let pageURL: URL
    let previewImageURL: URL?
}

enum MotionBGSParser {
    struct ListingPage {
        let items: [MotionBGSListItem]
        let nextPath: String?
    }

    static func parseListingPage(html: String, baseURL: URL) -> ListingPage {
        let normalized = decodeHTMLEntities(html)
        let pattern = #"<a title="([^"]+) live wallpaper" href=([^ >]+)>.*?<img[^>]+src=([^ >]+)[^>]*>.*?<span class=ttl>([^<]+)</span>"#
        let items = regexMatches(pattern: pattern, in: normalized).compactMap { match -> MotionBGSListItem? in
            guard match.count >= 5,
                  let pageURL = absoluteURL(from: match[2], baseURL: baseURL) else {
                return nil
            }
            let previewImageURL = absoluteURL(from: match[3], baseURL: baseURL)
            let title = cleanupTitle(match[4].isEmpty ? match[1] : match[4])
            return MotionBGSListItem(title: title, pageURL: pageURL, previewImageURL: previewImageURL)
        }

        let nextPath = firstMatch(in: normalized, pattern: #"<link href=https://motionbgs\.com/([^" ]+) rel=next>"#)
            ?? firstMatch(in: normalized, pattern: #"<a href=/(tag:anime-nature/\d+/)> Next"#)

        return ListingPage(items: items, nextPath: nextPath)
    }

    static func parseDetailPage(html: String, item: MotionBGSListItem, baseURL: URL) -> CatalogWallpaper? {
        let normalized = decodeHTMLEntities(html)
        let title = cleanupTitle(
            firstMatch(in: normalized, pattern: #"<h1><span>([^<]+)</span> Live Wallpaper</h1>"#)
                ?? firstMatch(in: normalized, pattern: #"<meta content="([^"]+) Live Wallpaper" property=og:title>"#)
                ?? item.title
        )

        let previewImageURL = firstMatch(in: normalized, pattern: #"<meta content=(https://motionbgs\.com/[^ >]+) property=og:image>"#)
            .flatMap(URL.init(string:))
            ?? item.previewImageURL

        let category = firstMatch(in: normalized, pattern: #"<li><div><a href=/tag:anime-nature/>Anime Nature</a></div></li>"#) != nil
            ? "Anime Nature"
            : "Anime Nature"

        let sources = regexMatches(
            pattern: #"<a href=(/dl/(?:4k|hd)/\d+/?)[^>]*>.*?<span class=font-bold>(4K|HD)</span>.*?<div class=text-xs>(\d{3,5})x(\d{3,5}) mp4 file</div>"#,
            in: normalized
        ).compactMap { match -> CatalogVideoSource? in
            guard match.count >= 5,
                  let url = absoluteURL(from: match[1], baseURL: baseURL),
                  let width = Int(match[3]),
                  let height = Int(match[4]) else {
                return nil
            }
            return CatalogVideoSource(url: url, width: width, height: height)
        }

        guard !sources.isEmpty else {
            return nil
        }

        return CatalogWallpaper(
            id: "motionbgs-anime-nature-\(item.pageURL.lastPathComponent)",
            title: title,
            category: category,
            attribution: "MotionBGS",
            previewImageURL: previewImageURL,
            sourcePageURL: item.pageURL,
            sources: sources.sorted {
                ($0.width * $0.height) > ($1.width * $1.height)
            }
        )
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        regexMatches(pattern: pattern, in: text).first.flatMap { match in
            match.count > 1 ? match[1] : nil
        }
    }

    private static func regexMatches(pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).map { match in
            (0..<match.numberOfRanges).compactMap { index in
                guard let range = Range(match.range(at: index), in: text) else {
                    return nil
                }
                return String(text[range])
            }
        }
    }

    private static func absoluteURL(from value: String, baseURL: URL) -> URL? {
        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        if trimmed.hasPrefix("/") {
            return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    private static func cleanupTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: #"[\n\r\t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        var decoded = value
        let replacements = [
            "&amp;": "&",
            "&#038;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&nbsp;": " ",
            "&ndash;": "-",
            "–": "-",
        ]
        for (entity, replacement) in replacements {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }
        return decoded
    }
}

private struct MotionBGSCatalogCacheEnvelope: Codable {
    let updatedAt: Date
    let wallpapers: [CatalogWallpaper]
}

enum MotionBGSSourceError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}
