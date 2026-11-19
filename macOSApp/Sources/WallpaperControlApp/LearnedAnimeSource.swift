import Foundation
import SwiftSoup

/// Public, read-only operations learned with api-anything. Only the HTTP URL
/// templates and HTML extraction recipes are used; no browser/session is shipped.
enum LearnedAnimeSite: String, CaseIterable, Sendable {
    case desktophut, livewallpapers4free, livelywallpaper

    var title: String {
        switch self {
        case .desktophut: return "DesktopHut"
        case .livewallpapers4free: return "LiveWallpapers4Free"
        case .livelywallpaper: return "Lively Wallpaper"
        }
    }
    var baseURL: URL {
        switch self {
        case .desktophut: return URL(string: "https://www.desktophut.com/")!
        case .livewallpapers4free: return URL(string: "https://livewallpapers4free.com/")!
        case .livelywallpaper: return URL(string: "https://livelywallpaper.app/")!
        }
    }

    func accepts(_ url: URL, media: Bool = false) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        let hosts: [String]
        switch self {
        case .desktophut where media: hosts = ["www.desktophut.com", "media.desktophut.com"]
        case .livelywallpaper where media: hosts = ["livelywallpaper.app", "cdn.livelywallpaper.app"]
        default: hosts = [baseURL.host!]
        }
        return hosts.contains(url.host?.lowercased() ?? "")
    }
}

struct LearnedCatalogAPI: Decodable, Sendable {
    struct Recipe: Decodable, Sendable {
        let items: String
        let fields: [String: String]
        let empty: String?
    }
    struct Operation: Decodable, Sendable {
        struct Trigger: Decodable, Sendable { let url: String }
        struct Response: Decodable, Sendable { let html: Recipe? }
        func htmlRecipe() throws -> Recipe {
            guard let recipe = response.html else { throw LearnedCatalogError.unavailable("Missing HTML extraction recipe: \(name).") }
            return recipe
        }
        let name: String
        let trigger: Trigger
        let response: Response
    }
    let operations: [Operation]

    static func load(_ site: LearnedAnimeSite) throws -> Self {
        guard let url = AppResources.bundle?.url(forResource: "\(site.rawValue)-api", withExtension: "json") else {
            throw LearnedCatalogError.unavailable("Missing \(site.title) catalog operations.")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func operation(_ name: String) throws -> Operation {
        guard let operation = operations.first(where: { $0.name == name }) else {
            throw LearnedCatalogError.unavailable("Missing catalog operation: \(name).")
        }
        return operation
    }
}

enum LearnedCatalogError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}

enum LearnedCatalogHTML {
    /// The same CSS + @attribute / all: notation as api-anything's HTML recipes.
    static func extract(_ html: String, recipe: LearnedCatalogAPI.Recipe, baseURL: URL) throws -> [[String: [String]]] {
        let document = try SwiftSoup.parse(html, baseURL.absoluteString)
        try document.select("script, style, noscript, template, [hidden]").remove()
        let elements = try document.select(recipe.items)
        if elements.isEmpty() {
            if let empty = recipe.empty, !(try document.select(empty)).isEmpty() { return [] }
            throw LearnedCatalogError.unavailable("The catalog page format has changed or access is unavailable.")
        }
        return try elements.map { element in
            var row: [String: [String]] = [:]
            for (key, field) in recipe.fields {
                let all = field.hasPrefix("all:")
                let expression = all ? String(field.dropFirst(4)) : field
                let parts = expression.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
                let selector = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let targets = selector.isEmpty ? [element] : try element.select(selector).array()
                row[key] = try (all ? targets : Array(targets.prefix(1))).compactMap { target in
                    let value = try parts.count == 2 ? target.attr(String(parts[1])) : target.text()
                    guard !value.isEmpty else { return nil }
                    if parts.count == 2, ["href", "src"].contains(String(parts[1])) {
                        return URL(string: value, relativeTo: baseURL)?.absoluteURL.absoluteString
                    }
                    return value
                }
            }
            return row
        }
    }

    static func nextURL(_ html: String, baseURL: URL, site: LearnedAnimeSite) throws -> URL? {
        let document = try SwiftSoup.parse(html, baseURL.absoluteString)
        let link = try document.select("link[rel=next], a[rel=next], a.next.page-numbers").first()
        guard let value = try link?.attr("href"), let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              site.accepts(url), url != baseURL else { return nil }
        return url
    }

    static func dimensions(_ label: String) -> (Int, Int) {
        if let range = label.range(of: #"\d{3,5}[x×]\d{3,5}"#, options: .regularExpression) {
            let parts = label[range].split(whereSeparator: { $0 == "x" || $0 == "×" })
            return (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
        }
        let text = label.lowercased()
        if text.contains("8k") { return (7680, 4320) }
        if text.contains("4k") { return (3840, 2160) }
        if text.contains("2k") { return (2560, 1440) }
        if text.contains("hd") { return (1920, 1080) }
        return (0, 0)
    }
}

actor LearnedAnimeSource: WallpaperCatalogProviding, WallpaperCatalogPaging, WallpaperCatalogSearching,
    WallpaperCatalogMediaResolving, WallpaperCatalogPreviewResolving, CatalogCacheClearing {
    let site: LearnedAnimeSite
    private let api: Result<LearnedCatalogAPI, Error>
    private let session: URLSession
    private let cacheDirectory: URL?
    private let musicCollection: Bool
    private var nextURL: URL?
    private var loaded: [CatalogWallpaper] = []
    private var visited = Set<URL>()
    private var resolved: [String: CatalogResolvedMedia] = [:]

    init(site: LearnedAnimeSite, session: URLSession = .shared,
         cacheDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AuraFlow/LearnedCatalogs", isDirectory: true), musicCollection: Bool = false) {
        self.site = site
        self.api = Result { try LearnedCatalogAPI.load(site) }
        self.session = session
        self.cacheDirectory = cacheDirectory
        self.musicCollection = musicCollection
    }

    private struct Cache: Codable { let wallpapers: [CatalogWallpaper]; let nextURL: URL? }
    private var cacheURL: URL? { cacheDirectory?.appendingPathComponent("\(site.rawValue)\(musicCollection ? "-music" : "").json") }
    private var listOperation: String { musicCollection ? "musicList" : "list" }

    func loadCachedCatalog() async -> [CatalogWallpaper]? {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return nil }
        return cache.wallpapers.isEmpty ? nil : cache.wallpapers
    }

    func clearCache() async {
        if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
        resolved.removeAll(); index = nil
    }

    func fetchCatalog() async throws -> [CatalogWallpaper] {
        if musicCollection, site == .livelywallpaper {
            loaded = try await indexCatalog(query: nil)
            nextURL = nil; visited = []; persist()
            return loaded
        }
        let firstOperation = site == .livelywallpaper ? "firstPage" : listOperation
        let url = try operationURL(firstOperation, arguments: ["page": "1", "tag": "wallpaper-with-music"])
        let page = try await fetchPage(url, operation: firstOperation)
        try Task.checkCancellation()
        loaded = page.items
        visited = [url]
        nextURL = page.next
        persist()
        return loaded
    }

    func fetchNextCatalogPage() async throws -> CatalogPage {
        guard let url = nextURL, !visited.contains(url) else { return CatalogPage(wallpapers: [], hasMore: false) }
        let page = try await fetchPage(url, operation: listOperation)
        try Task.checkCancellation()
        // A refresh can finish while the next-page request is in flight.
        guard nextURL == url, !visited.contains(url) else { return CatalogPage(wallpapers: [], hasMore: nextURL != nil) }
        visited.insert(url)
        let known = Set(loaded.map(\.id))
        let additions = page.items.filter { !known.contains($0.id) }
        loaded += additions
        nextURL = page.next.flatMap { visited.contains($0) ? nil : $0 }
        persist()
        return CatalogPage(wallpapers: additions, hasMore: nextURL != nil)
    }

    func searchCatalog(query: String) async throws -> [CatalogWallpaper] {
        try await searchCatalog(query: query, progress: { _ in })
    }

    func searchCatalog(query: String, progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        if site == .livelywallpaper {
            let items = try await indexCatalog(query: query)
            await progress(items)
            return items
        }
        var url: URL? = try operationURL("search", arguments: ["query": query, "page": "1"])
        var pages = Set<URL>()
        var items: [CatalogWallpaper] = []
        var ids = Set<String>()
        // Targeted, bounded search; never crawl an entire third-party library.
        while let current = url, pages.count < 3, pages.insert(current).inserted {
            try Task.checkCancellation()
            let page = try await fetchPage(current, operation: "search")
            items += page.items.filter { ids.insert($0.id).inserted }
            await progress(items)
            url = page.next
        }
        return items
    }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        guard let url = try await resolveMedia(for: wallpaper).originalSources.first?.url else { throw URLError(.fileDoesNotExist) }
        return url
    }

    func resolvePreviewSources(for wallpaper: CatalogWallpaper) async throws -> [CatalogVideoSource] {
        try await resolveMedia(for: wallpaper).previewSources
    }

    func invalidateResolvedMedia(for wallpaper: CatalogWallpaper) async { resolved[wallpaper.id] = nil }

    func resolveMedia(for wallpaper: CatalogWallpaper) async throws -> CatalogResolvedMedia {
        if let cached = resolved[wallpaper.id], cached.validUntil > Date() { return cached }
        guard let url = wallpaper.sourcePageURL, site.accepts(url) else { throw URLError(.badURL) }
        let document = try await fetchHTML(url)
        let html = document.html
        let recipe = try api.get().operation("detail").htmlRecipe()
        guard let row = try LearnedCatalogHTML.extract(html, recipe: recipe, baseURL: document.url).first else {
            throw URLError(.cannotParseResponse)
        }
        let labels = row["labels"] ?? []
        let originals = (row["original"] ?? []).enumerated().compactMap { index, value -> CatalogVideoSource? in
            guard let mediaURL = URL(string: value), site.accepts(mediaURL, media: true),
                  ["mp4", "m4v", "mov"].contains(mediaURL.pathExtension.lowercased()) ||
                    (site == .livewallpapers4free && mediaURL.path.range(of: #"^/download/\d+/?$"#, options: .regularExpression) != nil) else { return nil }
            let size = LearnedCatalogHTML.dimensions(labels.indices.contains(index) ? labels[index] : "")
            return CatalogVideoSource(url: mediaURL, width: size.0, height: size.1)
        }.sorted { $0.width * $0.height > $1.width * $1.height }
        guard !originals.isEmpty else {
            throw LearnedCatalogError.unavailable("\(site.title): this wallpaper has no supported original video.")
        }
        let previews = (row["preview"] ?? []).compactMap { value -> CatalogVideoSource? in
            guard let mediaURL = URL(string: value), site.accepts(mediaURL, media: true), mediaURL.pathExtension.lowercased() == "mp4" else { return nil }
            return CatalogVideoSource(url: mediaURL, width: 640, height: 360)
        }
        let media = CatalogResolvedMedia(previewSources: previews.isEmpty ? originals : previews,
            originalSources: originals, provider: site.title, validUntil: Date().addingTimeInterval(3600))
        if resolved.count >= 128 { resolved.removeAll() }
        resolved[wallpaper.id] = media
        return media
    }

    private func operationURL(_ name: String, arguments: [String: String]) throws -> URL {
        var template = try api.get().operation(name).trigger.url
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        for (key, value) in arguments { template = template.replacingOccurrences(of: "{\(key)}", with: value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
        guard !template.contains("{"), let url = URL(string: template), site.accepts(url) else { throw URLError(.badURL) }
        return url
    }

    private func fetchPage(_ url: URL, operation: String) async throws -> (items: [CatalogWallpaper], next: URL?) {
        let document = try await fetchHTML(url)
        let html = document.html
        let recipe = try api.get().operation(operation).htmlRecipe()
        let rows = try LearnedCatalogHTML.extract(html, recipe: recipe, baseURL: document.url)
        var ids = Set<String>()
        let items = rows.compactMap { row -> CatalogWallpaper? in
            guard let title = row["title"]?.first, !title.isEmpty,
                  let value = row["url"]?.first, let pageURL = URL(string: value), site.accepts(pageURL),
                  (site == .livelywallpaper
                    ? pageURL.pathComponents.count == 3 && pageURL.pathComponents[1] == "live-wallpapers"
                    : pageURL.pathComponents.count == 2) else { return nil }
            // Scene ZIPs require Wallpaper Engine; they are not video downloads.
            if row["kind"]?.first?.lowercased() == "scene" { return nil }
            if !musicCollection, site == .livewallpapers4free, operation == "search",
               row["categories"]?.first?.contains("category-anime-live-wallpapers") != true { return nil }
            let id = "\(site.rawValue)-\(pageURL.lastPathComponent)"
            guard ids.insert(id).inserted else { return nil }
            let image = row["image"]?.first.flatMap(URL.init(string:)).flatMap { site.accepts($0, media: true) ? $0 : nil }
            return CatalogWallpaper(id: id, title: title, category: "Anime", attribution: site.title,
                previewImageURL: image, sourcePageURL: pageURL, sources: [])
        }
        return (items, try LearnedCatalogHTML.nextURL(html, baseURL: document.url, site: site))
    }

    private struct Index: Decodable { let wallpapers: [IndexItem] }
    private struct IndexItem: Decodable {
        let slug: String
        let title: String
        let categories: [String]
        let search: String
        let cover_url: URL
        let preview_url: URL
        let download_url: URL
        let width: Int
        let height: Int
    }
    private var index: [IndexItem]?

    /// This site's search filters its public JSON index in the browser. Use the
    /// same index, so matches on later pages are included without crawling them.
    private func indexCatalog(query: String?) async throws -> [CatalogWallpaper] {
        let rows: [IndexItem]
        if let index { rows = index }
        else {
            let url = try operationURL("search", arguments: [:])
            let data = try await fetchData(url, mime: "application/json").data
            rows = try JSONDecoder().decode(Index.self, from: data).wallpapers
            index = rows
        }
        return rows.compactMap { row in
            guard row.categories.contains("anime"),
                  row.slug.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil,
                  site.accepts(row.cover_url, media: true), site.accepts(row.preview_url, media: true),
                  site.accepts(row.download_url, media: true), row.download_url.pathExtension == "mp4",
                  query.map({ WallpaperSearchMatcher.matches(query: $0, fields: [row.title, row.search]) }) ?? true else { return nil }
            let page = site.baseURL.appendingPathComponent("live-wallpapers/\(row.slug)/")
            let card = CatalogWallpaper(id: "\(site.rawValue)-\(row.slug)", title: row.title, category: "Anime",
                attribution: site.title, previewImageURL: row.cover_url, sourcePageURL: page, sources: [])
            resolved[card.id] = CatalogResolvedMedia(
                previewSources: [.init(url: row.preview_url, width: 640, height: 360)],
                originalSources: [.init(url: row.download_url, width: row.width, height: row.height)],
                provider: site.title, validUntil: Date().addingTimeInterval(3600))
            return card
        }
    }

    private func fetchHTML(_ url: URL) async throws -> (html: String, url: URL) {
        let document = try await fetchData(url, mime: "text/html")
        guard let html = String(data: document.data, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
        return (html, document.url)
    }

    private func fetchData(_ url: URL, mime: String) async throws -> (data: Data, url: URL) {
        guard site.accepts(url) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue(mime, forHTTPHeaderField: "Accept")
        request.setValue("AuraFlow/1.0 (wallpaper catalog)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else { throw CatalogDownloadError.badStatus(url: url, statusCode: http.statusCode) }
        guard let final = http.url, site.accepts(final), data.count <= 4 * 1024 * 1024,
              http.mimeType == mime else { throw URLError(.cannotParseResponse) }
        return (data, final)
    }

    private func persist() {
        guard let cacheURL, let data = try? JSONEncoder().encode(Cache(wallpapers: loaded, nextURL: nextURL)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
