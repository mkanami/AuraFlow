import Foundation
import Testing
@testable import WallpaperControlApp

@Test func motionBGSListingPageParsesItemsAndNextPage() {
    let html = """
    <html>
      <head>
        <link href=https://motionbgs.com/tag:anime-nature/2/ rel=next>
      </head>
      <body>
        <div class=tmb>
          <a title="Calm Blue Lake live wallpaper" href=/calm-blue-lake>
            <figure><img src=/i/c/364x205/media/9472/calm-blue-lake.3840x2160.jpg></figure>
            <span class=ttl>Calm Blue Lake</span>
            <span class=frm> 4K </span>
          </a>
        </div>
      </body>
    </html>
    """

    let page = MotionBGSParser.parseListingPage(
        html: html,
        baseURL: URL(string: "https://motionbgs.com/")!
    )

    #expect(page.items.count == 1)
    #expect(page.items.first?.title == "Calm Blue Lake")
    #expect(page.items.first?.pageURL.absoluteString == "https://motionbgs.com/calm-blue-lake")
    #expect(page.nextPath == "tag:anime-nature/2/")
}

@Test func motionBGSDetailPageBuildsDownloadableWallpaper() {
    let item = MotionBGSListItem(
        title: "Calm Blue Lake",
        pageURL: URL(string: "https://motionbgs.com/calm-blue-lake")!,
        previewImageURL: URL(string: "https://motionbgs.com/i/c/364x205/media/9472/calm-blue-lake.3840x2160.jpg")
    )
    let html = """
    <html>
      <head>
        <meta content=https://motionbgs.com/media/9472/calm-blue-lake.3840x2160.jpg property=og:image>
      </head>
      <body>
        <h1><span>Calm Blue Lake</span> Live Wallpaper</h1>
        <li><div><a href=/tag:anime-nature/>Anime Nature</a></div></li>
        <section class=dl>
          <a href=/dl/4k/9472 rel=nofollow target=_blank>
            <div class="text-lg mb-1"><span class=font-bold>4K</span> Wallpaper (18.1Mb)</div>
            <div class=text-xs>3840x2160 mp4 file</div>
          </a>
          <a href=/dl/hd/9472 rel=nofollow target=_blank>
            <div class="text-lg mb-1"><span class=font-bold>HD</span> Wallpaper (10.9Mb)</div>
            <div class=text-xs>1920x1080 mp4 file</div>
          </a>
        </section>
      </body>
    </html>
    """

    let wallpaper = MotionBGSParser.parseDetailPage(
        html: html,
        item: item,
        baseURL: URL(string: "https://motionbgs.com/")!
    )

    #expect(wallpaper?.id == "motionbgs-anime-nature-calm-blue-lake")
    #expect(wallpaper?.title == "Calm Blue Lake")
    #expect(wallpaper?.category == "Anime Nature")
    #expect(wallpaper?.attribution == "MotionBGS")
    #expect(wallpaper?.sources.map(\.url.absoluteString) == [
        "https://motionbgs.com/dl/4k/9472",
        "https://motionbgs.com/dl/hd/9472",
    ])
}

@Test func motionBGSSearchReturnsEveryExactCaseInsensitiveMatch() async throws {
    MotionBGSSearchURLProtocol.configure(html: """
    <div class=tmb>
      <a title="Hatsune Miku Star Eyes live wallpaper" href=/hatsune-miku-star-eyes>
        <img src=/miku-star-eyes.jpg>
        <span class=ttl>Hatsune Miku Star Eyes</span>
      </a>
      <a title="Miku's Aqua Melody live wallpaper" href=/mikus-aqua-melody>
        <img src=/miku-aqua.jpg>
        <span class=ttl>Miku's Aqua Melody</span>
      </a>
      <a title="Miko Shrine live wallpaper" href=/miko-shrine>
        <img src=/miko.jpg>
        <span class=ttl>Miko Shrine</span>
      </a>
      <a title="Mikasa Ackerman live wallpaper" href=/mikasa-ackerman>
        <img src=/mikasa.jpg>
        <span class=ttl>Mikasa Ackerman</span>
      </a>
    </div>
    """)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MotionBGSSearchURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let source = MotionBGSAnimeNatureSource(session: session)

    let results = try await source.searchCatalog(query: "mIkU")

    #expect(results.map(\.title) == [
        "Hatsune Miku Star Eyes",
        "Miku's Aqua Melody",
    ])
    #expect(MotionBGSSearchURLProtocol.requestedQuery == "mIkU")
}

@Test func motionBGSDetailPreviewUsesFullResolutionImageAndLiveVideo() {
    let thumbnailURL = URL(
        string: "https://motionbgs.com/i/c/364x205/media/9806/miku-nakano.3840x2160.jpg"
    )!
    let html = """
    <meta content=https://motionbgs.com/media/9806/miku-nakano.960x540.mp4 property=og:video>
    """

    let imageURL = MotionBGSParser.fullResolutionPreviewURL(from: thumbnailURL)
    let videoURL = MotionBGSParser.previewVideoURL(
        html: html,
        baseURL: URL(string: "https://motionbgs.com/")!
    )

    #expect(
        imageURL?.absoluteString ==
            "https://motionbgs.com/media/9806/miku-nakano.3840x2160.jpg"
    )
    #expect(
        videoURL?.absoluteString ==
            "https://motionbgs.com/media/9806/miku-nakano.960x540.mp4"
    )
}

@Test func motionBGSListingPosterDerivesLightweightPreviewWithoutDetailRequest() {
    let modernPoster = URL(
        string: "https://motionbgs.com/i/c/364x205/media/9964/summer-mountain-paradise.3840x2160.jpg"
    )!
    let legacyPoster = URL(
        string: "https://motionbgs.com/i/c/364x205/media/2763/samurai-spirit-under-the-moon.jpg"
    )!

    #expect(
        MotionBGSParser.derivedPreviewVideoURL(from: modernPoster)?.absoluteString ==
            "https://motionbgs.com/media/9964/summer-mountain-paradise.960x540.mp4"
    )
    #expect(
        MotionBGSParser.derivedPreviewVideoURL(from: legacyPoster)?.absoluteString ==
            "https://motionbgs.com/media/2763/samurai-spirit-under-the-moon.960x540.mp4"
    )
}

@Test func motionBGSPreviewResolverSelectsLightweightOGVideo() async throws {
    MotionBGSPreviewURLProtocol.configure(html: """
    <meta property="og:video" content="https://motionbgs.com/media/9806/miku-nakano.960x540.mp4">
    <div>FPS: 60</div>
    <a href=/dl/4k/9806 rel=nofollow target=_blank>
      <div class="text-lg mb-1"><span class=font-bold>4K</span> Wallpaper (38.2Mb)</div>
      <div class=text-xs>3840x2160 mp4 file</div>
    </a>
    """)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MotionBGSPreviewURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let wallpaper = CatalogWallpaper(
        id: "motion-preview",
        title: "Miku",
        category: "Anime Nature",
        attribution: "MotionBGS",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://motionbgs.com/miku")!,
        sources: []
    )

    let media = try await MotionBGSAnimeNatureSource(session: session)
        .resolveMedia(for: wallpaper)
    let sources = media.previewSources

    #expect(sources.map(\.url.absoluteString) == [
        "https://motionbgs.com/media/9806/miku-nakano.960x540.mp4"
    ])
    #expect(sources.first?.width == 960)
    #expect(sources.first?.height == 540)
    #expect(media.originalSources.map(\.url.absoluteString) == [
        "https://motionbgs.com/dl/4k/9806"
    ])
    #expect(media.fileSizeMB == 38.2)
    #expect(media.framesPerSecond == 60)
}

private final class MotionBGSPreviewURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responseData = Data()

    static func configure(html: String) {
        lock.lock()
        responseData = Data(html.utf8)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "motionbgs.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let data = Self.responseData
        Self.lock.unlock()
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MotionBGSSearchURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responseData = Data()
    private static var query: String?

    static var requestedQuery: String? {
        lock.lock()
        defer { lock.unlock() }
        return query
    }

    static func configure(html: String) {
        lock.lock()
        responseData = Data(html.utf8)
        query = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "motionbgs.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        Self.query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "q" })?
            .value
        let data = Self.responseData
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
