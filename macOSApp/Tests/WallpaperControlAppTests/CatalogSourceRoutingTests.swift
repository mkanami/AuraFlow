import Foundation
import Testing
@testable import WallpaperControlApp

@Test func catalogSourceRoutingKeepsMusicSceneryWithItsOriginalSite() async throws {
    let anime = CatalogRouteRecorder(), nature = CatalogRouteRecorder(), scenic = CatalogRouteRecorder()
    let provider = ManagedWallpaperCatalogProvider(animeProvider: anime, animeNatureProvider: nature,
        scenicProvider: scenic, musicProvider: CatalogRouteRecorder(), curatedCatalog: [])
    for (host, category) in [("www.desktophut.com", "Nature"), ("livewallpapers4free.com", "Anime Nature")] {
        let item = CatalogWallpaper(id: "music-scenery", title: "Rainy Forest", category: category,
            attribution: "Source", previewImageURL: nil, sourcePageURL: URL(string: "https://\(host)/rainy-forest/"), sources: [])
        _ = try await provider.resolveDownloadURL(for: item)
        _ = try await provider.resolvePreviewSources(for: item)
        let media = try await provider.resolveMedia(for: item)
        await provider.invalidateResolvedMedia(for: item)
        _ = try await provider.enrichMediaMetadata(for: item, media: media)
    }
    #expect(await anime.actions == ["download", "media", "media", "invalidate", "enrich",
                                   "download", "media", "media", "invalidate", "enrich"])
    #expect(await nature.actions.isEmpty)
    #expect(await scenic.actions.isEmpty)

    for (host, category) in [("motionbgs.com", "Anime Nature"), ("dareful.com", "Nature")] {
        let item = CatalogWallpaper(id: host, title: "Forest", category: category, attribution: "Source",
            previewImageURL: nil, sourcePageURL: URL(string: "https://\(host)/forest/"), sources: [])
        _ = try await provider.resolveMedia(for: item)
    }
    #expect(await nature.actions == ["media"])
    #expect(await scenic.actions == ["media"])

}

private actor CatalogRouteRecorder: WallpaperCatalogProviding, WallpaperCatalogMediaResolving, WallpaperCatalogMediaMetadataEnriching {
    var actions: [String] = []
    func loadCachedCatalog() async -> [CatalogWallpaper]? { nil }
    func fetchCatalog() async throws -> [CatalogWallpaper] { [] }
    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        actions.append("download")
        return URL(string: "https://media.desktophut.com/files/forest.mp4")!
    }
    func resolveMedia(for wallpaper: CatalogWallpaper) async throws -> CatalogResolvedMedia {
        actions.append("media")
        return CatalogResolvedMedia(previewSources: [], originalSources: [], provider: "Fixture", validUntil: .distantFuture)
    }
    func invalidateResolvedMedia(for wallpaper: CatalogWallpaper) async { actions.append("invalidate") }
    func enrichMediaMetadata(for wallpaper: CatalogWallpaper, media: CatalogResolvedMedia) async throws -> CatalogResolvedMedia {
        actions.append("enrich")
        return media
    }
}
