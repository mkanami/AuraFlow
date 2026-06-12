import Foundation

struct MoeWallsRESTPost: Decodable {
    struct RenderedText: Decodable {
        let rendered: String
    }

    struct OpenGraphImage: Decodable {
        let url: String
        let width: Int?
        let height: Int?
    }

    struct SchemaNode: Decodable {
        let articleSection: [String]?
        let keywords: [String]?
        let thumbnailUrl: String?
    }

    struct YoastSchema: Decodable {
        let graph: [SchemaNode]?
    }

    struct YoastHeadJSON: Decodable {
        let ogImage: [OpenGraphImage]?
        let schema: YoastSchema?

        enum CodingKeys: String, CodingKey {
            case ogImage = "og_image"
            case schema
        }
    }

    struct ClassList: Decodable {
        let values: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let array = try? container.decode([String].self) {
                values = array
                return
            }
            let dictionary = try container.decode([String: String].self)
            values = dictionary
                .sorted { lhs, rhs in
                    (Int(lhs.key) ?? .max) < (Int(rhs.key) ?? .max)
                }
                .map(\.value)
        }
    }

    let slug: String
    let link: String
    let title: RenderedText
    let date: String?
    let categories: [Int]?
    let tags: [Int]?
    let resolutions: [Int]?
    let classList: ClassList?
    let yoastHeadJSON: YoastHeadJSON?

    enum CodingKeys: String, CodingKey {
        case slug
        case link
        case title
        case date
        case categories
        case tags
        case resolutions
        case classList = "class_list"
        case yoastHeadJSON = "yoast_head_json"
    }
}

struct MoeWallsTaxonomyTerm: Decodable {
    let id: Int
    let name: String
    let slug: String
}

actor MoeWallsSource: WallpaperCatalogProviding {
    private let baseURL = URL(string: "https://moewalls.com/")!
    private let client: MoeWallsHTTPClient
    private let probeService: MoeWallsProbeService
    private let restPageSize = 100
    private let archiveDetailFetchLimit = 20
    private let catalogRESTBatchSize = 4
    private let detailCacheLimit = 160

    private var probeResult: MoeWallsProbeResult?
    private var detailCache: [String: MoeWallsWallpaper] = [:]
    private var detailCacheOrder: [String] = []

    init(client: MoeWallsHTTPClient = MoeWallsHTTPClient()) {
        self.client = client
        self.probeService = MoeWallsProbeService(client: client)
    }

    func clearCache() async {
        detailCache.removeAll()
        detailCacheOrder.removeAll()
        probeResult = nil
        if let cacheURL = try? catalogCacheURL() {
            try? FileManager.default.removeItem(at: cacheURL)
        }
    }

    func loadCachedCatalog() async -> [CatalogWallpaper]? {
        guard let cacheURL = try? catalogCacheURL(),
              let data = try? Data(contentsOf: cacheURL),
              let envelope = try? JSONDecoder().decode(MoeWallsCatalogCacheEnvelope.self, from: data) else {
            return nil
        }
        return envelope.wallpapers.isEmpty ? nil : envelope.wallpapers.map(\.asCatalogWallpaper)
    }

    func fetchCatalog() async throws -> [CatalogWallpaper] {
        let wallpapers = try await fetchCatalogWallpapers(progress: nil)
        guard !wallpapers.isEmpty else {
            throw MoeWallsSourceError.unavailable("MoeWalls catalog is unavailable.")
        }
        try persistCatalog(wallpapers)
        return wallpapers.map(\.asCatalogWallpaper)
    }

    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        let wallpapers = try await fetchCatalogWallpapers { partial in
            await progress(partial.map(\.asCatalogWallpaper))
        }
        guard !wallpapers.isEmpty else {
            throw MoeWallsSourceError.unavailable("MoeWalls catalog is unavailable.")
        }
        try persistCatalog(wallpapers)
        return wallpapers.map(\.asCatalogWallpaper)
    }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        if let source = wallpaper.sources.first {
            return source.url
        }
        guard let pageURL = wallpaper.sourcePageURL else {
            throw URLError(.badURL)
        }
        let details = try await fetchDetails(pageURL: pageURL)
        if let downloadURL = details.downloadURL {
            return downloadURL
        }
        if let previewVideoURL = details.previewVideoURL {
            return previewVideoURL
        }
        throw MoeWallsSourceError.missingDownloadURL
    }

    func fetchLatest(page: Int) async throws -> [MoeWallsWallpaper] {
        let probe = try await usableStrategy()
        switch probe {
        case .rest:
            return try await fetchLatestViaREST(page: page)
        case .sitemap:
            return try await fetchLatestViaSitemaps(page: page)
        case .archive:
            return try await fetchArchive(path: archivePath(page: page))
        case .unavailable:
            throw MoeWallsSourceError.unavailable("MoeWalls unavailable.")
        }
    }

    func fetchByCategory(slug: String, page: Int) async throws -> [MoeWallsWallpaper] {
        let probe = try await usableStrategy()
        switch probe {
        case .rest:
            return try await fetchRESTCollection(taxonomy: "categories", slug: slug, page: page)
        case .sitemap, .archive:
            return try await fetchArchive(path: archivePath(categorySlug: slug, page: page))
        case .unavailable:
            throw MoeWallsSourceError.unavailable("MoeWalls unavailable.")
        }
    }

    func fetchByTag(slug: String, page: Int) async throws -> [MoeWallsWallpaper] {
        let probe = try await usableStrategy()
        switch probe {
        case .rest:
            return try await fetchRESTCollection(taxonomy: "tags", slug: slug, page: page)
        case .sitemap, .archive:
            return try await fetchArchive(path: archivePath(tagSlug: slug, page: page))
        case .unavailable:
            throw MoeWallsSourceError.unavailable("MoeWalls unavailable.")
        }
    }

    func fetchByResolution(slug: String, page: Int) async throws -> [MoeWallsWallpaper] {
        let probe = try await usableStrategy()
        switch probe {
        case .rest, .sitemap, .archive:
            return try await fetchArchive(path: archivePath(resolutionSlug: slug, page: page))
        case .unavailable:
            throw MoeWallsSourceError.unavailable("MoeWalls unavailable.")
        }
    }

    func search(query: String, page: Int) async throws -> [MoeWallsWallpaper] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let probe = try await usableStrategy()
        switch probe {
        case .rest:
            return try await searchViaREST(query: trimmed, page: page)
        case .sitemap, .archive:
            let latest = try await fetchLatest(page: page)
            return latest.filter { wallpaper in
                wallpaper.title.localizedCaseInsensitiveContains(trimmed) ||
                    wallpaper.tags.contains(where: { $0.localizedCaseInsensitiveContains(trimmed) })
            }
        case .unavailable:
            throw MoeWallsSourceError.unavailable("MoeWalls unavailable.")
        }
    }

    func fetchDetails(pageURL: URL) async throws -> MoeWallsWallpaper {
        let cacheKey = pageURL.absoluteString
        if let cached = detailCache[cacheKey] {
            touchDetailCacheKey(cacheKey)
            return cached
        }

        let response = try await client.get(pageURL)
        let wallpaper = MoeWallsParser.parseWallpaperDetail(html: response.text, pageURL: pageURL)
        cacheDetailWallpaper(wallpaper, for: cacheKey)
        return wallpaper
    }

    private func touchDetailCacheKey(_ key: String) {
        detailCacheOrder.removeAll { $0 == key }
        detailCacheOrder.append(key)
    }

    private func cacheDetailWallpaper(_ wallpaper: MoeWallsWallpaper, for key: String) {
        detailCache[key] = wallpaper
        touchDetailCacheKey(key)

        while detailCacheOrder.count > detailCacheLimit {
            let oldestKey = detailCacheOrder.removeFirst()
            detailCache.removeValue(forKey: oldestKey)
        }
    }

    private func usableStrategy() async throws -> MoeWallsCatalogStrategy {
        if let probeResult {
            if probeResult.available {
                return probeResult.strategy
            }
            throw MoeWallsSourceError.unavailable(probeResult.reason ?? "MoeWalls unavailable.")
        }

        let result = await probeService.probe()
        probeResult = result
        if result.available {
            return result.strategy
        }
        throw MoeWallsSourceError.unavailable(result.reason ?? "MoeWalls unavailable.")
    }

    private func fetchLatestViaREST(page: Int) async throws -> [MoeWallsWallpaper] {
        let posts = try await fetchRESTPosts(queryItems: [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(restPageSize)),
            URLQueryItem(name: "_fields", value: "slug,link,title,date,categories,tags,resolutions,class_list,yoast_head_json"),
        ])
        return try await hydrateAndFilter(posts: posts)
    }

    private func fetchRESTCollection(taxonomy: String, slug: String, page: Int) async throws -> [MoeWallsWallpaper] {
        try await fetchRESTCollectionDirect(taxonomy: taxonomy, slug: slug, page: page)
    }

    private func fetchRESTCollectionDirect(taxonomy: String, slug: String, page: Int) async throws -> [MoeWallsWallpaper] {
        let termID = try await fetchRESTTermID(taxonomy: taxonomy, slug: slug)
        let queryName = taxonomy == "categories" ? "categories" : "tags"
        let posts = try await fetchRESTPosts(queryItems: [
            URLQueryItem(name: queryName, value: String(termID)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(restPageSize)),
            URLQueryItem(name: "_fields", value: "slug,link,title,date,categories,tags,resolutions,class_list,yoast_head_json"),
        ])
        return try await hydrateAndFilter(posts: posts)
    }

    private func searchViaREST(query: String, page: Int) async throws -> [MoeWallsWallpaper] {
        let posts = try await fetchRESTPosts(queryItems: [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(restPageSize)),
            URLQueryItem(name: "_fields", value: "slug,link,title,date,categories,tags,resolutions,class_list,yoast_head_json"),
        ])
        return try await hydrateAndFilter(posts: posts)
    }

    private func fetchRESTPostsPage(queryItems: [URLQueryItem]) async throws -> ([MoeWallsRESTPost], Int?) {
        let url = makeRESTURL(path: "wp/v2/posts", queryItems: queryItems)
        let response = try await client.get(url, accept: "application/json,text/html")
        let posts = try JSONDecoder().decode([MoeWallsRESTPost].self, from: response.data)
        let totalPages = response.response.value(forHTTPHeaderField: "X-WP-TotalPages").flatMap(Int.init)
        return (posts, totalPages)
    }

    private func fetchRESTPosts(queryItems: [URLQueryItem]) async throws -> [MoeWallsRESTPost] {
        let (posts, _) = try await fetchRESTPostsPage(queryItems: queryItems)
        return posts
    }

    private func fetchRESTTermID(taxonomy: String, slug: String) async throws -> Int {
        let url = makeRESTURL(path: "wp/v2/\(taxonomy)", queryItems: [
            URLQueryItem(name: "slug", value: slug),
            URLQueryItem(name: "_fields", value: "id,name,slug"),
        ])
        let response = try await client.get(url, accept: "application/json,text/html")
        let terms = try JSONDecoder().decode([MoeWallsTaxonomyTerm].self, from: response.data)
        guard let first = terms.first else {
            throw MoeWallsSourceError.unavailable("MoeWalls taxonomy term not found: \(slug)")
        }
        return first.id
    }

    private func hydrateAndFilter(posts: [MoeWallsRESTPost]) async throws -> [MoeWallsWallpaper] {
        deduplicate(
            posts
                .compactMap(makeWallpaper(from:))
                .filter(isSupported(_:))
        )
    }

    private func fetchLatestViaSitemaps(page: Int) async throws -> [MoeWallsWallpaper] {
        let sitemapURLs = try await discoverSitemapURLs()
        let postSitemaps = sitemapURLs.filter { $0.absoluteString.localizedCaseInsensitiveContains("post-sitemap") }
        guard !postSitemaps.isEmpty else {
            return try await fetchArchive(path: archivePath(page: page))
        }

        let sitemapIndex = max(0, min(page - 1, postSitemaps.count - 1))
        let urlSet = try await client.get(postSitemaps[sitemapIndex], accept: "application/xml,text/xml,text/html")
        let urls = MoeWallsParser.parseURLSet(xml: urlSet.data)
        let detailURLs = urls.filter(isWallpaperDetailURL(_:))

        var wallpapers: [MoeWallsWallpaper] = []
        for pageURL in detailURLs.prefix(archiveDetailFetchLimit) {
            let details = try await fetchDetails(pageURL: pageURL)
            if isSupported(details) {
                wallpapers.append(details)
            }
        }
        return deduplicate(wallpapers)
    }

    private func discoverSitemapURLs() async throws -> [URL] {
        let robotsURL = baseURL.appending(path: "robots.txt")
        let robotsResponse = try await client.get(robotsURL, accept: "text/plain,text/html")
        let lines = robotsResponse.text.components(separatedBy: .newlines)
        let sitemapURL = lines.first { $0.lowercased().hasPrefix("sitemap:") }
            .flatMap { line in
                URL(string: line.replacingOccurrences(of: "Sitemap:", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces))
            }
            ?? baseURL.appending(path: "sitemap_index.xml")
        let sitemapResponse = try await client.get(sitemapURL, accept: "application/xml,text/xml,text/html")
        return MoeWallsParser.parseSitemapIndex(xml: sitemapResponse.data)
    }

    private func fetchArchive(path: String) async throws -> [MoeWallsWallpaper] {
        let response = try await client.get(baseURL.appending(path: path))
        let parsed = MoeWallsParser.parseArchivePage(html: response.text, pageURL: baseURL.appending(path: path))
        let selected = Array(parsed.wallpapers.prefix(archiveDetailFetchLimit))
        var resolved: [MoeWallsWallpaper] = []

        for wallpaper in selected {
            let details = try await fetchDetails(pageURL: wallpaper.pageURL)
            if isSupported(details) {
                resolved.append(details)
            }
        }

        return deduplicate(resolved)
    }

    private func fetchCatalogWallpapers(
        progress: (@Sendable ([MoeWallsWallpaper]) async -> Void)?
    ) async throws -> [MoeWallsWallpaper] {
        let restWallpapers = (try? await fetchCatalogViaREST(progress: progress)) ?? []
        if !restWallpapers.isEmpty {
            return restWallpapers
        }

        let archiveWallpapers = (try? await fetchCatalogViaArchive(progress: progress)) ?? []
        if !archiveWallpapers.isEmpty {
            return archiveWallpapers
        }

        return []
    }

    private func fetchCatalogViaREST(
        progress: (@Sendable ([MoeWallsWallpaper]) async -> Void)?
    ) async throws -> [MoeWallsWallpaper] {
        var aggregated: [MoeWallsWallpaper] = []
        let termID = try await fetchRESTTermID(taxonomy: "categories", slug: "anime")
        let firstPage = try await fetchCatalogRESTPage(termID: termID, page: 1)
        guard !firstPage.posts.isEmpty else {
            return []
        }

        aggregated.append(contentsOf: firstPage.wallpapers)
        if let progress {
            await progress(deduplicate(aggregated))
        }

        let totalPages = max(1, firstPage.totalPages ?? 1)
        guard totalPages > 1 else {
            return deduplicate(aggregated)
        }

        var nextPage = 2
        while nextPage <= totalPages {
            let upperBound = min(totalPages, nextPage + catalogRESTBatchSize - 1)
            let pageRange = Array(nextPage...upperBound)
            let batchResults = try await withThrowingTaskGroup(of: (Int, [MoeWallsWallpaper]).self) { group in
                for page in pageRange {
                    group.addTask { [self] in
                        let result = try await fetchCatalogRESTPage(termID: termID, page: page)
                        return (page, result.wallpapers)
                    }
                }

                var collected: [(Int, [MoeWallsWallpaper])] = []
                for try await result in group {
                    collected.append(result)
                }
                return collected
            }

            for (_, wallpapers) in batchResults.sorted(by: { $0.0 < $1.0 }) {
                aggregated.append(contentsOf: wallpapers)
            }

            if let progress {
                await progress(deduplicate(aggregated))
            }

            nextPage = upperBound + 1
        }

        return deduplicate(aggregated)
    }

    private func fetchCatalogRESTPage(termID: Int, page: Int) async throws -> (posts: [MoeWallsRESTPost], wallpapers: [MoeWallsWallpaper], totalPages: Int?) {
        let (posts, totalPages) = try await fetchRESTPostsPage(queryItems: [
            URLQueryItem(name: "categories", value: String(termID)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(restPageSize)),
            URLQueryItem(name: "_fields", value: "slug,link,title,date,categories,tags,resolutions,class_list,yoast_head_json"),
        ])
        let wallpapers = try await hydrateAndFilter(posts: posts)
        return (posts, wallpapers, totalPages)
    }

    private func fetchCatalogViaArchive(
        progress: (@Sendable ([MoeWallsWallpaper]) async -> Void)?
    ) async throws -> [MoeWallsWallpaper] {
        var aggregated: [MoeWallsWallpaper] = []
        var page = 1

        while true {
            let path = archivePath(categorySlug: "anime", page: page)
            let pageWallpapers = try await fetchArchive(path: path)
            if pageWallpapers.isEmpty {
                break
            }
            aggregated.append(contentsOf: pageWallpapers)
            let deduplicated = deduplicate(aggregated)
            if let progress {
                await progress(deduplicated)
            }
            page += 1
        }

        return deduplicate(aggregated)
    }

    private func isSupported(_ wallpaper: MoeWallsWallpaper) -> Bool {
        wallpaper.category.localizedCaseInsensitiveContains("anime") &&
            (wallpaper.resolution?.isSupportedForAuraFlow ?? false)
    }

    private func deduplicate(_ wallpapers: [MoeWallsWallpaper]) -> [MoeWallsWallpaper] {
        var seen = Set<String>()
        var unique: [MoeWallsWallpaper] = []
        for wallpaper in wallpapers {
            let key = wallpaper.pageURL.absoluteString
            if seen.insert(key).inserted {
                unique.append(wallpaper)
            }
        }
        return unique
    }

    private func makeWallpaper(from post: MoeWallsRESTPost) -> MoeWallsWallpaper? {
        guard let pageURL = URL(string: post.link) else {
            return nil
        }

        let previewImageURL = post.yoastHeadJSON?.ogImage?.first.flatMap { URL(string: $0.url) }
        let schemaNodes = post.yoastHeadJSON?.schema?.graph ?? []
        let category = schemaNodes
            .compactMap { $0.articleSection?.first }
            .first
            ?? pageURL.pathComponents.dropFirst().first.map(titleFromSlug(_:))
            ?? "Anime"
        let tags = Array(
            Set(
                schemaNodes
                    .flatMap { $0.keywords ?? [] }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
        let resolution = post.classList?.values
            .compactMap { value -> MoeWallsResolution? in
                guard let range = value.range(of: "resolutions-") else {
                    return nil
                }
                return MoeWallsResolution.parse(String(value[range.upperBound...]))
            }
            .first
        let publishedAt = parsePublishedAt(post.date)

        return MoeWallsWallpaper(
            id: "moewalls-\(post.slug)",
            slug: post.slug,
            title: cleanupTitle(post.title.rendered),
            pageURL: pageURL,
            previewImageURL: previewImageURL,
            previewVideoURL: nil,
            category: category,
            tags: tags,
            resolution: resolution,
            fileSizeMB: nil,
            sourceName: "MoeWalls",
            publishedAt: publishedAt,
            downloadURL: nil,
            hasExplicitPlayableSource: nil
        )
    }

    private func cleanupTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(" Live Wallpaper") {
            return String(trimmed.dropLast(" Live Wallpaper".count))
        }
        return trimmed
    }

    private func parsePublishedAt(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: raw)
    }

    private func titleFromSlug(_ slug: String) -> String {
        slug
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part in
                let value = String(part)
                guard let first = value.first else { return value }
                return first.uppercased() + value.dropFirst()
            }
            .joined(separator: " ")
    }

    private func makeRESTURL(path: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/wp-json/\(path)"
        components.queryItems = queryItems
        return components.url!
    }

    private func archivePath(categorySlug: String? = nil, tagSlug: String? = nil, resolutionSlug: String? = nil, page: Int) -> String {
        let basePath: String
        if let categorySlug {
            basePath = "category/\(categorySlug)/"
        } else if let tagSlug {
            basePath = "tag/\(tagSlug)/"
        } else if let resolutionSlug {
            basePath = "resolution/\(resolutionSlug)/"
        } else {
            basePath = ""
        }

        if page <= 1 {
            return basePath
        }
        return "\(basePath)page/\(page)/"
    }

    private func catalogCacheURL() throws -> URL {
        try catalogSupportDirectory().appendingPathComponent("moewalls-cache.json")
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

    private func persistCatalog(_ wallpapers: [MoeWallsWallpaper]) throws {
        let envelope = MoeWallsCatalogCacheEnvelope(updatedAt: Date(), wallpapers: wallpapers)
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: try catalogCacheURL(), options: .atomic)
    }

    private func isWallpaperDetailURL(_ url: URL) -> Bool {
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        return parts.count == 2 && !["category", "tag", "resolution", "page", "wp-json"].contains(parts[0].lowercased())
    }
}

private struct MoeWallsCatalogCacheEnvelope: Codable {
    let updatedAt: Date
    let wallpapers: [MoeWallsWallpaper]
}
