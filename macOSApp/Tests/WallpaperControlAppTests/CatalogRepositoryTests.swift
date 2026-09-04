import Foundation
import Testing
@testable import WallpaperControlApp

private struct CatalogRepositoryTestProvider: WallpaperCatalogProviding {
    let cached: [CatalogWallpaper]?

    func loadCachedCatalog() async -> [CatalogWallpaper]? {
        cached
    }

    func fetchCatalog() async throws -> [CatalogWallpaper] {
        cached ?? []
    }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        wallpaper.sources.first?.url ?? URL(fileURLWithPath: "/tmp/wallpaper.mp4")
    }
}

private func repositoryTestWallpaper(id: String) -> CatalogWallpaper {
    CatalogWallpaper(
        id: id,
        title: "Test Wallpaper",
        category: "Scenic",
        attribution: "Test",
        previewImageURL: nil,
        sourcePageURL: nil,
        sources: []
    )
}

@Test func catalogRepositoryPrefersItsUnifiedCache() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auraflow-catalog-repository-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let cachedWallpaper = repositoryTestWallpaper(id: "unified-cache")
    let data = try JSONEncoder().encode([cachedWallpaper])
    try data.write(
        to: directory.appendingPathComponent("catalog-cache.json"),
        options: .atomic
    )

    let provider = CatalogRepositoryTestProvider(
        cached: [repositoryTestWallpaper(id: "provider-cache")]
    )
    let repository = CatalogRepository(
        provider: provider,
        catalogDirectoryURL: directory
    )

    let loaded = await repository.loadCatalogCache()
    #expect(loaded?.map(\.id) == ["unified-cache"])
}

@Test func catalogRepositoryRegistersAndReusesDownloadedWallpaper() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auraflow-catalog-registration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let localURL = directory.appendingPathComponent("wallpaper.mp4")
    try Data([1, 2, 3]).write(to: localURL, options: .atomic)
    let wallpaper = repositoryTestWallpaper(id: "downloaded-wallpaper")
    let repository = CatalogRepository(
        provider: CatalogRepositoryTestProvider(cached: nil),
        catalogDirectoryURL: directory
    )

    let result = repository.registerDownloadedWallpaper(
        wallpaper,
        localURL: localURL,
        existing: []
    )

    #expect(result.wallpapers.count == 1)
    #expect(result.wallpapers[0].localURL == localURL.standardizedFileURL)
    #expect(repository.reusableDownloadedWallpaperURL(
        for: wallpaper.id,
        in: result.wallpapers
    ) == localURL.standardizedFileURL)
    #expect(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("downloaded-catalog.json").path
    ))
}
