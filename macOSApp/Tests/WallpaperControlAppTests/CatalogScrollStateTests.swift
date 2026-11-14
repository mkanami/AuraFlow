import Combine
import Foundation
import Testing
@testable import WallpaperControlApp

@Test @MainActor func catalogScrollingIndexTracksPagingFiltersSearchAndAudioChanges() {
    let model = CatalogViewModel()
    let items = (0..<40).map { scrollStateCard($0) }
    model.replaceCatalogForDisplay(with: items, hasMoreRemotePages: false)
    #expect(model.filteredWallpapers.count == 12)
    #expect(model.musicCount == 20)
    #expect(model.count(in: .anime) == 6)
    #expect(model.loadNextDeferredPage())
    #expect(model.filteredWallpapers.count == 24)
    #expect(model.count(in: .anime) == 12)
    model.toggleMusic()
    #expect(model.filteredWallpapers.count == 20)
    model.audioStatus["scroll-state-0"] = false
    #expect(model.musicCount == 19)
    #expect(!model.filteredWallpapers.contains { $0.id == "scroll-state-0" })
    model.audioStatus.removeValue(forKey: "scroll-state-0")
    #expect(model.musicCount == 20)
    #expect(model.filteredWallpapers.count == 20)
    model.toggleGroup(.scenic)
    #expect(model.filteredWallpapers.allSatisfy { $0.catalogGroup == .scenic })
    model.searchText = "new scene"
    #expect(model.filteredWallpapers.isEmpty)
    model.appendSearchResults([scrollStateCard(1001, title: "New scene")])
    #expect(model.filteredWallpapers.map(\.id) == ["scroll-state-1001"])
    model.searchResults.removeAll()
    #expect(model.filteredWallpapers.isEmpty)
    model.searchText = ""
    model.selectedGroup = nil
    model.setWallpapersDirectly([scrollStateCard(99)])
    #expect(model.musicCount == 0)
    #expect(model.filteredWallpapers.map(\.id) == ["scroll-state-99"])
    #expect(model.count(in: .scenic) == 1)
    model.wallpapers.append(scrollStateCard(100))
    #expect(model.musicCount == 1)
    #expect(model.filteredWallpapers.count == 2)
}

@Test @MainActor func catalogScrollingRepeatedAudioInspectionDoesNotRepublishKnownMusic() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = CatalogAudioMetadata(provider: ScrollAudioOfflineProvider(),
        coordinator: CatalogTransferCoordinator(), cacheURL: root.appendingPathComponent("audio.json"))
    var publications = 0
    let subscription = metadata.$audio.dropFirst().sink { _ in publications += 1 }
    defer { subscription.cancel() }
    let item = scrollStateCard(0)
    for _ in 0..<30 { await metadata.inspect(item) }
    #expect(metadata.audio[item.id] == true)
    #expect(publications == 1)
}

@Test func catalogScrollingDecisionCacheDoesNotApproveChangedArtworkMetadata() {
    let clean = scrollStateCard(123)
    for _ in 0..<20 { #expect(CatalogContentPolicy.allows(clean)) }
    let branded = CatalogWallpaper(id: clean.id, title: "HDsoundi", category: clean.category,
        attribution: clean.attribution, previewImageURL: clean.previewImageURL,
        sourcePageURL: clean.sourcePageURL, sources: [])
    #expect(!CatalogContentPolicy.allows(branded))
    let replacedPoster = CatalogWallpaper(id: clean.id, title: clean.title, category: clean.category,
        attribution: clean.attribution, previewImageURL: URL(string: "https://www.desktophut.com/images/1720775444.webp"),
        sourcePageURL: clean.sourcePageURL, sources: [])
    #expect(!CatalogContentPolicy.allows(replacedPoster))
    #expect(CatalogContentPolicy.allows(clean))
}

private func scrollStateCard(_ index: Int, title: String? = nil) -> CatalogWallpaper {
    var item = CatalogWallpaper(id: "scroll-state-\(index)", title: title ?? "Wallpaper \(index)",
        category: index % 2 == 0 ? "Anime" : "Scenic", attribution: "Test",
        previewImageURL: nil, sourcePageURL: nil, sources: [])
    item.hasMusic = index % 2 == 0 ? true : nil
    return item
}

private struct ScrollAudioOfflineProvider: WallpaperCatalogProviding {
    func loadCachedCatalog() async -> [CatalogWallpaper]? { nil }
    func fetchCatalog() async throws -> [CatalogWallpaper] { [] }
    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL { throw URLError(.notConnectedToInternet) }
}
