import Foundation
import Testing
@testable import WallpaperControlApp

@Test func catalogDownloadUsesOnlyResolvedOriginalRoutes() async throws {
    let catalogDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowOriginalRoute-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: catalogDirectory) }
    let recorder = CatalogDownloadRequestRecorder()
    let wallpaper = CatalogWallpaper(
        id: "resolved-original",
        title: "Resolved Original",
        category: "Anime Nature",
        attribution: "MotionBGS",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://motionbgs.test/card")!,
        sources: [CatalogVideoSource(url: URL(string: "https://media.test/preview.mp4")!, width: 960, height: 540)]
    )
    let original = CatalogVideoSource(
        url: URL(string: "https://media.test/original.mp4")!,
        width: 3840,
        height: 2160
    )
    let service = CatalogDownloadService(
        provider: FailingCatalogDownloadProvider(),
        catalogDirectoryURL: catalogDirectory,
        fileDownloader: { request, session in
            await recorder.record(
                url: request.url,
                sessionIdentity: ObjectIdentifier(session)
            )
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("AuraFlowOriginal-\(UUID().uuidString).mp4")
            try Data("original media".utf8).write(to: temporaryURL)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/2",
                headerFields: ["Content-Type": "video/mp4"]
            )!
            return (temporaryURL, response)
        }
    )

    let downloadedURL = try await service.download(
        wallpaper,
        preferredSources: [original]
    )

    #expect(await recorder.urls == [original.url])
    #expect(
        downloadedURL.deletingLastPathComponent().lastPathComponent
            == "Downloaded Wallpapers"
    )
}

@Test func catalogDownloadReusesItsURLSessionAcrossTransfers() async throws {
    let catalogDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowSessionReuse-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: catalogDirectory) }
    let recorder = CatalogDownloadRequestRecorder()
    let service = CatalogDownloadService(
        provider: FailingCatalogDownloadProvider(),
        catalogDirectoryURL: catalogDirectory,
        fileDownloader: { request, session in
            await recorder.record(
                url: request.url,
                sessionIdentity: ObjectIdentifier(session)
            )
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("AuraFlowSession-\(UUID().uuidString).mp4")
            try Data("media".utf8).write(to: temporaryURL)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/2",
                headerFields: ["Content-Type": "video/mp4"]
            )!
            return (temporaryURL, response)
        }
    )

    for id in ["one", "two"] {
        let wallpaper = CatalogWallpaper(
            id: id, title: id, category: "Scenic", attribution: "Test",
            previewImageURL: nil, sourcePageURL: nil, sources: []
        )
        let source = CatalogVideoSource(
            url: URL(string: "https://media.test/\(id).mp4")!, width: 3840, height: 2160
        )
        _ = try await service.download(wallpaper, preferredSources: [source])
    }

    #expect(await recorder.sessionIdentityCount == 1)
}

@Test func catalogDownloadSurfacesAnyStaleResolvedRouteBeforeProviderFallback() async throws {
    let catalogDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlowStaleRoute-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: catalogDirectory) }
    let staleURL = URL(string: "https://media.test/stale.mp4")!
    let unavailableURL = URL(string: "https://media.test/unavailable.mp4")!
    let wallpaper = CatalogWallpaper(
        id: "stale-route", title: "Stale Route", category: "Scenic", attribution: "Dareful",
        previewImageURL: nil, sourcePageURL: URL(string: "https://dareful.test/card"), sources: []
    )
    let service = CatalogDownloadService(
        provider: FailingCatalogDownloadProvider(),
        catalogDirectoryURL: catalogDirectory,
        fileDownloader: { request, _ in
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("AuraFlowStale-\(UUID().uuidString).mp4")
            try Data("response".utf8).write(to: temporaryURL)
            let statusCode = request.url == staleURL ? 404 : 500
            let response = HTTPURLResponse(
                url: request.url!, statusCode: statusCode, httpVersion: "HTTP/2",
                headerFields: ["Content-Type": "video/mp4"]
            )!
            return (temporaryURL, response)
        }
    )

    do {
        _ = try await service.download(
            wallpaper,
            preferredSources: [
                CatalogVideoSource(url: staleURL, width: 3840, height: 2160),
                CatalogVideoSource(url: unavailableURL, width: 3840, height: 2160),
            ],
            allowProviderFallbackAfterStaleRoute: false
        )
        Issue.record("Expected the stale route to be surfaced")
    } catch let CatalogDownloadError.badStatus(url, statusCode) {
        #expect(url == staleURL)
        #expect(statusCode == 404)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

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

private actor CatalogDownloadRequestRecorder {
    private(set) var urls: [URL] = []
    private var sessionIdentities = Set<ObjectIdentifier>()

    var sessionIdentityCount: Int { sessionIdentities.count }

    func record(url: URL?, sessionIdentity: ObjectIdentifier) {
        if let url { urls.append(url) }
        sessionIdentities.insert(sessionIdentity)
    }
}
