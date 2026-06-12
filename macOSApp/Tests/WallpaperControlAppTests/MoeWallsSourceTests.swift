import Foundation
import Testing
@testable import WallpaperControlApp

@Test func moewallsChallengePageIsDetected() throws {
    let html = try loadFixture(named: "moewalls_challenge", ext: "html")
    #expect(MoeWallsParser.isChallengePage(html))
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

    *   [![Image 3](https://moewalls.com/wp-content/uploads/2026/03/musashi-soul-of-the-katana-vagabond-thumb-364x205.jpg)](https://moewalls.com/anime/musashi-soul-of-the-katana-vagabond-live-wallpaper/ "Musashi Soul Of The Katana Vagabond Live Wallpaper")
    *   [![Image 4](https://moewalls.com/wp-content/uploads/2026/03/gojo-hollow-purple-unlimited-void-jujutsu-kaisen-thumb-364x205.jpg)](https://moewalls.com/anime/gojo-hollow-purple-unlimited-void-jujutsu-kaisen-live-wallpaper/ "Gojo Hollow Purple Unlimited Void Jujutsu Kaisen Live Wallpaper")
    """

    let page = MoeWallsParser.parseArchivePage(
        html: markdown,
        pageURL: URL(string: "https://moewalls.com/category/anime/")!
    )

    #expect(page.wallpapers.count == 2)
    #expect(page.wallpapers[0].slug == "musashi-soul-of-the-katana-vagabond-live-wallpaper")
    #expect(page.wallpapers[0].previewVideoURL?.absoluteString == "https://moewalls.com/wp-content/uploads/preview/2026/musashi-soul-of-the-katana-vagabond-preview.webm")
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
    #expect(wallpaper.downloadURL?.absoluteString == "https://moewalls.com/wp-content/uploads/preview/2026/makima-chainsaw-man-preview.webm")
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
