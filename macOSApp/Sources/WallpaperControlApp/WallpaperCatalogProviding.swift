import Foundation

protocol WallpaperCatalogProviding: Sendable {
    func loadCachedCatalog() async -> [CatalogWallpaper]?
    func fetchCatalog() async throws -> [CatalogWallpaper]
    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper]
    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL
}

struct CatalogPage: Sendable {
    let wallpapers: [CatalogWallpaper]
    let hasMore: Bool
}

/// Optional capability for sources that are too large to download in one
/// refresh. The initial catalog stays fast while subsequent pages are fetched
/// only as the user reaches the end of the loaded cards.
protocol WallpaperCatalogPaging: Sendable {
    func fetchNextCatalogPage() async throws -> CatalogPage
}

/// Optional targeted search for catalogs that are intentionally loaded in
/// pages. This lets search find older entries without downloading every card.
protocol WallpaperCatalogSearching: Sendable {
    func searchCatalog(query: String) async throws -> [CatalogWallpaper]
}

/// Optional provider capability used by the catalog preview pipeline. Preview
/// sources are deliberately separate from full wallpaper downloads so a card
/// can use a small rendition without changing what the user ultimately saves.
protocol WallpaperCatalogPreviewResolving: Sendable {
    func resolvePreviewSources(for wallpaper: CatalogWallpaper) async throws -> [CatalogVideoSource]
}

extension WallpaperCatalogProviding {
    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        let wallpapers = try await fetchCatalog()
        await progress(wallpapers)
        return wallpapers
    }
}
