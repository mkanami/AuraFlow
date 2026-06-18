import Foundation

protocol CatalogCacheClearing {
    func clearCache() async
}

actor ManagedWallpaperCatalogProvider: WallpaperCatalogProviding, CatalogCacheClearing {
    private let liveProvider: WallpaperCatalogProviding
    private let curatedCatalog: [CatalogWallpaper]

    init(
        liveProvider: WallpaperCatalogProviding = MoeWallsSource(),
        curatedCatalog: [CatalogWallpaper] = CatalogWallpaper.defaultCatalog
    ) {
        self.liveProvider = liveProvider
        self.curatedCatalog = curatedCatalog
    }

    func loadCachedCatalog() async -> [CatalogWallpaper]? {
        let cached = await liveProvider.loadCachedCatalog() ?? []
        let merged = Self.mergeCatalogs(curated: curatedCatalog, live: cached)
        return merged.isEmpty ? nil : merged
    }

    func fetchCatalog() async throws -> [CatalogWallpaper] {
        do {
            let liveCatalog = try await liveProvider.fetchCatalog()
            return Self.mergeCatalogs(curated: curatedCatalog, live: liveCatalog)
        } catch {
            if let cached = await liveProvider.loadCachedCatalog(), !cached.isEmpty {
                return Self.mergeCatalogs(curated: curatedCatalog, live: cached)
            }
            if !curatedCatalog.isEmpty {
                return curatedCatalog
            }
            throw error
        }
    }

    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        let curatedCatalog = curatedCatalog
        do {
            let liveCatalog = try await liveProvider.fetchCatalog { partial in
                let merged = Self.mergeCatalogs(curated: curatedCatalog, live: partial)
                if !merged.isEmpty {
                    await progress(merged)
                }
            }
            return Self.mergeCatalogs(curated: curatedCatalog, live: liveCatalog)
        } catch {
            if let cached = await liveProvider.loadCachedCatalog(), !cached.isEmpty {
                let merged = Self.mergeCatalogs(curated: curatedCatalog, live: cached)
                await progress(merged)
                return merged
            }
            if !curatedCatalog.isEmpty {
                await progress(curatedCatalog)
                return curatedCatalog
            }
            throw error
        }
    }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        if let source = wallpaper.sources.first {
            return source.url
        }
        return try await liveProvider.resolveDownloadURL(for: wallpaper)
    }

    func clearCache() async {
        if let cacheClearingProvider = liveProvider as? CatalogCacheClearing {
            await cacheClearingProvider.clearCache()
        }
    }

    private static func mergeCatalogs(
        curated: [CatalogWallpaper],
        live: [CatalogWallpaper]
    ) -> [CatalogWallpaper] {
        var seen = Set<String>()
        var merged: [CatalogWallpaper] = []
        let maxCount = max(curated.count, live.count)

        for index in 0..<maxCount {
            if index < curated.count, seen.insert(curated[index].id).inserted {
                merged.append(curated[index])
            }
            if index < live.count, seen.insert(live[index].id).inserted {
                merged.append(live[index])
            }
        }

        return merged
    }
}

extension MoeWallsSource: CatalogCacheClearing {}
