import Foundation

actor PixabaySource: WallpaperCatalogProviding, CatalogCacheClearing {
    private let baseURL = URL(string: "https://pixabay.com/")!
    private let searchQueries = [
        "scenery",
        "waterfalls",
        "mountain waterfall",
        "river trees",
        "forest misty",
        "falling leaves",
        "waterfall loop",
        "leaves wind",
        "lava lamp",
        "lava abstract",
        "abstract waves",
        "abstract loop",
        "motion graphics",
        "galaxy universe",
    ]
    private let apiPageSize = 200
    private let maxAPIPagesPerQuery = 3
    private let session: URLSession
    private let apiKey: String?

    init(session: URLSession = .shared, apiKey: String? = PixabaySource.defaultAPIKey()) {
        self.session = session
        self.apiKey = Self.nonEmpty(apiKey)
    }

    func clearCache() async {
        if let cacheURL = try? catalogCacheURL() {
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    func loadCachedCatalog() async -> [CatalogWallpaper]? {
        guard let cacheURL = try? catalogCacheURL(),
              let data = try? Data(contentsOf: cacheURL),
              let envelope = try? JSONDecoder().decode(PixabayCatalogCacheEnvelope.self, from: data) else {
            let curated = Self.curatedScenicCatalog
            return curated.isEmpty ? nil : curated
        }
        let merged = Self.mergeCatalogs(live: envelope.wallpapers, fallback: Self.curatedScenicCatalog)
        return merged.isEmpty ? nil : merged
    }

    func fetchCatalog() async throws -> [CatalogWallpaper] {
        let wallpapers = try await fetchCatalog(progress: { _ in })
        return wallpapers
    }

    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        if let apiKey {
            let apiCatalog = try await fetchAPICatalog(apiKey: apiKey, progress: progress)
            if !apiCatalog.isEmpty {
                try persistCatalog(apiCatalog)
                return apiCatalog
            }
        }

        var aggregated: [CatalogWallpaper] = []

        for query in searchQueries {
            let pageURL = searchURL(for: query)
            let pageWallpapers = (try? await fetchSearchPage(url: pageURL)) ?? []
            aggregated.append(contentsOf: pageWallpapers)

            let merged = Self.mergeCatalogs(live: aggregated, fallback: Self.curatedScenicCatalog)
            if !merged.isEmpty {
                await progress(merged)
            }
        }

        let merged = Self.mergeCatalogs(live: aggregated, fallback: Self.curatedScenicCatalog)
        guard !merged.isEmpty else {
            throw PixabaySourceError.unavailable("Pixabay scenic catalog is unavailable.")
        }

        try persistCatalog(merged)
        return merged
    }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        if let source = wallpaper.sources.first {
            return source.url
        }
        throw URLError(.badURL)
    }

    private func fetchAPICatalog(
        apiKey: String,
        progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void
    ) async throws -> [CatalogWallpaper] {
        var aggregated: [CatalogWallpaper] = []
        var firstError: Error?

        for query in searchQueries {
            do {
                let firstPage = try await fetchAPIPage(apiKey: apiKey, query: query, page: 1)
                aggregated.append(contentsOf: firstPage.wallpapers)
                await progress(Self.deduplicate(aggregated))

                let totalPages = min(
                    maxAPIPagesPerQuery,
                    max(1, Int(ceil(Double(firstPage.totalHits) / Double(apiPageSize))))
                )
                if totalPages > 1 {
                    for page in 2...totalPages {
                        let pageResult = try await fetchAPIPage(apiKey: apiKey, query: query, page: page)
                        aggregated.append(contentsOf: pageResult.wallpapers)
                        await progress(Self.deduplicate(aggregated))
                    }
                }
            } catch {
                firstError = firstError ?? error
            }
        }

        let deduplicated = Self.deduplicate(aggregated)
        if deduplicated.isEmpty, let firstError {
            throw firstError
        }
        return deduplicated
    }

    private func fetchAPIPage(
        apiKey: String,
        query: String,
        page: Int
    ) async throws -> (wallpapers: [CatalogWallpaper], totalHits: Int) {
        var components = URLComponents(url: baseURL.appending(path: "api/videos/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "video_type", value: "all"),
            URLQueryItem(name: "category", value: query.contains("abstract") || query.contains("motion") || query.contains("lava") ? "backgrounds" : "nature"),
            URLQueryItem(name: "min_width", value: "1920"),
            URLQueryItem(name: "min_height", value: "1080"),
            URLQueryItem(name: "safesearch", value: "true"),
            URLQueryItem(name: "order", value: "popular"),
            URLQueryItem(name: "per_page", value: String(apiPageSize)),
            URLQueryItem(name: "page", value: String(page)),
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("AuraFlow/1.2", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let message = Self.nonEmpty(String(data: data, encoding: .utf8)) ?? "Pixabay API returned HTTP \(httpResponse.statusCode)."
            throw PixabaySourceError.unavailable(message)
        }

        let payload = try JSONDecoder().decode(PixabayVideoAPIResponse.self, from: data)
        let wallpapers = payload.hits.compactMap(PixabayParser.makeCatalogWallpaper(fromAPIHit:))
        return (wallpapers, payload.totalHits)
    }

    private func fetchSearchPage(url: URL) async throws -> [CatalogWallpaper] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw PixabaySourceError.unavailable("Pixabay returned HTTP \(httpResponse.statusCode).")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw PixabaySourceError.unavailable("Pixabay returned an unreadable catalog page.")
        }
        if PixabayParser.isChallengePage(html) {
            return []
        }
        return PixabayParser.parseSearchPage(html: html, pageURL: url)
    }

    private func searchURL(for query: String) -> URL {
        var components = URLComponents(url: baseURL.appending(path: "videos/search/\(query)/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "orientation", value: "horizontal"),
        ]
        return components.url!
    }

    private func persistCatalog(_ wallpapers: [CatalogWallpaper]) throws {
        let envelope = PixabayCatalogCacheEnvelope(updatedAt: Date(), wallpapers: wallpapers)
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: try catalogCacheURL(), options: .atomic)
    }

    private func catalogCacheURL() throws -> URL {
        try catalogSupportDirectory().appendingPathComponent("pixabay-scenic-cache.json")
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

    private static func mergeCatalogs(
        live: [CatalogWallpaper],
        fallback: [CatalogWallpaper]
    ) -> [CatalogWallpaper] {
        deduplicate(live + fallback)
    }

    private static func deduplicate(_ wallpapers: [CatalogWallpaper]) -> [CatalogWallpaper] {
        var seen = Set<String>()
        var merged: [CatalogWallpaper] = []
        for wallpaper in wallpapers where seen.insert(wallpaper.id).inserted {
            merged.append(wallpaper)
        }
        return merged
    }

    private static func defaultAPIKey() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["AURAFLOW_PIXABAY_API_KEY"] ?? environment["PIXABAY_API_KEY"] {
            return value
        }
        return Bundle.main.object(forInfoDictionaryKey: "PixabayAPIKey") as? String
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct PixabayVideoAPIResponse: Decodable {
    let totalHits: Int
    let hits: [PixabayVideoHit]
}

struct PixabayVideoHit: Decodable {
    let id: Int
    let pageURL: URL
    let tags: String
    let duration: Int?
    let videos: [String: PixabayVideoRendition]
    let user: String?
}

struct PixabayVideoRendition: Decodable {
    let url: URL?
    let width: Int
    let height: Int
    let size: Int?
    let thumbnail: URL?
}

enum PixabayParser {
    static func isChallengePage(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("just a moment") ||
            lowercased.contains("enable javascript and cookies to continue") ||
            lowercased.contains("cf_chl_opt") ||
            lowercased.contains("cf-mitigated")
    }

    static func parseSearchPage(html: String, pageURL: URL) -> [CatalogWallpaper] {
        let normalized = decodeHTMLEntities(html)
        let imagePattern = #"https://cdn\.pixabay\.com/video/\d{4}/\d{2}/\d{2}/([0-9]+(?:-[0-9]+)?)_tiny\.(?:jpg|jpeg|webp)"#
        guard let regex = try? NSRegularExpression(pattern: imagePattern, options: [.caseInsensitive]) else {
            return []
        }

        let matches = regex.matches(
            in: normalized,
            range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        )

        var wallpapers: [CatalogWallpaper] = []
        var seen = Set<String>()

        for match in matches {
            guard let matchRange = Range(match.range(at: 0), in: normalized),
                  let assetRange = Range(match.range(at: 1), in: normalized),
                  let thumbnailURL = URL(string: String(normalized[matchRange])) else {
                continue
            }

            let assetID = String(normalized[assetRange])
            let title = titleNear(range: matchRange, in: normalized) ?? titleFromAssetID(assetID)
            guard isScenicText(title) else { continue }

            let catalogID = "pixabay-\(assetID)"
            guard seen.insert(catalogID).inserted else { continue }
            let sourcePageURL = sourcePageURLNear(range: matchRange, assetID: assetID, in: normalized, fallback: pageURL)

            wallpapers.append(
                makeCatalogWallpaper(
                    id: catalogID,
                    title: title,
                    thumbnailURL: thumbnailURL,
                    sourcePageURL: sourcePageURL
                )
            )
        }

        return wallpapers
    }

    static func makeCatalogWallpaper(
        id: String,
        title: String,
        thumbnailURL: URL,
        sourcePageURL: URL
    ) -> CatalogWallpaper {
        CatalogWallpaper(
            id: id,
            title: cleanupTitle(title),
            category: "Scenic",
            attribution: "Pixabay",
            previewImageURL: thumbnailURL,
            sourcePageURL: sourcePageURL,
            sources: videoCandidates(from: thumbnailURL).map {
                CatalogVideoSource(url: $0, width: 1920, height: 1080)
            }
        )
    }

    static func makeCatalogWallpaper(fromAPIHit hit: PixabayVideoHit) -> CatalogWallpaper? {
        guard isScenicText(hit.tags) else { return nil }
        let orderedKeys = ["medium", "large", "small", "tiny"]
        let sources = orderedKeys.compactMap { key -> CatalogVideoSource? in
            guard let video = hit.videos[key],
                  let url = video.url,
                  video.width >= 960,
                  video.height >= 540 else {
                return nil
            }
            return CatalogVideoSource(url: url, width: video.width, height: video.height)
        }
        guard !sources.isEmpty else { return nil }

        let previewImageURL = orderedKeys.compactMap { hit.videos[$0]?.thumbnail }.first
        return CatalogWallpaper(
            id: "pixabay-\(hit.id)",
            title: titleFromTags(hit.tags),
            category: "Scenic",
            attribution: "Pixabay",
            previewImageURL: previewImageURL,
            sourcePageURL: hit.pageURL,
            sources: sources
        )
    }

    static func videoCandidates(from thumbnailURL: URL) -> [URL] {
        let raw = thumbnailURL.absoluteString
        let pattern = #"_tiny\.(?:jpg|jpeg|webp)$"#
        let candidates = ["medium", "large", "small", "tiny"].compactMap { quality -> URL? in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            let replaced = regex.stringByReplacingMatches(
                in: raw,
                range: NSRange(raw.startIndex..<raw.endIndex, in: raw),
                withTemplate: "_\(quality).mp4"
            )
            return URL(string: replaced)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.absoluteString).inserted }
    }

    private static func titleNear(range: Range<String.Index>, in html: String) -> String? {
        let lowerBound = html.index(range.lowerBound, offsetBy: -900, limitedBy: html.startIndex) ?? html.startIndex
        let upperBound = html.index(range.upperBound, offsetBy: 900, limitedBy: html.endIndex) ?? html.endIndex
        let window = String(html[lowerBound..<upperBound])
        let targetOffset = html.distance(from: lowerBound, to: range.lowerBound)
        let patterns = [
            #"alt=["']Image:\s*([^"']+)["']"#,
            #"aria-label=["']Image:\s*([^"']+)["']"#,
            #"title=["']Image:\s*([^"']+)["']"#,
        ]

        var candidates: [(distance: Int, title: String)] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
                continue
            }
            let nsRange = NSRange(window.startIndex..<window.endIndex, in: window)
            for match in regex.matches(in: window, range: nsRange) {
                guard match.numberOfRanges > 1,
                      let titleRange = Range(match.range(at: 1), in: window) else {
                    continue
                }
                let title = cleanupTitle(String(window[titleRange]))
                guard !title.isEmpty else { continue }
                let matchOffset = match.range.location + match.range.length
                candidates.append((abs(targetOffset - matchOffset), title))
            }
        }
        return candidates.min(by: { $0.distance < $1.distance })?.title
    }

    private static func sourcePageURLNear(
        range: Range<String.Index>,
        assetID: String,
        in html: String,
        fallback: URL
    ) -> URL {
        let numericID = assetID.split(separator: "-").first.map(String.init) ?? assetID
        let lowerBound = html.index(range.lowerBound, offsetBy: -900, limitedBy: html.startIndex) ?? html.startIndex
        let upperBound = html.index(range.upperBound, offsetBy: 900, limitedBy: html.endIndex) ?? html.endIndex
        let window = String(html[lowerBound..<upperBound])
        let patterns = [
            #"href=["'](https://pixabay\.com/videos/[^"']*\#(numericID)/?)["']"#,
            #"href=["'](/videos/[^"']*\#(numericID)/?)["']"#,
        ]

        for pattern in patterns {
            if let rawURL = firstMatch(in: window, pattern: pattern),
               let url = URL(string: rawURL, relativeTo: URL(string: "https://pixabay.com"))?.absoluteURL {
                return url
            }
        }
        return fallback
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    static func isScenicText(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        let allowedTerms = [
            "abstract", "autumn", "cascade", "cloud", "forest", "galaxy", "grass", "green",
            "geothermal", "lake", "lava", "leaf", "leaves", "loop", "mountain", "nature",
            "nebula", "ocean", "plant", "rain", "river", "space", "stars", "stream", "sunset",
            "tree", "tunnel", "volcano", "water", "waterfall", "waves", "wind",
        ]
        let blockedTerms = [
            "anime", "cartoon", "emoji", "flag", "icon", "man", "people", "portrait", "selfie", "woman",
        ]
        return allowedTerms.contains { lowercased.contains($0) } &&
            !blockedTerms.contains { lowercased.contains($0) }
    }

    private static func titleFromTags(_ tags: String) -> String {
        let title = tags
            .split(separator: ",")
            .map { part in
                part.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .prefix(5)
            .map { tag in
                tag
                    .split(separator: " ")
                    .map { word in
                        let value = String(word)
                        guard let first = value.first else { return value }
                        return first.uppercased() + value.dropFirst()
                    }
                    .joined(separator: " ")
            }
            .joined(separator: ", ")
        return cleanupTitle(title).isEmpty ? "Pixabay Scenic" : cleanupTitle(title)
    }

    private static func titleFromAssetID(_ assetID: String) -> String {
        "Pixabay Scenic \(assetID)"
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
        ]
        for (entity, replacement) in replacements {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }
        return decoded
    }
}

private struct PixabayCatalogCacheEnvelope: Codable {
    let updatedAt: Date
    let wallpapers: [CatalogWallpaper]
}

enum PixabaySourceError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}

private extension PixabaySource {
    static let curatedScenicCatalog: [CatalogWallpaper] = [
        curated(
            id: "pixabay-246856",
            title: "Waterfall Rainbow River Nature",
            thumbnail: "https://cdn.pixabay.com/video/2024/12/15/246856_tiny.jpg",
            page: "https://pixabay.com/videos/waterfall-rainbow-river-nature-246856/"
        ),
        curated(
            id: "pixabay-356398",
            title: "Waterfall River Beautiful Wallpaper",
            thumbnail: "https://cdn.pixabay.com/video/2026/06/03/356398_tiny.jpg",
            page: "https://pixabay.com/videos/waterfall-river-beautiful-wallpaper-356398/"
        ),
        curated(
            id: "pixabay-215696",
            title: "Nebula Space Universe Galaxy Stars",
            thumbnail: "https://cdn.pixabay.com/video/2024/06/07/215696_tiny.jpg",
            page: "https://pixabay.com/videos/nebula-space-universe-galaxy-stars-215696/"
        ),
        curated(
            id: "pixabay-139689",
            title: "Galaxy Space Universe",
            thumbnail: "https://cdn.pixabay.com/video/2022/11/19/139689-773418069_tiny.jpg",
            page: "https://pixabay.com/videos/galaxy-space-universe-139689/"
        ),
        curated(
            id: "pixabay-4968",
            title: "Space Wormhole Blue Vortex Lights",
            thumbnail: "https://cdn.pixabay.com/video/2016/09/06/4968-181688475_tiny.jpg",
            page: "https://pixabay.com/videos/space-wormhole-blue-vortex-lights-4968/"
        ),
        curated(
            id: "pixabay-26637",
            title: "Herb Leaf Wind Nature Macro",
            thumbnail: "https://cdn.pixabay.com/video/2019/09/07/26637-360259342_tiny.jpg",
            page: "https://pixabay.com/videos/herb-leaf-wind-nature-macro-26637/"
        ),
        curated(
            id: "pixabay-197946",
            title: "Grass Plant Dry Park Garden",
            thumbnail: "https://cdn.pixabay.com/video/2024/01/24/197946-906217105_tiny.jpg",
            page: "https://pixabay.com/videos/grass-plant-dry-park-garden-197946/"
        ),
        curated(
            id: "pixabay-57506",
            title: "Swans Lake River Mountains",
            thumbnail: "https://cdn.pixabay.com/video/2020/11/27/57506-484931119_tiny.jpg",
            page: "https://pixabay.com/videos/swans-lake-river-mountains-57506/"
        ),
    ]

    static func curated(id: String, title: String, thumbnail: String, page: String) -> CatalogWallpaper {
        PixabayParser.makeCatalogWallpaper(
            id: id,
            title: title,
            thumbnailURL: URL(string: thumbnail)!,
            sourcePageURL: URL(string: page)!
        )
    }
}
