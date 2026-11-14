import Foundation
import Testing
@testable import WallpaperControlApp

@Test func catalogContentPolicyRejectsChannelCoversAndEncodedBranding() {
    for title in ["HDsoundi", "HD Soundi Music", "Where words fail music speaks", "♬ Live Wallpaper Long Grass", "♫-Live-Wallpaper Cover", "Watermarked landscape"] {
        #expect(!CatalogContentPolicy.allows(policyCard("candidate", title: title)))
    }
    #expect(!CatalogContentPolicy.allows(policyCard("source-%E2%99%AC-Live-Wallpaper-new-title")))
    for title in ["Rainy forest", "Without watermark", "Watermark-free landscape", "No watermark", "HD Sound Forest"] {
        #expect(CatalogContentPolicy.allows(policyCard("clean", title: title)))
    }
}

@Test func catalogContentPolicyKeepsReviewedExclusionsAcrossRenamedAliases() {
    let id = "desktophut-cat-lofi-cute"
    let page = URL(string: "https://www.desktophut.com/cat-lofi-cute/?utm_source=search#preview")!
    let poster = URL(string: "https://www.desktophut.com/images/1720775444.webp?size=large")!
    #expect(!CatalogContentPolicy.allows(policyCard(id)))
    #expect(!CatalogContentPolicy.allows(policyCard("new-id", page: page)))
    #expect(!CatalogContentPolicy.allows(policyCard("another-id", poster: poster)))
    #expect(!CatalogContentPolicy.allows(policyCard("moewalls-sadako-the-ring-live-wallpaper")))
    #expect(CatalogContentPolicy.allows(policyCard("new-id", page: URL(string: "https://www.desktophut.com/clean-forest"))))
}

@Test func catalogContentPolicyPrunesAndPersistsOldUnifiedCache() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let good = policyCard("clean"), bad = policyCard("desktophut-cat-lofi-cute")
    let cache = root.appendingPathComponent("catalog-cache.json")
    try JSONEncoder().encode([bad, good]).write(to: cache)
    let source = PolicyFixtureSource(items: [bad, good])
    let repository = CatalogRepository(provider: source, catalogDirectoryURL: root)
    #expect(await repository.loadCatalogCache().wallpapers == [good])
    #expect(try JSONDecoder().decode([CatalogWallpaper].self, from: Data(contentsOf: cache)) == [good])
    #expect(try await repository.refreshCatalog(progress: { _ in }).wallpapers == [good])
    #expect(try await repository.loadNextCatalogPage(existing: [bad, good]).wallpapers == [good])
    #expect(try await repository.searchCatalog(query: "Wallpaper", existing: [bad]).wallpapers == [good])
}

@Test func catalogContentPolicyFiltersProviderCacheRefreshSearchAndBothPagingRoutes() async throws {
    let good = policyCard("clean"), bad = policyCard("desktophut-cat-lofi-cute")
    let source = PolicyFixtureSource(items: [bad, good])
    let empty = PolicyFixtureSource(items: [])
    let provider = ManagedWallpaperCatalogProvider(animeProvider: source, animeNatureProvider: empty,
        scenicProvider: empty, musicProvider: source, curatedCatalog: [bad])
    #expect(await provider.loadCachedCatalog() == [good])
    #expect(try await provider.fetchCatalog() == [good])
    #expect(try await provider.searchCatalog(query: "Wallpaper") == [good])
    #expect(try await provider.fetchNextCatalogPage().wallpapers == [good])
    #expect(try await provider.fetchNextMusicCatalogPage().wallpapers == [good])
    await #expect(throws: (any Error).self) { try await provider.resolveMedia(for: bad) }
    await #expect(throws: (any Error).self) { try await provider.resolveDownloadURL(for: bad) }
    #expect(await source.resolutions == 0)
}

@Test @MainActor func catalogContentPolicyHidesDownloadedCardsWithoutDeletingPersonalFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("user-video.mp4")
    try Data("personal media".utf8).write(to: file)
    let source = PolicyFixtureSource(items: [])
    let repository = CatalogRepository(provider: source, catalogDirectoryURL: root)
    let result = repository.registerDownloadedWallpaper(policyCard("desktophut-cat-lofi-cute"), localURL: file, existing: [])
    let model = CatalogViewModel()
    model.downloadedWallpapers = result.wallpapers
    #expect(model.visibleDownloadedWallpapers.isEmpty)
    #expect(model.downloadedWallpapers.count == 1)
    #expect(repository.loadDownloadedWallpapers(preserving: []).wallpapers.count == 1)
    #expect(try Data(contentsOf: file) == Data("personal media".utf8))
    model.replaceCatalogForDisplay(with: [policyCard("desktophut-cat-lofi-cute"), policyCard("clean")], hasMoreRemotePages: true)
    #expect(model.filteredWallpapers.map(\.id) == ["clean"])
    model.appendSearchResults([policyCard("desktophut-cat-lofi-cute")])
    #expect(model.searchResults.isEmpty)
}

@Test func musicCatalogCuratedModeDoesNotFetchUnreviewedDiscoveryOrTrustOldCache() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let reviewed = (0..<3).map { policyCard("reviewed-\($0)") }
    var unreviewed = policyCard("unreviewed"); unreviewed.hasMusic = true
    var approved = reviewed[0]; approved.hasMusic = true
    let changedPoster = policyCard(reviewed[1].id, poster: URL(string: "https://www.desktophut.com/other.jpg"))
    try JSONEncoder().encode([unreviewed, approved, changedPoster]).write(to: root.appendingPathComponent("catalog.json"))
    let backend = PolicyFixtureSource(items: [unreviewed])
    let provider = MusicWallpaperCatalogProvider(entries: [.init(site: .desktophut,
        provider: backend, seeds: reviewed, curatedOnly: true)], directory: root,
        batchSize: 2, verifyAudio: { _, _ in .audible })
    #expect(await provider.loadCachedCatalog() == [approved])
    let first = try await provider.fetchCatalog()
    #expect(first.count == 3)
    #expect(first.allSatisfy { $0.id.hasPrefix("reviewed-") && $0.hasMusic == true })
    let end = try await provider.fetchNextCatalogPage()
    #expect(!end.hasMore)
    #expect(try await provider.searchCatalog(query: "unreviewed").isEmpty)
    #expect(await backend.discoveryRequests == 0)
    await #expect(throws: (any Error).self) { try await provider.resolveDownloadURL(for: unreviewed) }
}

private func policyCard(_ id: String, title: String = "Wallpaper", page: URL? = nil, poster: URL? = nil) -> CatalogWallpaper {
    CatalogWallpaper(id: id, title: title, category: "Anime", attribution: "DesktopHut",
        previewImageURL: poster, sourcePageURL: page ?? URL(string: "https://www.desktophut.com/\(id)"), sources: [])
}

private actor PolicyFixtureSource: WallpaperCatalogProviding, WallpaperCatalogPaging, WallpaperCatalogSearching {
    let items: [CatalogWallpaper]
    var discoveryRequests = 0
    var resolutions = 0
    init(items: [CatalogWallpaper]) { self.items = items }
    func loadCachedCatalog() async -> [CatalogWallpaper]? { items }
    func fetchCatalog() async throws -> [CatalogWallpaper] { discoveryRequests += 1; return items }
    func searchCatalog(query: String) async throws -> [CatalogWallpaper] { discoveryRequests += 1; return items }
    func fetchNextCatalogPage() async throws -> CatalogPage {
        discoveryRequests += 1; return CatalogPage(wallpapers: items, hasMore: false)
    }
    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        resolutions += 1
        return URL(string: "https://www.desktophut.com/files/\(wallpaper.id).mp4")!
    }
}
