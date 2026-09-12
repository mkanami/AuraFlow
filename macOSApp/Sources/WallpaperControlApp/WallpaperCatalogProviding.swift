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

extension WallpaperCatalogProviding {
    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        let wallpapers = try await fetchCatalog()
        await progress(wallpapers)
        return wallpapers
    }
}
