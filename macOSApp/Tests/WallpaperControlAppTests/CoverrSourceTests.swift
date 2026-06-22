import Foundation
import Testing
@testable import WallpaperControlApp

@Test func coverrAPIHitBuildsDownloadableScenicWallpaper() {
    let hit = CoverrVideoHit(
        id: "waterfall-nature-123",
        title: "Waterfall in a Mountain Forest",
        poster: URL(string: "https://storage.coverr.co/p/waterfall"),
        thumbnail: URL(string: "https://storage.coverr.co/t/waterfall"),
        description: "A wide landscape shot of a waterfall in nature.",
        isVertical: false,
        tags: ["waterfall", "forest", "nature"],
        aspectRatio: "16:9",
        duration: 12.5,
        maxHeight: 2160,
        maxWidth: 3840,
        urls: CoverrVideoURLs(
            mp4: URL(string: "https://storage.coverr.co/videos/waterfall-token"),
            mp4Preview: URL(string: "https://storage.coverr.co/videos/waterfall-preview"),
            mp4Download: URL(string: "https://storage.coverr.co/videos/waterfall-download")
        )
    )

    let wallpaper = CoverrParser.makeCatalogWallpaper(from: hit)

    #expect(wallpaper?.id == "coverr-waterfall-nature-123")
    #expect(wallpaper?.title == "Waterfall in a Mountain Forest")
    #expect(wallpaper?.category == "Scenic")
    #expect(wallpaper?.attribution == "Coverr")
    #expect(wallpaper?.catalogGroup == .scenic)
    #expect(wallpaper?.sources.map(\.url.absoluteString) == [
        "https://storage.coverr.co/videos/waterfall-token",
        "https://storage.coverr.co/videos/waterfall-download",
    ])
}

@Test func coverrParserRejectsVerticalAndLowResolutionVideos() {
    let vertical = coverrHit(
        id: "vertical",
        title: "Vertical Waterfall",
        isVertical: true,
        aspectRatio: "9:16",
        maxWidth: 1080,
        maxHeight: 1920
    )
    let lowResolution = coverrHit(
        id: "low-res",
        title: "Small Waterfall",
        maxWidth: 1280,
        maxHeight: 720
    )

    #expect(CoverrParser.makeCatalogWallpaper(from: vertical) == nil)
    #expect(CoverrParser.makeCatalogWallpaper(from: lowResolution) == nil)
}

@Test func coverrParserRejectsPeopleTextAndLogoVideos() {
    let people = coverrHit(id: "people", title: "Person Walking by a Waterfall")
    let text = coverrHit(id: "text", title: "Waterfall With Text Overlay")
    let logo = coverrHit(id: "logo", title: "Nature Brand Logo Animation")

    #expect(CoverrParser.makeCatalogWallpaper(from: people) == nil)
    #expect(CoverrParser.makeCatalogWallpaper(from: text) == nil)
    #expect(CoverrParser.makeCatalogWallpaper(from: logo) == nil)
}

private func coverrHit(
    id: String,
    title: String,
    isVertical: Bool = false,
    aspectRatio: String = "16:9",
    maxWidth: Int = 1920,
    maxHeight: Int = 1080
) -> CoverrVideoHit {
    CoverrVideoHit(
        id: id,
        title: title,
        poster: URL(string: "https://storage.coverr.co/p/\(id)"),
        thumbnail: URL(string: "https://storage.coverr.co/t/\(id)"),
        description: "Nature scenery with waterfall, forest, mountain and ocean themes.",
        isVertical: isVertical,
        tags: ["nature", "waterfall", "forest"],
        aspectRatio: aspectRatio,
        duration: 8.0,
        maxHeight: maxHeight,
        maxWidth: maxWidth,
        urls: CoverrVideoURLs(
            mp4: URL(string: "https://storage.coverr.co/videos/\(id)"),
            mp4Preview: URL(string: "https://storage.coverr.co/videos/\(id)/preview"),
            mp4Download: URL(string: "https://storage.coverr.co/videos/\(id)/download")
        )
    )
}
