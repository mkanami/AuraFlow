import Foundation

actor DarefulSource: WallpaperCatalogProviding, CatalogCacheClearing {
    private let baseURL = URL(string: "https://dareful.com/")!
    private let tagSlugs = [
        "nature",
        "water",
        "forest",
        "ocean",
        "clouds",
        "lake",
        "landscape",
        "mountains",
        "trees",
        "beach",
        "sunset",
        "sky",
        "aerial",
        "drone",
    ]
    private let pageSize = 50
    private let maxPagesPerTag = 4
    private let maxConcurrentDetailFetches = 10
    private let session: URLSession

    init(session: URLSession = DarefulSource.makeSession()) {
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
              let envelope = try? JSONDecoder().decode(DarefulCatalogCacheEnvelope.self, from: data) else {
            return nil
        }
        return envelope.wallpapers.isEmpty ? nil : envelope.wallpapers
    }

    func fetchCatalog() async throws -> [CatalogWallpaper] {
        try await fetchCatalog(progress: { _ in })
    }

    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        let tagIDs = try await fetchTagIDs()
        guard !tagIDs.isEmpty else {
            throw DarefulSourceError.unavailable("Dareful nature tags are unavailable.")
        }

        let posts = try await fetchPosts(tagIDs: tagIDs)
        let uniquePosts = Self.deduplicatePosts(posts)
        let prioritizedPosts = Self.prioritizePosts(uniquePosts, preferredTagIDs: tagIDs)
        let deduplicated = try await fetchWallpapers(from: prioritizedPosts, progress: progress)
        guard !deduplicated.isEmpty else {
            throw DarefulSourceError.unavailable("Dareful returned no supported scenic MP4 videos.")
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

    private func fetchTagIDs() async throws -> [Int] {
        var components = URLComponents(url: baseURL.appending(path: "wp-json/wp/v2/tags"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "slug", value: tagSlugs.joined(separator: ",")),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "_fields", value: "id,slug,name,count"),
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let data = try await fetchData(url)
        let tags = try JSONDecoder().decode([DarefulTag].self, from: data)
        return tags
            .filter { $0.count > 0 }
            .sorted { lhs, rhs in
                let lhsIndex = tagSlugs.firstIndex(of: lhs.slug) ?? .max
                let rhsIndex = tagSlugs.firstIndex(of: rhs.slug) ?? .max
                return lhsIndex < rhsIndex
            }
            .map(\.id)
    }

    private func fetchPosts(tagID: Int, page: Int) async throws -> (posts: [DarefulPost], totalPages: Int) {
        var components = URLComponents(url: baseURL.appending(path: "wp-json/wp/v2/posts"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "tags", value: String(tagID)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(pageSize)),
            URLQueryItem(name: "_fields", value: "id,slug,link,title,tags,featured_media"),
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await fetchDataAndResponse(url)
        let posts = try JSONDecoder().decode([DarefulPost].self, from: data)
        let totalPages = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "X-WP-TotalPages")
            .flatMap(Int.init) ?? 1
        return (posts, totalPages)
    }

    private func fetchPosts(tagIDs: [Int]) async throws -> [DarefulPost] {
        try await withThrowingTaskGroup(of: [DarefulPost].self) { group in
            for tagID in tagIDs {
                group.addTask { [self] in
                    try await fetchPosts(tagID: tagID)
                }
            }

            var posts: [DarefulPost] = []
            for try await tagPosts in group {
                posts.append(contentsOf: tagPosts)
            }
            return posts
        }
    }

    private func fetchPosts(tagID: Int) async throws -> [DarefulPost] {
        let firstPage = try await fetchPosts(tagID: tagID, page: 1)
        var posts = firstPage.posts
        let pageCount = min(maxPagesPerTag, max(1, firstPage.totalPages))
        guard pageCount > 1 else {
            return posts
        }

        let remainingPosts = try await withThrowingTaskGroup(of: [DarefulPost].self) { group in
            for page in 2...pageCount {
                group.addTask { [self] in
                    try await fetchPosts(tagID: tagID, page: page).posts
                }
            }

            var remaining: [DarefulPost] = []
            for try await pagePosts in group {
                remaining.append(contentsOf: pagePosts)
            }
            return remaining
        }

        posts.append(contentsOf: remainingPosts)
        return posts
    }

    private func fetchWallpaperDetails(for post: DarefulPost) async throws -> CatalogWallpaper? {
        let data = try await fetchData(post.link)
        guard let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        return DarefulParser.parseDetailPage(
            html: html,
            postID: post.id,
            fallbackTitle: post.title.rendered,
            pageURL: post.link
        )
    }

    private func fetchWallpapers(
        from posts: [DarefulPost],
        progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void
    ) async throws -> [CatalogWallpaper] {
        guard !posts.isEmpty else { return [] }

        var iterator = posts.makeIterator()
        var collected: [CatalogWallpaper] = []
        var emittedCount = 0

        return try await withThrowingTaskGroup(of: CatalogWallpaper?.self) { group in
            for _ in 0..<min(maxConcurrentDetailFetches, posts.count) {
                guard let post = iterator.next() else { break }
                group.addTask { [self] in
                    try await fetchWallpaperDetails(for: post)
                }
            }

            while let wallpaper = try await group.next() {
                if let wallpaper {
                    collected.append(wallpaper)
                    let deduplicated = Self.deduplicateWallpapers(collected)
                    if Self.shouldEmitProgress(foundCount: deduplicated.count, previousCount: emittedCount) {
                        emittedCount = deduplicated.count
                        await progress(deduplicated)
                    }
                }

                if let nextPost = iterator.next() {
                    group.addTask { [self] in
                        try await fetchWallpaperDetails(for: nextPost)
                    }
                }
            }

            let deduplicated = Self.deduplicateWallpapers(collected)
            if !deduplicated.isEmpty && emittedCount != deduplicated.count {
                await progress(deduplicated)
            }
            return deduplicated
        }
    }

    private func fetchData(_ url: URL) async throws -> Data {
        let (data, _) = try await fetchDataAndResponse(url)
        return data
    }

    private func fetchDataAndResponse(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json,text/html,*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw DarefulSourceError.unavailable("Dareful returned HTTP \(httpResponse.statusCode).")
        }
        return (data, response)
    }

    private func persistCatalog(_ wallpapers: [CatalogWallpaper]) throws {
        let envelope = DarefulCatalogCacheEnvelope(updatedAt: Date(), wallpapers: wallpapers)
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: try catalogCacheURL(), options: .atomic)
    }

    private func catalogCacheURL() throws -> URL {
        try catalogSupportDirectory().appendingPathComponent("dareful-scenic-cache.json")
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

    private static func deduplicatePosts(_ posts: [DarefulPost]) -> [DarefulPost] {
        var seen = Set<Int>()
        return posts.filter { seen.insert($0.id).inserted }
    }

    private static func deduplicateWallpapers(_ wallpapers: [CatalogWallpaper]) -> [CatalogWallpaper] {
        var seen = Set<String>()
        return wallpapers.filter { seen.insert($0.id).inserted }
    }

    private static func shouldEmitProgress(foundCount: Int, previousCount: Int) -> Bool {
        guard foundCount > previousCount else { return false }
        return foundCount <= 8 || foundCount - previousCount >= 4
    }

    static func prioritizePosts(_ posts: [DarefulPost], preferredTagIDs: [Int]) -> [DarefulPost] {
        guard posts.count > 1 else { return posts }

        var grouped: [Int: [DarefulPost]] = [:]
        var fallbackOrder: [Int] = []
        for post in posts {
            let key = preferredTagIDs.first(where: { post.tags.contains($0) }) ?? post.tags.first ?? post.id
            if grouped[key] == nil {
                fallbackOrder.append(key)
            }
            grouped[key, default: []].append(post)
        }

        let orderedKeys = preferredTagIDs.filter { grouped[$0] != nil } +
            fallbackOrder.filter { !preferredTagIDs.contains($0) }
        var offsets = Dictionary(uniqueKeysWithValues: orderedKeys.map { ($0, 0) })
        var prioritized: [DarefulPost] = []
        prioritized.reserveCapacity(posts.count)

        while prioritized.count < posts.count {
            var advanced = false
            for key in orderedKeys {
                guard let bucket = grouped[key] else { continue }
                let offset = offsets[key, default: 0]
                guard offset < bucket.count else { continue }
                prioritized.append(bucket[offset])
                offsets[key] = offset + 1
                advanced = true
            }
            if !advanced {
                break
            }
        }

        return prioritized
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

struct DarefulTag: Decodable {
    let id: Int
    let slug: String
    let name: String
    let count: Int
}

struct DarefulPost: Decodable {
    struct RenderedText: Decodable {
        let rendered: String
    }

    let id: Int
    let slug: String
    let link: URL
    let title: RenderedText
    let tags: [Int]
    let featuredMedia: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case slug
        case link
        case title
        case tags
        case featuredMedia = "featured_media"
    }
}

enum DarefulParser {
    static func parseDetailPage(
        html: String,
        postID: Int,
        fallbackTitle: String,
        pageURL: URL
    ) -> CatalogWallpaper? {
        let normalized = decodeHTMLEntities(html)
        let title = cleanupTitle(
            firstMatch(in: normalized, pattern: #"metadata-video-title=["']([^"']+)["']"#)
                ?? firstMatch(in: normalized, pattern: #"<meta[^>]+property=["']og:image:alt["'][^>]+content=["']([^"']+)["']"#)
                ?? fallbackTitle
        )
        let tags = tagNames(in: normalized)
        guard isSupportedScenicText(([title] + tags).joined(separator: " ")) else {
            return nil
        }

        guard let playbackID = playbackID(in: normalized) else {
            return nil
        }
        let resolution = resolution(in: normalized)
        guard isSupportedResolution(resolution) else {
            return nil
        }

        let previewImageURL = firstMatch(
            in: normalized,
            pattern: #"<meta[^>]+property=["']og:image(?::secure_url)?["'][^>]+content=["']([^"']+)["']"#
        ).flatMap(URL.init(string:))

        let sources = videoSources(playbackID: playbackID, resolution: resolution)
        guard !sources.isEmpty else {
            return nil
        }

        return CatalogWallpaper(
            id: "dareful-\(postID)",
            title: title,
            category: "Scenic",
            attribution: "Dareful",
            previewImageURL: previewImageURL,
            sourcePageURL: pageURL,
            sources: sources
        )
    }

    static func videoSources(playbackID: String, resolution: MoeWallsResolution?) -> [CatalogVideoSource] {
        let width = resolution?.width ?? 1920
        let height = resolution?.height ?? 1080
        return ["high", "medium", "low"].compactMap { rendition in
            URL(string: "https://stream.mux.com/\(playbackID)/\(rendition).mp4").map {
                CatalogVideoSource(url: $0, width: width, height: height)
            }
        }
    }

    static func playbackID(in html: String) -> String? {
        firstMatch(in: html, pattern: #"<mux-player[^>]+playback-id=["']([^"']+)["']"#)
            ?? firstMatch(in: html, pattern: #"https://stream\.mux\.com/([^/"']+)\.m3u8"#)
    }

    static func resolution(in html: String) -> MoeWallsResolution? {
        firstMatch(in: html, pattern: #"Resolution\s*(?:—|&mdash;|-|:)?\s*(\d{3,5}\s*x\s*\d{3,5})"#)
            .flatMap(MoeWallsResolution.parse)
    }

    static func isSupportedResolution(_ resolution: MoeWallsResolution?) -> Bool {
        guard let resolution else {
            return true
        }
        return resolution.width >= 1920 &&
            resolution.height >= 1080 &&
            resolution.width >= resolution.height
    }

    static func isSupportedScenicText(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        let allowedTerms = [
            "aerial", "autumn", "beach", "cloud", "clouds", "drone", "forest", "foliage",
            "grass", "lake", "landscape", "mountain", "mountains", "nature", "ocean",
            "rain", "river", "scenic", "sea", "sky", "snow", "sunrise", "sunset", "tree",
            "trees", "water", "waterfall", "wave", "waves", "winter",
        ]
        let blockedTerms = [
            "building", "city", "crowd", "fireworks", "logo", "man", "people", "person",
            "portrait", "rooftop", "screen", "street", "text", "traffic", "vehicle", "woman",
        ]
        return allowedTerms.contains { lowercased.contains($0) } &&
            !blockedTerms.contains { lowercased.contains($0) }
    }

    private static func tagNames(in html: String) -> [String] {
        regexMatches(pattern: #"<a[^>]+rel=["']tag["'][^>]*>([^<]+)</a>"#, in: html)
            .compactMap { $0.count > 1 ? cleanupTitle($0[1]) : nil }
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

    private static func cleanupTitle(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: #"[\n\r\t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Dareful Scenic" : cleaned
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
            "&mdash;": "—",
            "&nbsp;": " ",
        ]
        for (entity, replacement) in replacements {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }
        return decoded
    }
}

private struct DarefulCatalogCacheEnvelope: Codable {
    let updatedAt: Date
    let wallpapers: [CatalogWallpaper]
}

enum DarefulSourceError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}
