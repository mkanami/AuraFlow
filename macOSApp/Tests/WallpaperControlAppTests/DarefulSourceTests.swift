import Foundation
import Testing
@testable import WallpaperControlApp

@Test func darefulDetailPageBuildsDownloadableScenicWallpaper() {
    let html = """
    <html>
      <head>
        <meta property="og:image" content="https://dareful.com/wp-content/uploads/mountain-foliage-fall.jpg">
      </head>
      <body>
        <mux-player
          metadata-video-title="Mountain Foliage Fall"
          playback-id="7lLCv01rgqvjHF7gr2qV9kvXmt028RbGHmsBko2gCrB00A">
        </mux-player>
        <a rel="tag">Nature</a>
        <a rel="tag">Forest</a>
        <span>Resolution —1920 x 1080</span>
      </body>
    </html>
    """

    let wallpaper = DarefulParser.parseDetailPage(
        html: html,
        postID: 1744,
        fallbackTitle: "Fallback Title",
        pageURL: URL(string: "https://dareful.com/mountain-foliage-fall/")!
    )

    #expect(wallpaper?.id == "dareful-1744")
    #expect(wallpaper?.title == "Mountain Foliage Fall")
    #expect(wallpaper?.category == "Scenic")
    #expect(wallpaper?.attribution == "Dareful")
    #expect(wallpaper?.catalogGroup == .scenic)
    #expect(wallpaper?.previewImageURL?.absoluteString == "https://dareful.com/wp-content/uploads/mountain-foliage-fall.jpg")
    #expect(wallpaper?.sources.map(\.url.absoluteString) == [
        "https://stream.mux.com/7lLCv01rgqvjHF7gr2qV9kvXmt028RbGHmsBko2gCrB00A/high.mp4",
        "https://stream.mux.com/7lLCv01rgqvjHF7gr2qV9kvXmt028RbGHmsBko2gCrB00A/medium.mp4",
        "https://stream.mux.com/7lLCv01rgqvjHF7gr2qV9kvXmt028RbGHmsBko2gCrB00A/low.mp4",
    ])
}

@Test func darefulParserFallsBackToMuxDownloadHref() {
    let html = """
    <html>
      <head>
        <meta property="og:image:alt" content="Ocean Waves At Sunset">
      </head>
      <body>
        <a href="https://stream.mux.com/abc123xyz.m3u8">Download</a>
        <a rel="tag">Ocean</a>
        Resolution -3840 x 2160
      </body>
    </html>
    """

    let wallpaper = DarefulParser.parseDetailPage(
        html: html,
        postID: 42,
        fallbackTitle: "Fallback Title",
        pageURL: URL(string: "https://dareful.com/ocean-waves/")!
    )

    #expect(wallpaper?.sources.first?.url.absoluteString == "https://stream.mux.com/abc123xyz/high.mp4")
    #expect(wallpaper?.sources.first?.width == 3840)
    #expect(wallpaper?.sources.first?.height == 2160)
}

@Test func darefulParserRejectsPeopleTextLogoAndVerticalVideos() {
    #expect(darefulWallpaper(title: "Person Walking Near Waterfall", tags: ["nature"]) == nil)
    #expect(darefulWallpaper(title: "Nature Text Overlay", tags: ["forest"]) == nil)
    #expect(darefulWallpaper(title: "Mountain Logo Animation", tags: ["mountains"]) == nil)
    #expect(darefulWallpaper(title: "Small Ocean", tags: ["ocean"], resolution: "1280 x 720") == nil)
    #expect(darefulWallpaper(title: "Vertical Ocean", tags: ["ocean"], resolution: "1080 x 1920") == nil)
}

@Test func darefulParserRejectsNonScenicVideos() {
    #expect(darefulWallpaper(title: "Modern Office Desk", tags: ["business"]) == nil)
}

@Test func darefulPostPrioritizationInterleavesTags() {
    let posts = [
        darefulPost(id: 1, tags: [3], title: "Nature 1"),
        darefulPost(id: 2, tags: [3], title: "Nature 2"),
        darefulPost(id: 3, tags: [55], title: "Ocean 1"),
        darefulPost(id: 4, tags: [55], title: "Ocean 2"),
        darefulPost(id: 5, tags: [3], title: "Nature 3"),
    ]

    let prioritized = DarefulSource.prioritizePosts(posts, preferredTagIDs: [3, 55])

    #expect(prioritized.map(\.id) == [1, 3, 2, 4, 5])
}

private func darefulWallpaper(
    title: String,
    tags: [String],
    resolution: String = "1920 x 1080"
) -> CatalogWallpaper? {
    let tagHTML = tags.map { #"<a rel="tag">\#($0)</a>"# }.joined()
    let html = """
    <html>
      <body>
        <mux-player metadata-video-title="\(title)" playback-id="playback123"></mux-player>
        \(tagHTML)
        Resolution —\(resolution)
      </body>
    </html>
    """

    return DarefulParser.parseDetailPage(
        html: html,
        postID: 99,
        fallbackTitle: title,
        pageURL: URL(string: "https://dareful.com/test/")!
    )
}

private func darefulPost(id: Int, tags: [Int], title: String) -> DarefulPost {
    DarefulPost(
        id: id,
        slug: "post-\(id)",
        link: URL(string: "https://dareful.com/post-\(id)/")!,
        title: DarefulPost.RenderedText(rendered: title),
        tags: tags,
        featuredMedia: nil
    )
}
