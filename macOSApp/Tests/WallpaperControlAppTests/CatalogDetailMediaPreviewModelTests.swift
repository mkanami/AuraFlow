import Foundation
import Testing
@testable import WallpaperControlApp

@Test @MainActor
func catalogDetailWaitsForResolvedPreviewInsteadOfStreamingRemoteOriginal() {
    let mp4URL = URL(string: "https://example.com/preview.mp4")!
    let webMURL = URL(string: "https://example.com/preview.webm")!
    let wallpaper = previewTestWallpaper(sources: [mp4URL, webMURL])

    #expect(CatalogDetailMediaPreviewModel.immediatePreviewSource(for: wallpaper) == nil)
}

@Test @MainActor
func catalogDetailDoesNotStartRemoteNativeOriginalBeforeResolution() {
    let imageURL = URL(string: "https://example.com/poster.jpg")!
    let mp4URL = URL(string: "https://example.com/preview.mp4")!
    let wallpaper = previewTestWallpaper(sources: [imageURL, mp4URL])

    #expect(CatalogDetailMediaPreviewModel.immediatePreviewSource(for: wallpaper) == nil)
}

@Test @MainActor
func catalogDetailDoesNotTreatStaticImagesAsLivePreviews() {
    let wallpaper = previewTestWallpaper(
        sources: [URL(string: "https://example.com/poster.jpg")!]
    )

    #expect(CatalogDetailMediaPreviewModel.immediatePreviewSource(for: wallpaper) == nil)
}

@Test @MainActor
func catalogDetailKeepsFirstMovingWebRouteAfterItWins() async {
    let webMURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("catalog-preview.webm")
    let wallpaper = previewTestWallpaper(sources: [webMURL])
    let model = CatalogDetailMediaPreviewModel()

    await model.load(wallpaper)
    model.streamingPreviewDidStart(url: webMURL)
    model.streamingPreviewDidFail(url: webMURL, wallpaper: wallpaper)

    #expect(model.isVideoVisible)
    #expect(model.streamingVideoURL == webMURL)
    #expect(model.player == nil)
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
