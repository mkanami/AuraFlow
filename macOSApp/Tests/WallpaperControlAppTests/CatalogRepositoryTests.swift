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

private struct CatalogRepositoryPersistenceTestError: Error, LocalizedError, Sendable {
    let description: String

    var errorDescription: String? {
        description
    }
}

private func repositoryTestDownloadedWallpaper(
    id: String,
    localURL: URL
) -> DownloadedCatalogWallpaper {
    DownloadedCatalogWallpaper(
        id: id,
        wallpaperID: id,
        title: "Test Download",
        category: "Test",
        attribution: "Test",
        previewImageURL: nil,
        localPreviewPath: nil,
        sourcePageURL: nil,
        localPath: localURL.path,
        downloadedAt: Date(timeIntervalSince1970: 1)
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
    #expect(loaded.wallpapers?.map(\.id) == ["unified-cache"])
}

@Test func corruptUnifiedCatalogCacheIsRewrittenFromProviderFallback() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auraflow-unified-cache-recovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let wallpaper = repositoryTestWallpaper(id: "recovered-unified-cache")
    let cacheURL = directory.appendingPathComponent("catalog-cache.json")
    try Data("{corrupt-cache".utf8).write(to: cacheURL, options: .atomic)

    let repository = CatalogRepository(
        provider: CatalogRepositoryTestProvider(cached: [wallpaper]),
        catalogDirectoryURL: directory
    )
    let result = await repository.loadCatalogCache()

    #expect(result.persistenceStatus == .recoveredAndPersisted)
    #expect(result.wallpapers == [wallpaper])
    let repaired = try JSONDecoder().decode(
        [CatalogWallpaper].self,
        from: Data(contentsOf: cacheURL)
    )
    #expect(repaired == [wallpaper])
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

@Test func corruptDownloadedManifestIsRecoveredAndRewritten() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auraflow-catalog-corrupt-manifest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let wallpaperURL = directory.appendingPathComponent("recovered.mp4")
    try Data([1, 2, 3]).write(to: wallpaperURL, options: .atomic)
    let manifestURL = directory.appendingPathComponent("downloaded-catalog.json")
    let corruptData = Data("{not-json".utf8)
    try corruptData.write(to: manifestURL, options: .atomic)

    let repository = CatalogRepository(
        provider: CatalogRepositoryTestProvider(cached: nil),
        catalogDirectoryURL: directory
    )
    let result = repository.loadDownloadedWallpapers(preserving: [])

    #expect(result.persistenceStatus == .recoveredAndPersisted)
    #expect(result.persistenceStatus.didRecover)
    #expect(result.persistenceStatus.didPersist)
    #expect(result.wallpapers.count == 1)
    #expect(result.wallpapers[0].localURL == wallpaperURL.standardizedFileURL)

    let repairedData = try Data(contentsOf: manifestURL)
    let repaired = try JSONDecoder().decode(
        [DownloadedCatalogWallpaper].self,
        from: repairedData
    )
    #expect(repaired.count == 1)
    #expect(repaired[0].localURL == wallpaperURL.standardizedFileURL)
    #expect(repairedData != corruptData)
}

@Test func corruptDownloadedManifestRecoveryWriteFailureIsReported() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auraflow-catalog-corrupt-write-failure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let wallpaperURL = directory.appendingPathComponent("recovered.mp4")
    try Data([4, 5, 6]).write(to: wallpaperURL, options: .atomic)
    let manifestURL = directory.appendingPathComponent("downloaded-catalog.json")
    let corruptData = Data("{still-not-json".utf8)
    try corruptData.write(to: manifestURL, options: .atomic)

    let injectedError = CatalogRepositoryPersistenceTestError(
        description: "read-only catalog directory"
    )
    let repository = CatalogRepository(
        provider: CatalogRepositoryTestProvider(cached: nil),
        catalogDirectoryURL: directory,
        atomicDataWriter: { _, _ in throw injectedError }
    )
    let result = repository.loadDownloadedWallpapers(preserving: [])

    #expect(!result.persistenceStatus.didPersist)
    #expect(result.persistenceStatus.didRecover)
    #expect(result.persistenceStatus.warningMessage?.contains("read-only") == true)
    #expect(result.wallpapers.count == 1)
    #expect(try Data(contentsOf: manifestURL) == corruptData)
}

@Test func readOnlyManifestWriteIsReturnedToTheCaller() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auraflow-catalog-read-only-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let wallpaperURL = directory.appendingPathComponent("wallpaper.mp4")
    try Data([7, 8, 9]).write(to: wallpaperURL, options: .atomic)
    let injectedError = CatalogRepositoryPersistenceTestError(
        description: "read-only catalog directory"
    )
    let repository = CatalogRepository(
        provider: CatalogRepositoryTestProvider(cached: nil),
        catalogDirectoryURL: directory,
        atomicDataWriter: { _, _ in throw injectedError }
    )

    let status = repository.persistDownloadedWallpapers([
        repositoryTestDownloadedWallpaper(id: "read-only", localURL: wallpaperURL)
    ])

    #expect(!status.didPersist)
    #expect(status.warningMessage?.contains("read-only") == true)
    #expect(!FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("downloaded-catalog.json").path
    ))
}

@Test func failedManifestWritePreservesPreviousBytes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auraflow-catalog-failed-write-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let oldWallpaperURL = directory.appendingPathComponent("old.mp4")
    let newWallpaperURL = directory.appendingPathComponent("new.mp4")
    try Data([1]).write(to: oldWallpaperURL, options: .atomic)
    try Data([2]).write(to: newWallpaperURL, options: .atomic)
    let manifestURL = directory.appendingPathComponent("downloaded-catalog.json")
    let oldManifest = try JSONEncoder().encode([
        repositoryTestDownloadedWallpaper(id: "old", localURL: oldWallpaperURL)
    ])
    try oldManifest.write(to: manifestURL, options: .atomic)

    let injectedError = CatalogRepositoryPersistenceTestError(
        description: "simulated disk full"
    )
    let repository = CatalogRepository(
        provider: CatalogRepositoryTestProvider(cached: nil),
        catalogDirectoryURL: directory,
        atomicDataWriter: { _, _ in throw injectedError }
    )
    let status = repository.persistDownloadedWallpapers([
        repositoryTestDownloadedWallpaper(id: "new", localURL: newWallpaperURL)
    ])

    #expect(!status.didPersist)
    #expect(try Data(contentsOf: manifestURL) == oldManifest)
}

@Test func unifiedCatalogWriteFailureIsReturnedWithFreshCatalog() async throws {
    let wallpaper = repositoryTestWallpaper(id: "fresh-catalog")
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("auraflow-unified-cache-write-failure-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let injectedError = CatalogRepositoryPersistenceTestError(
        description: "simulated disk full"
    )
    let repository = CatalogRepository(
        provider: CatalogRepositoryTestProvider(cached: [wallpaper]),
        catalogDirectoryURL: directory,
        atomicDataWriter: { _, _ in throw injectedError }
    )
    let result = try await repository.refreshCatalog(progress: { _ in })

    #expect(result.wallpapers == [wallpaper])
    #expect(!result.persistenceStatus.didPersist)
    #expect(result.persistenceStatus.warningMessage?.contains("disk full") == true)
    #expect(!FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("catalog-cache.json").path
    ))
}
