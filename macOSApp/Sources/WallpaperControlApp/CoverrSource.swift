import Foundation

actor CoverrSource: WallpaperCatalogProviding, CatalogCacheClearing {
    private let apiBaseURL = URL(string: "https://api.coverr.co/")!
    private let searchQueries = [
        "waterfall",
        "forest",
        "mountain",
        "ocean waves",
        "clouds",
        "rain",
        "river",
        "lake",
        "aerial nature",
        "drone nature",
        "sunset landscape",
        "forest rain",
    ]
    private let pageSize = 30
    private let maxPagesPerQuery = 2
    private let session: URLSession
    private let apiKey: String?

    init(session: URLSession = .shared, apiKey: String? = CoverrSource.defaultAPIKey()) {
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
              let envelope = try? JSONDecoder().decode(CoverrCatalogCacheEnvelope.self, from: data) else {
            return nil
        }
        return envelope.wallpapers.isEmpty ? nil : envelope.wallpapers
    }

    func fetchCatalog() async throws -> [CatalogWallpaper] {
        try await fetchCatalog(progress: { _ in })
    }

    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        guard let apiKey else {
            throw CoverrSourceError.unavailable("Coverr API key is not configured.")
        }

        var aggregated: [CatalogWallpaper] = []
        var firstError: Error?

        for query in searchQueries {
            do {
                let firstPage = try await fetchPage(apiKey: apiKey, query: query, page: 0)
                aggregated.append(contentsOf: firstPage.wallpapers)
                let deduplicated = Self.deduplicate(aggregated)
                if !deduplicated.isEmpty {
                    await progress(deduplicated)
                }

                let pageCount = min(maxPagesPerQuery, max(1, firstPage.pages))
                if pageCount > 1 {
                    for page in 1..<pageCount {
                        let pageResult = try await fetchPage(apiKey: apiKey, query: query, page: page)
                        aggregated.append(contentsOf: pageResult.wallpapers)
                        let deduplicated = Self.deduplicate(aggregated)
                        if !deduplicated.isEmpty {
                            await progress(deduplicated)
                        }
                    }
                }
            } catch {
                firstError = firstError ?? error
            }
        }

        let deduplicated = Self.deduplicate(aggregated)
        guard !deduplicated.isEmpty else {
            throw firstError ?? CoverrSourceError.unavailable("Coverr returned no nature videos.")
        }
        try persistCatalog(deduplicated)
        return deduplicated
    }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        if let source = wallpaper.sources.first {
            return source.url
        }
        throw URLError(.badURL)
    }

    private func fetchPage(
        apiKey: String,
        query: String,
        page: Int
    ) async throws -> (wallpapers: [CatalogWallpaper], pages: Int) {
        var components = URLComponents(url: apiBaseURL.appending(path: "videos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "sort", value: "popular"),
            URLQueryItem(name: "urls", value: "true"),
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("AuraFlow/1.2", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let message = Self.nonEmpty(String(data: data, encoding: .utf8)) ?? "Coverr API returned HTTP \(httpResponse.statusCode)."
            throw CoverrSourceError.unavailable(message)
        }

        let payload = try JSONDecoder().decode(CoverrVideoAPIResponse.self, from: data)
        let wallpapers = payload.hits.compactMap(CoverrParser.makeCatalogWallpaper(from:))
        return (wallpapers, payload.pages)
    }

    private func persistCatalog(_ wallpapers: [CatalogWallpaper]) throws {
        let envelope = CoverrCatalogCacheEnvelope(updatedAt: Date(), wallpapers: wallpapers)
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: try catalogCacheURL(), options: .atomic)
    }

    private func catalogCacheURL() throws -> URL {
        try catalogSupportDirectory().appendingPathComponent("coverr-nature-cache.json")
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
        if let value = environment["AURAFLOW_COVERR_API_KEY"] ?? environment["COVERR_API_KEY"] {
            return value
        }
        return Bundle.main.object(forInfoDictionaryKey: "CoverrAPIKey") as? String
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CoverrVideoAPIResponse: Decodable {
    let page: Int
    let pages: Int
    let pageSize: Int
    let total: Int
    let hits: [CoverrVideoHit]

    enum CodingKeys: String, CodingKey {
        case page
        case pages
        case pageSize = "page_size"
        case total
        case hits
    }
}

struct CoverrVideoHit: Decodable {
    let id: String
    let title: String
    let poster: URL?
    let thumbnail: URL?
    let description: String?
    let isVertical: Bool
    let tags: [String]
    let aspectRatio: String?
    let duration: Double?
    let maxHeight: Int?
    let maxWidth: Int?
    let urls: CoverrVideoURLs?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case poster
        case thumbnail
        case description
        case isVertical = "is_vertical"
        case tags
        case aspectRatio = "aspect_ratio"
        case duration
        case maxHeight = "max_height"
        case maxWidth = "max_width"
        case urls
    }
}

struct CoverrVideoURLs: Decodable {
    let mp4: URL?
    let mp4Preview: URL?
    let mp4Download: URL?

    enum CodingKeys: String, CodingKey {
        case mp4
        case mp4Preview = "mp4_preview"
        case mp4Download = "mp4_download"
    }

    init(mp4: URL?, mp4Preview: URL?, mp4Download: URL?) {
        self.mp4 = mp4
        self.mp4Preview = mp4Preview
        self.mp4Download = mp4Download
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mp4 = Self.decodeURL(for: .mp4, from: container)
        mp4Preview = Self.decodeURL(for: .mp4Preview, from: container)
        mp4Download = Self.decodeURL(for: .mp4Download, from: container)
    }

    private static func decodeURL(
        for key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> URL? {
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }
}

enum CoverrParser {
    static func makeCatalogWallpaper(from hit: CoverrVideoHit) -> CatalogWallpaper? {
        guard isSupportedNatureVideo(hit) else { return nil }
        guard let videoURL = hit.urls?.mp4 ?? hit.urls?.mp4Download else { return nil }

        let width = hit.maxWidth ?? 1920
        let height = hit.maxHeight ?? 1080
        var sources = [CatalogVideoSource(url: videoURL, width: width, height: height)]
        if let downloadURL = hit.urls?.mp4Download, downloadURL != videoURL {
            sources.append(CatalogVideoSource(url: downloadURL, width: width, height: height))
        }

        return CatalogWallpaper(
            id: "coverr-\(hit.id)",
            title: cleanupTitle(hit.title),
            category: "Scenic",
            attribution: "Coverr",
            previewImageURL: hit.poster ?? hit.thumbnail,
            sourcePageURL: URL(string: "https://coverr.co/videos/\(hit.id)"),
            sources: sources
        )
    }

    static func isSupportedNatureVideo(_ hit: CoverrVideoHit) -> Bool {
        if hit.isVertical { return false }
        if let aspectRatio = hit.aspectRatio, aspectRatio != "16:9" {
            return false
        }

        let width = hit.maxWidth ?? 0
        let height = hit.maxHeight ?? 0
        guard width >= 1920, height >= 1080 else {
            return false
        }
        guard hit.urls?.mp4 != nil || hit.urls?.mp4Download != nil else {
            return false
        }

        let searchableText = ([hit.title, hit.description ?? ""] + hit.tags)
            .joined(separator: " ")
            .lowercased()
        let allowedTerms = [
            "aerial", "beach", "cloud", "clouds", "drone", "forest", "lake", "landscape",
            "mountain", "nature", "ocean", "rain", "river", "sea", "sunset", "tree",
            "trees", "water", "waterfall", "wave", "waves",
        ]
        let blockedTerms = [
            "app", "brand", "building", "business", "car", "city", "computer", "crowd",
            "device", "face", "family", "hand", "hands", "iphone", "laptop", "logo",
            "man", "office", "people", "person", "phone", "portrait", "screen", "selfie",
            "sign", "street", "text", "traffic", "woman",
        ]

        return allowedTerms.contains { searchableText.contains($0) } &&
            !blockedTerms.contains { searchableText.contains($0) }
    }

    private static func cleanupTitle(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: #"[\n\r\t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Coverr Nature" : cleaned
    }
}

private struct CoverrCatalogCacheEnvelope: Codable {
    let updatedAt: Date
    let wallpapers: [CatalogWallpaper]
}

enum CoverrSourceError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}
