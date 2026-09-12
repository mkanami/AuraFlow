import Foundation
import Testing
@testable import WallpaperControlApp

@Test func catalogDownloadUsesMoeWallsPreviewWhenCachedSourcesAreMissing() async throws {
    let catalogDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowCatalogPreviewFallback-\(UUID().uuidString)", isDirectory: true)
    let temporaryDownload = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowCatalogPreviewFallbackSource-\(UUID().uuidString).webm")
    defer {
        try? FileManager.default.removeItem(at: catalogDirectory)
        try? FileManager.default.removeItem(at: temporaryDownload)
    }
    try Data("valid preview payload".utf8).write(to: temporaryDownload, options: .atomic)

    let wallpaper = CatalogWallpaper(
        id: "moewalls-preview-fallback",
        title: "Preview Fallback",
        category: "Anime",
        attribution: "MoeWalls",
        previewImageURL: URL(string: "https://moewalls.com/wp-content/uploads/2026/08/preview-fallback-thumb.jpg"),
        sourcePageURL: URL(string: "https://moewalls.com/anime/preview-fallback-live-wallpaper/"),
        sources: []
    )
    let service = CatalogDownloadService(
        provider: FailingCatalogDownloadProvider(),
        catalogDirectoryURL: catalogDirectory,
        fileDownloader: { _, _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://moewalls.com/wp-content/uploads/preview/2026/preview-fallback-preview.webm")!,
                statusCode: 200,
                httpVersion: "HTTP/2",
                headerFields: ["Content-Type": "video/webm"]
            )!
            return (temporaryDownload, response)
        }
    )

    let result = try await service.download(wallpaper)

    #expect(result.pathExtension == "webm")
    #expect(try Data(contentsOf: result) == Data("valid preview payload".utf8))
}

private struct FailingCatalogDownloadProvider: WallpaperCatalogProviding {
    func loadCachedCatalog() async -> [CatalogWallpaper]? { nil }

    func fetchCatalog() async throws -> [CatalogWallpaper] { [] }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        throw URLError(.fileDoesNotExist)
    }
}
