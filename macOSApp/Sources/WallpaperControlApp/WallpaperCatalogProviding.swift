import Foundation

protocol WallpaperCatalogProviding: Sendable {
    func loadCachedCatalog() async -> [CatalogWallpaper]?
    func fetchCatalog() async throws -> [CatalogWallpaper]
    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper]
    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL
}

extension WallpaperCatalogProviding {
    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        let wallpapers = try await fetchCatalog()
        await progress(wallpapers)
        return wallpapers
    }
}
