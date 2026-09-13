import Foundation
import Testing
@testable import WallpaperControlApp

@Test @MainActor
func catalogDetailPrefersImmediatelyStreamableWebMOverMP4Fallback() {
    let mp4URL = URL(string: "https://example.com/preview.mp4")!
    let webMURL = URL(string: "https://example.com/preview.webm")!
    let wallpaper = previewTestWallpaper(sources: [mp4URL, webMURL])

    #expect(CatalogDetailMediaPreviewModel.immediatePreviewSource(for: wallpaper) == .web(webMURL))
}

@Test @MainActor
func catalogDetailStartsNativeVideoWithoutPreparationWhenWebMIsUnavailable() {
    let imageURL = URL(string: "https://example.com/poster.jpg")!
    let mp4URL = URL(string: "https://example.com/preview.mp4")!
    let wallpaper = previewTestWallpaper(sources: [imageURL, mp4URL])

    #expect(CatalogDetailMediaPreviewModel.immediatePreviewSource(for: wallpaper) == .native(mp4URL))
}

@Test @MainActor
func catalogDetailDoesNotTreatStaticImagesAsLivePreviews() {
    let wallpaper = previewTestWallpaper(
        sources: [URL(string: "https://example.com/poster.jpg")!]
    )

    #expect(CatalogDetailMediaPreviewModel.immediatePreviewSource(for: wallpaper) == nil)
}

private func previewTestWallpaper(sources: [URL]) -> CatalogWallpaper {
    CatalogWallpaper(
        id: "preview-test",
        title: "Preview Test",
        category: "Anime",
        attribution: "Test",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://example.com/wallpaper"),
        sources: sources.map { CatalogVideoSource(url: $0, width: 1920, height: 1080) }
    )
}
