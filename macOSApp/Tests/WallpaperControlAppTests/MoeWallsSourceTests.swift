import Foundation
import Testing
@testable import WallpaperControlApp

@Test func moewallsChallengePageIsDetected() throws {
    let html = try loadFixture(named: "moewalls_challenge", ext: "html")
    #expect(MoeWallsParser.isChallengePage(html))
}

@Test func moewallsRealPageWithChallengeScriptIsNotRejected() {
    let html = """
    <html><body>
      <h1>Anime Live Wallpapers</h1>
      <script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script>
    </body></html>
    """

    #expect(!MoeWallsParser.isChallengePage(html))
}

@Test func moewallsHTTPClientUsesProxyAfterCrossHostRedirect() async throws {
    MoeWallsRedirectURLProtocol.reset()

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MoeWallsRedirectURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let client = MoeWallsHTTPClient(
        session: session,
        timeout: 2,
        maxRetries: 0,
        proxyBaseURL: "https://proxy.test/http://"
    )
    let response = try await client.get(URL(string: "https://moewalls.com/wp-json/")!)

    #expect(response.text == "{\"proxied\":true}")
    #expect(MoeWallsRedirectURLProtocol.requestedPaths == [
        "https://moewalls.com/wp-json/",
        "https://proxy.test/http://moewalls.com/wp-json/",
    ])
    #expect(MoeWallsRedirectURLProtocol.acceptHeaders == [
        "text/html,application/xml,application/json",
        "text/plain",
    ])
}

@Test func moewallsArchiveCardsAreParsed() throws {
    let html = try loadFixture(named: "moewalls_archive_anime", ext: "html")
    let page = MoeWallsParser.parseArchivePage(
        html: html,
        pageURL: URL(string: "https://moewalls.com/category/anime/")!
    )

    #expect(page.wallpapers.count == 2)
    #expect(page.hasNextPage)
    #expect(page.wallpapers[0].slug == "neon-ruins-live-wallpaper")
    #expect(page.wallpapers[0].title == "Neon Ruins Live Wallpaper")
    #expect(page.wallpapers[0].category == "Anime")
}

@Test func moewallsMarkdownArchiveCardsAreParsed() {
    let markdown = """
    Latest Videos

    *   [![Image 3](https://moewalls.com/wp-content/uploads/2026/03/musashi-soul-of-the-katana-vagabond-thumb-364x205.jpg)](https://moewalls.com/anime/musashi-soul-of-the-katana-vagabond-live-wallpaper/ "Musashi Soul Of The Katana Vagabond Live Wallpaper") [3840x2160](https://moewalls.com/resolution/3840x2160/)
    *   [![Image 4](https://moewalls.com/wp-content/uploads/2026/03/gojo-hollow-purple-unlimited-void-jujutsu-kaisen-thumb-364x205.jpg)](https://moewalls.com/anime/gojo-hollow-purple-unlimited-void-jujutsu-kaisen-live-wallpaper/ "Gojo Hollow Purple Unlimited Void Jujutsu Kaisen Live Wallpaper") [2560x1440](https://moewalls.com/resolution/2560x1440/)
    """

    let page = MoeWallsParser.parseArchivePage(
        html: markdown,
        pageURL: URL(string: "https://moewalls.com/category/anime/")!
    )

    #expect(page.wallpapers.count == 2)
    #expect(page.wallpapers[0].slug == "musashi-soul-of-the-katana-vagabond-live-wallpaper")
    #expect(page.wallpapers[0].previewVideoURL?.absoluteString == "https://moewalls.com/wp-content/uploads/preview/2026/musashi-soul-of-the-katana-vagabond-preview.webm")
    #expect(page.wallpapers[0].resolution == MoeWallsResolution(width: 3840, height: 2160))
    #expect(page.wallpapers[1].resolution == MoeWallsResolution(width: 2560, height: 1440))
}

@Test func moewallsCatalogPagesLoadIncrementallyAndDeduplicate() async throws {
    let firstCard = """
    * [![Image](https://moewalls.com/wp-content/uploads/2026/03/first-thumb.jpg)](https://moewalls.com/anime/first-live-wallpaper/ \"First Live Wallpaper\") [3840x2160](https://moewalls.com/resolution/3840x2160/)
    """
    let secondCard = """
    * [![Image](https://moewalls.com/wp-content/uploads/2026/03/second-thumb.jpg)](https://moewalls.com/anime/second-live-wallpaper/ \"Second Live Wallpaper\") [2560x1440](https://moewalls.com/resolution/2560x1440/)
    """
    MoeWallsPaginationURLProtocol.configure(pages: [
        1: firstCard,
        2: firstCard + "\n" + secondCard,
        3: "No more wallpapers",
    ])

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MoeWallsPaginationURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlow-MoeWalls-Paging-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = MoeWallsSource(
        client: MoeWallsHTTPClient(session: session, timeout: 2, maxRetries: 0),
        catalogDirectoryURL: directory
    )

    let firstPage = try await source.fetchNextCatalogPage()
    let secondPage = try await source.fetchNextCatalogPage()
    let finalPage = try await source.fetchNextCatalogPage()

    #expect(firstPage.wallpapers.map(\.id) == ["moewalls-first-live-wallpaper"])
    #expect(secondPage.wallpapers.map(\.id) == ["moewalls-second-live-wallpaper"])
    #expect(finalPage.wallpapers.isEmpty)
    #expect(!finalPage.hasMore)
    #expect(MoeWallsPaginationURLProtocol.requestedPages == [1, 2, 3])
    #expect(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("moewalls-cache.json").path
    ))
}

@Test func moewallsDetailPageIsParsed() throws {
    let html = try loadFixture(named: "moewalls_detail_neon_ruins", ext: "html")
    let wallpaper = MoeWallsParser.parseWallpaperDetail(
        html: html,
        pageURL: URL(string: "https://moewalls.com/anime/neon-ruins-live-wallpaper/")!
    )

    #expect(wallpaper.title == "Neon Ruins Live Wallpaper")
    #expect(wallpaper.category == "Anime")
    #expect(wallpaper.tags.contains("Black Hole"))
    #expect(wallpaper.tags.contains("Neon City"))
    #expect(wallpaper.resolution == MoeWallsResolution(width: 3840, height: 2160))
    #expect(wallpaper.resolution?.isSupportedForAuraFlow == true)
    #expect(wallpaper.fileSizeMB == 24.5)
    #expect(wallpaper.framesPerSecond == 60)
    #expect(wallpaper.sourceName == "Original Artist")
    #expect(wallpaper.downloadURL?.absoluteString == "https://media.moewalls.com/videos/neon-ruins-3840x2160.mp4")
}

@Test func moewallsDetailPageResolvesRelativePreviewVideoURLs() {
    let html = """
    <html>
      <head>
        <link rel="canonical" href="https://moewalls.com/anime/makima-chainsaw-man-6-live-wallpaper/">
        <meta property="og:title" content="Makima Chainsaw Man Live Wallpaper">
        <meta property="og:image" content="https://moewalls.com/wp-content/uploads/2026/04/makima-chainsaw-man-thumb.jpg">
      </head>
      <body>
        <video poster="/wp-content/uploads/2026/04/makima-chainsaw-man-thumb-728x410.jpg">
          <source src="/wp-content/uploads/preview/2026/makima-chainsaw-man-preview.webm" type="video/mp4" />
        </video>
      </body>
    </html>
    """

    let wallpaper = MoeWallsParser.parseWallpaperDetail(
        html: html,
        pageURL: URL(string: "https://moewalls.com/anime/makima-chainsaw-man-6-live-wallpaper/")!
    )

    #expect(wallpaper.previewVideoURL?.absoluteString == "https://moewalls.com/wp-content/uploads/preview/2026/makima-chainsaw-man-preview.webm")
    #expect(wallpaper.downloadURL == nil)
}

@Test func moewallsPreviewResolverDoesNotPrioritizeSyntheticMP4() async throws {
    let mp4 = URL(string: "https://moewalls.com/wp-content/uploads/preview/test.mp4")!
    let webm = URL(string: "https://moewalls.com/wp-content/uploads/preview/test.webm")!
    let wallpaper = CatalogWallpaper(
        id: "moewalls-test",
        title: "Test",
        category: "Anime",
        attribution: "MoeWalls",
        previewImageURL: nil,
        sourcePageURL: nil,
        sources: [
            CatalogVideoSource(url: mp4, width: 1920, height: 1080),
            CatalogVideoSource(url: webm, width: 1920, height: 1080),
        ]
    )

    let media = try await MoeWallsSource().resolveMedia(for: wallpaper)
    let sources = media.previewSources

    #expect(sources.map(\.url) == [webm, mp4])
    #expect(media.originalSources.map(\.url) == [mp4, webm])
}

@Test func moewallsDetailPageResolvesTokenDownloadURL() {
    let html = """
    <html>
      <head>
        <link rel="canonical" href="https://moewalls.com/anime/lucyna-wuthering-waves-x-cyberpunk-edgerunners-live-wallpaper/">
        <meta property="og:title" content="Lucyna Wuthering Waves x Cyberpunk Edgerunners Live Wallpaper">
        <meta property="og:image" content="https://moewalls.com/wp-content/uploads/2026/06/lucyna-wuthering-waves-cyberpunk-edgerunners-thumb.jpg">
      </head>
      <body>
        <video>
          <source src="/wp-content/uploads/preview/2026/lucyna-wuthering-waves-×-cyberpunk-edgerunners-preview.webm" type="video/webm" />
        </video>
        <a
          id="moe-download"
          data-id="20474"
          data-url="skfkzJydxVqF%2BAZdOvcfgYzTM4FJj6eRMccDNoYpT909suPXMqFJ04mKmAQnMbrGAaIdrCkWuwjvAWqrynxQLrWKp9Q6XLhIS7RM7A%3D%3D"
          href="#">
          Download Wallpaper
        </a>
      </body>
    </html>
    """

    let wallpaper = MoeWallsParser.parseWallpaperDetail(
        html: html,
        pageURL: URL(string: "https://moewalls.com/anime/lucyna-wuthering-waves-x-cyberpunk-edgerunners-live-wallpaper/")!
    )

    #expect(
        wallpaper.downloadURL?.absoluteString ==
        "https://go.moewalls.com/download.php?video=skfkzJydxVqF%2BAZdOvcfgYzTM4FJj6eRMccDNoYpT909suPXMqFJ04mKmAQnMbrGAaIdrCkWuwjvAWqrynxQLrWKp9Q6XLhIS7RM7A%3D%3D"
    )
}

@Test func moewallsDerivesPreviewVideoFromThumbnail() {
    let previewImageURL = URL(string: "https://moewalls.com/wp-content/uploads/2026/03/musashi-soul-of-the-katana-vagabond-thumb.jpg")
    let previewURL = MoeWallsParser.derivedPreviewVideoURL(
        from: previewImageURL,
        slug: "musashi-soul-of-the-katana-vagabond"
    )

    #expect(previewURL?.absoluteString == "https://moewalls.com/wp-content/uploads/preview/2026/musashi-soul-of-the-katana-vagabond-preview.webm")
}

@Test func moewallsPreviewCandidatesPreferNativeMP4Fallback() {
    let wallpaper = MoeWallsWallpaper(
        id: "moewalls-musashi",
        slug: "musashi-soul-of-the-katana-vagabond-live-wallpaper",
        title: "Musashi",
        pageURL: URL(string: "https://moewalls.com/anime/musashi-soul-of-the-katana-vagabond-live-wallpaper/")!,
        previewImageURL: nil,
        previewVideoURL: URL(string: "https://moewalls.com/wp-content/uploads/preview/2026/musashi-soul-of-the-katana-vagabond-preview.webm"),
        category: "Anime",
        tags: [],
        resolution: nil,
        fileSizeMB: nil,
        framesPerSecond: nil,
        sourceName: "MoeWalls",
        publishedAt: nil,
        downloadURL: nil,
        hasExplicitPlayableSource: nil
    )

    let candidates = wallpaper.previewCandidateURLs

    #expect(candidates.count == 2)
    #expect(candidates.first?.absoluteString == "https://moewalls.com/wp-content/uploads/preview/2026/musashi-soul-of-the-katana-vagabond-preview.mp4")
    #expect(candidates.last?.absoluteString == "https://moewalls.com/wp-content/uploads/preview/2026/musashi-soul-of-the-katana-vagabond-preview.webm")
}

@MainActor
@Test func moewallsDownloadTokenResolvesToGoEndpoint() throws {
    let pageURL = URL(string: "https://moewalls.com/anime/lucyna-wuthering-waves-x-cyberpunk-edgerunners-live-wallpaper/")!
    let token = "skfkzJydxVqF%2BAZdOvcfgYzTM4FJj6eRMccDNoYpT909suPXMqFJ04mKmAQnMbrGAaIdrCkWuwjvAWqrynxQLrWKp9Q6XLhIS7RM7A%3D%3D"

    let resolved = try MoeWallsBrowserResolver.resolvedDownloadURL(from: token, pageURL: pageURL)

    #expect(
        resolved.absoluteString ==
        "https://go.moewalls.com/download.php?video=skfkzJydxVqF%2BAZdOvcfgYzTM4FJj6eRMccDNoYpT909suPXMqFJ04mKmAQnMbrGAaIdrCkWuwjvAWqrynxQLrWKp9Q6XLhIS7RM7A%3D%3D"
    )
}

@MainActor
@Test func moewallsExplicitURLStillPassesThroughResolver() throws {
    let pageURL = URL(string: "https://moewalls.com/anime/example-live-wallpaper/")!
    let url = "https://media.moewalls.com/videos/example.mp4"

    let resolved = try MoeWallsBrowserResolver.resolvedDownloadURL(from: url, pageURL: pageURL)

    #expect(resolved.absoluteString == url)
}

@Test func moewallsSitemapIndexIsParsed() throws {
    let xml = try loadFixtureData(named: "moewalls_sitemap_index", ext: "xml")
    let urls = MoeWallsParser.parseSitemapIndex(xml: xml)

    #expect(urls.count == 2)
    #expect(urls.first?.absoluteString == "https://moewalls.com/post-sitemap.xml")
}

@Test func moewallsRestRoutesAreParsed() throws {
    let data = try loadFixtureData(named: "moewalls_wp_json_root", ext: "json")
    let routes = MoeWallsParser.parseRESTRootRoutes(from: data)

    #expect(routes.contains("/wp/v2/posts"))
    #expect(routes.contains("/wp/v2/categories"))
    #expect(routes.contains("/wp/v2/tags"))
}

private func loadFixture(named name: String, ext: String) throws -> String {
    let data = try loadFixtureData(named: name, ext: ext)
    guard let string = String(data: data, encoding: .utf8) else {
        throw FixtureError.invalidEncoding
    }
    return string
}

private func loadFixtureData(named name: String, ext: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
        throw FixtureError.missingFixture(name)
    }
    return try Data(contentsOf: url)
}

private enum FixtureError: Error {
    case missingFixture(String)
    case invalidEncoding
}

private final class MoeWallsRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var paths: [String] = []
    private static var accepts: [String] = []

    static var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    static var acceptHeaders: [String] {
        lock.lock()
        defer { lock.unlock() }
        return accepts
    }

    static func reset() {
        lock.lock()
        paths = []
        accepts = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "moewalls.com" || request.url?.host == "proxy.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestedURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.paths.append(requestedURL.absoluteString)
        Self.accepts.append(request.value(forHTTPHeaderField: "Accept") ?? "")
        Self.lock.unlock()

        let responseURL = requestedURL.host == "moewalls.com"
            ? URL(string: "https://motionbgs.com/wp-json/")!
            : requestedURL
        let response = HTTPURLResponse(
            url: responseURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let body = Data((requestedURL.host == "moewalls.com" ? "redirected" : "{\"proxied\":true}").utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MoeWallsPaginationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var pageBodies: [Int: Data] = [:]
    private static var pages: [Int] = []

    static var requestedPages: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return pages
    }

    static func configure(pages: [Int: String]) {
        lock.lock()
        pageBodies = pages.mapValues { Data($0.utf8) }
        self.pages = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "moewalls.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let components = url.pathComponents
        let page: Int
        if let pageComponentIndex = components.firstIndex(of: "page"),
           components.indices.contains(pageComponentIndex + 1),
           let parsed = Int(components[pageComponentIndex + 1]) {
            page = parsed
        } else {
            page = 1
        }

        Self.lock.lock()
        Self.pages.append(page)
        let body = Self.pageBodies[page] ?? Data()
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
