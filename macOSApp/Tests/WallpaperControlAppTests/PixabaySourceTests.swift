import Foundation
import Testing
@testable import WallpaperControlApp

@Test func pixabaySearchPageParsesScenicVideos() {
    let html = """
    <a href="/videos/waterfall-rainbow-river-nature-246856/">
      <img
        alt="Image: Waterfall, Rainbow, River, Nature"
        src="https://cdn.pixabay.com/video/2024/12/15/246856_tiny.jpg">
    </a>
    <a href="/videos/emoji-waterfall-love-joy-icon-123/">
      <img
        alt="Image: Emoji, Waterfall, Love, Joy, Icon"
        src="https://cdn.pixabay.com/video/2024/12/15/123_tiny.jpg">
    </a>
    """

    let wallpapers = PixabayParser.parseSearchPage(
        html: html,
        pageURL: URL(string: "https://pixabay.com/videos/search/waterfall%20loop/")!
    )

    #expect(wallpapers.count == 1)
    #expect(wallpapers[0].id == "pixabay-246856")
    #expect(wallpapers[0].title == "Waterfall, Rainbow, River, Nature")
    #expect(wallpapers[0].category == "Scenic")
    #expect(wallpapers[0].attribution == "Pixabay")
    #expect(wallpapers[0].sourcePageURL?.absoluteString == "https://pixabay.com/videos/waterfall-rainbow-river-nature-246856/")
    #expect(wallpapers[0].catalogGroup == .scenic)
}

@Test func pixabayVideoCandidatesPreserveLegacyCdnSuffixes() {
    let thumbnailURL = URL(string: "https://cdn.pixabay.com/video/2022/11/19/139689-773418069_tiny.jpg")!
    let candidates = PixabayParser.videoCandidates(from: thumbnailURL)

    #expect(candidates.map(\.absoluteString) == [
        "https://cdn.pixabay.com/video/2022/11/19/139689-773418069_medium.mp4",
        "https://cdn.pixabay.com/video/2022/11/19/139689-773418069_large.mp4",
        "https://cdn.pixabay.com/video/2022/11/19/139689-773418069_small.mp4",
        "https://cdn.pixabay.com/video/2022/11/19/139689-773418069_tiny.mp4",
    ])
}

@Test func pixabayChallengePageIsDetected() {
    let html = """
    <html><head><title>Just a moment...</title></head>
    <body><script>window._cf_chl_opt = { cZone: "pixabay.com" };</script></body></html>
    """

    #expect(PixabayParser.isChallengePage(html))
}
