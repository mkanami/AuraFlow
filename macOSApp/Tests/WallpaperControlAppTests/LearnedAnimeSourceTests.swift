import Foundation
import Testing
@testable import WallpaperControlApp

private func learnedFixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "html"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Test(arguments: LearnedAnimeSite.allCases)
func learnedCatalogLoadsPublicOperationsAndListing(site: LearnedAnimeSite) async throws {
    let api = try LearnedCatalogAPI.load(site)
    #expect(Set(api.operations.map(\.name)) == ["list", "search", "detail"])
    #expect(try api.operation("list").trigger.url.contains("{page}"))
    let html = try learnedFixture("\(site.rawValue)-listing")
    let http = LearnedFixtureHTTP { _ in html }
    defer { http.close() }
    let source = LearnedAnimeSource(site: site, session: http.session, cacheDirectory: nil)
    let items = try await source.fetchCatalog()
    #expect(items.count == (site == .desktophut ? 3 : 2))
    #expect(items.allSatisfy { $0.category == "Anime" && $0.attribution == site.title && $0.sources.isEmpty })
    #expect(items.allSatisfy { $0.previewImageURL != nil && $0.sourcePageURL != nil })
    #expect(items.first?.catalogGroup == .anime)
    #expect(http.requests.count == 1)
}

@Test func learnedRecipeMatchesApiAnythingRelativeLinksEntitiesAndHiddenElements() throws {
    let recipe = LearnedCatalogAPI.Recipe(items: "main", fields: ["title": "h2", "links": "all:a@href"], empty: nil)
    let rows = try LearnedCatalogHTML.extract("""
    <main><h2>Rain &amp; Light &#8211; 夜</h2><a href="../one">One</a>
    <a href="/two?a=1&amp;b=2">Two</a><a hidden href="/secret">Hidden</a>
    <template><a href="/template">Template</a></template></main>
    """, recipe: recipe, baseURL: URL(string: "https://example.com/category/anime/")!)
    #expect(rows.first?["title"] == ["Rain & Light – 夜"])
    #expect(rows.first?["links"] == ["https://example.com/category/one", "https://example.com/two?a=1&b=2"])
}

@Test func learnedPaginationDeduplicatesAndStopsAtLastPage() async throws {
    let first = "<a class=wallpaper-card href=/one><h3>One</h3></a>"
    let next = "<link rel=next href='?page=2'>"
    let http = LearnedFixtureHTTP { request in
        request.url?.query == "page=2" ? first + "<a class=wallpaper-card href=/two><h3>Two</h3></a>" : first + next
    }
    defer { http.close() }
    let source = LearnedAnimeSource(site: .desktophut, session: http.session, cacheDirectory: nil)
    #expect(try await source.fetchCatalog().map(\.title) == ["One"])
    let second = try await source.fetchNextCatalogPage()
    #expect(second.wallpapers.map(\.title) == ["Two"])
    #expect(!second.hasMore)
    #expect(try await source.fetchNextCatalogPage().wallpapers.isEmpty)
    #expect(http.requests.count == 2)
    #expect(try await source.fetchCatalog().map(\.title) == ["One"])
    #expect(try await source.fetchNextCatalogPage().wallpapers.map(\.title) == ["Two"])
}

@Test func learnedSourceCachesCatalogAndClearsOnlyItsOwnCache() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let html = try learnedFixture("desktophut-listing")
    let http = LearnedFixtureHTTP { _ in html }
    defer { http.close() }
    let source = LearnedAnimeSource(site: .desktophut, session: http.session, cacheDirectory: directory)
    let items = try await source.fetchCatalog()
    let restored = LearnedAnimeSource(site: .desktophut, session: http.session, cacheDirectory: directory)
    #expect(await restored.loadCachedCatalog() == items)
    try Data("untouched".utf8).write(to: directory.appendingPathComponent("other.json"))
    await restored.clearCache()
    #expect(await restored.loadCachedCatalog() == nil)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("other.json").path))
}

@Test func learnedSearchEncodesArgumentsFiltersNonAnimeAndDoesNotChangeBrowsePagination() async throws {
    let http = LearnedFixtureHTTP { request in
        if request.url?.query?.contains("s=") == true {
            return """
            <div id=primary><div class='post category-anime-live-wallpapers'><h2><a href=/miku>Miku</a></h2></div>
            <div class='post category-games-live-wallpapers'><h2><a href=/car>Car</a></h2></div></div>
            """
        }
        return "<div id=primary><div class=post><h2><a href=/anime>Anime</a></h2></div></div><link rel=next href='/category/anime-live-wallpapers/page/2/'>"
    }
    defer { http.close() }
    let source = LearnedAnimeSource(site: .livewallpapers4free, session: http.session, cacheDirectory: nil)
    _ = try await source.fetchCatalog()
    let query = "miku & rei/夜"
    #expect(try await source.searchCatalog(query: query).map(\.title) == ["Miku"])
    let search = try #require(http.requests.dropFirst().first?.url)
    #expect(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "s" })?.value == query)
    _ = try await source.fetchNextCatalogPage()
    #expect(http.requests.last?.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "category/anime-live-wallpapers/page/2")
}

@Test func learnedDesktopHutEmptySearchDoesNotReturnRecommendedWallpapers() async throws {
    let http = LearnedFixtureHTTP { _ in
        "<html><body><h1>No matches for test</h1><a class=wallpaper-card href=/recommended><h3>Unrelated</h3></a></body></html>"
    }
    defer { http.close() }
    let source = LearnedAnimeSource(site: .desktophut, session: http.session, cacheDirectory: nil)
    #expect(try await source.searchCatalog(query: "unmatched").isEmpty)
    #expect(try await source.searchCatalog(query: "  ").isEmpty)
    #expect(http.requests.count == 1)
}

@Test(arguments: LearnedAnimeSite.allCases)
func learnedMediaSeparatesPreviewFromOriginalAndInvalidatesCache(site: LearnedAnimeSite) async throws {
    let html = try learnedFixture("\(site.rawValue)-detail")
    let http = LearnedFixtureHTTP { _ in html }
    defer { http.close() }
    let source = LearnedAnimeSource(site: site, session: http.session, cacheDirectory: nil)
    let wallpaper = learnedCard(site: site)
    let media = try await source.resolveMedia(for: wallpaper)
    #expect(media.previewSources.count == 1)
    #expect(media.originalSources.count == (site == .desktophut ? 1 : 3))
    #expect(media.previewSources.first?.url != media.originalSources.first?.url)
    #expect(media.originalSources.first?.width == (site == .desktophut ? 4096 : 7680))
    #expect(try await source.resolveDownloadURL(for: wallpaper) == media.originalSources.first?.url)
    #expect(http.requests.count == 1)
    await source.invalidateResolvedMedia(for: wallpaper)
    _ = try await source.resolveMedia(for: wallpaper)
    #expect(http.requests.count == 2)
}

@Test func learnedSourceRejectsUnexpectedHostsNonVideoDownloadsAndChangedMarkup() async throws {
    let http = LearnedFixtureHTTP { _ in "<body><a id=primaryDownloadBtn href='https://www.desktophut.com/files/scene.zip'>Download</a></body>" }
    defer { http.close() }
    let source = LearnedAnimeSource(site: .desktophut, session: http.session, cacheDirectory: nil)
    await #expect(throws: (any Error).self) { try await source.resolveMedia(for: learnedCard(site: .desktophut)) }
    await #expect(throws: (any Error).self) { try await source.fetchCatalog() }
    let before = http.requests.count
    await #expect(throws: (any Error).self) {
        try await source.resolveMedia(for: learnedCard(site: .desktophut, page: "https://www.desktophut.com.attacker.test/wallpaper"))
    }
    #expect(http.requests.count == before)
    #expect(!LearnedAnimeSite.desktophut.accepts(URL(string: "https://www.desktophut.com@other.test/")!))
    #expect(!LearnedAnimeSite.desktophut.accepts(URL(string: "http://www.desktophut.com/")!))
    #expect(try LearnedCatalogHTML.nextURL("<link rel=next href='https://other.test/page/2'>", baseURL: LearnedAnimeSite.desktophut.baseURL, site: .desktophut) == nil)
}

@Test func learnedAnimeAggregateRoutesByHostAndSurvivesAnotherSourceFailure() async throws {
    let good = LearnedFixtureHTTP { request in
        if request.url?.path == "/wallpaper" { return try learnedFixture("desktophut-detail") }
        return try learnedFixture("desktophut-listing")
    }
    let bad = LearnedFixtureHTTP { _ in throw URLError(.cannotConnectToHost) }
    defer { good.close(); bad.close() }
    let desktop = LearnedAnimeSource(site: .desktophut, session: good.session, cacheDirectory: nil)
    let other = LearnedAnimeSource(site: .livewallpapers4free, session: bad.session, cacheDirectory: nil)
    let provider = AnimeWallpaperCatalogProvider(entries: [
        .init(hosts: ["www.desktophut.com"], provider: desktop),
        .init(hosts: ["livewallpapers4free.com"], provider: other),
    ])
    let items = try await provider.fetchCatalog()
    #expect(items.count == 3)
    let media = try await provider.resolveMedia(for: learnedCard(site: .desktophut))
    #expect(media.provider == "DesktopHut")
    #expect(bad.requests.count == 1)
}

private func learnedCard(site: LearnedAnimeSite, page: String? = nil) -> CatalogWallpaper {
    CatalogWallpaper(id: "\(site.rawValue)-wallpaper", title: "Wallpaper", category: "Anime", attribution: site.title,
        previewImageURL: nil, sourcePageURL: URL(string: page ?? site.baseURL.appendingPathComponent("wallpaper").absoluteString), sources: [])
}

@Test func learnedAnimeAggregatePreservesCachedMoeWallsCardsWithoutPageURLs() async throws {
    let media = CatalogVideoSource(url: URL(string: "https://moewalls.com/cached.mp4")!, width: 1920, height: 1080)
    let wallpaper = CatalogWallpaper(id: "moewalls-cached", title: "Cached", category: "Anime", attribution: "MoeWalls",
        previewImageURL: nil, sourcePageURL: nil, sources: [media])
    let provider = AnimeWallpaperCatalogProvider()
    let resolved = try await provider.resolveMedia(for: wallpaper)
    #expect(resolved.previewSources == [media])
    #expect(resolved.originalSources == [media])
}

private final class LearnedFixtureHTTP: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> String
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let id = UUID().uuidString
    private let handler: Handler
    let session: URLSession
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }

    init(handler: @escaping Handler) {
        self.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LearnedFixtureProtocol.self]
        config.httpAdditionalHeaders = ["X-AuraFlow-Fixture": id]
        session = URLSession(configuration: config)
        LearnedFixtureProtocol.register(self, id: id)
    }
    func respond(to request: URLRequest) throws -> String {
        lock.lock(); recorded.append(request); lock.unlock()
        return try handler(request)
    }
    func close() { session.invalidateAndCancel(); LearnedFixtureProtocol.remove(id: id) }
}

private final class LearnedFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: LearnedFixtureHTTP] = [:]
    static func register(_ fixture: LearnedFixtureHTTP, id: String) { lock.lock(); defer { lock.unlock() }; fixtures[id] = fixture }
    static func remove(id: String) { lock.lock(); defer { lock.unlock() }; fixtures[id] = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let fixture = Self.fixtures[request.value(forHTTPHeaderField: "X-AuraFlow-Fixture") ?? ""]
        Self.lock.unlock()
        do {
            guard let fixture, let url = request.url else { throw URLError(.badURL) }
            let html = try fixture.respond(to: request)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(html.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
