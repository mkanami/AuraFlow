import Foundation

protocol CatalogCacheClearing {
    func clearCache() async
}

actor ManagedWallpaperCatalogProvider: WallpaperCatalogProviding, CatalogCacheClearing {
    private let animeProvider: WallpaperCatalogProviding
    private let scenicProvider: WallpaperCatalogProviding
    private let curatedCatalog: [CatalogWallpaper]

    init(
        animeProvider: WallpaperCatalogProviding = MoeWallsSource(),
        scenicProvider: WallpaperCatalogProviding = DarefulSource(),
        curatedCatalog: [CatalogWallpaper] = CatalogWallpaper.defaultCatalog
    ) {
        self.animeProvider = animeProvider
        self.scenicProvider = scenicProvider
        self.curatedCatalog = curatedCatalog
    }

    func loadCachedCatalog() async -> [CatalogWallpaper]? {
        let cachedAnime = await animeProvider.loadCachedCatalog() ?? []
        let cachedScenic = await scenicProvider.loadCachedCatalog() ?? []
        let merged = Self.mergeCatalogs(curated: curatedCatalog, catalogs: [cachedAnime, cachedScenic])
        return merged.isEmpty ? nil : merged
    }

    func fetchCatalog() async throws -> [CatalogWallpaper] {
        var firstError: Error?

        let animeCatalog: [CatalogWallpaper]
        do {
            animeCatalog = try await animeProvider.fetchCatalog()
        } catch {
            firstError = error
            animeCatalog = await animeProvider.loadCachedCatalog() ?? []
        }

        let scenicCatalog: [CatalogWallpaper]
        do {
            scenicCatalog = try await scenicProvider.fetchCatalog()
        } catch {
            firstError = firstError ?? error
            scenicCatalog = await scenicProvider.loadCachedCatalog() ?? []
        }

        let merged = Self.mergeCatalogs(curated: curatedCatalog, catalogs: [animeCatalog, scenicCatalog])
        if !merged.isEmpty {
            return merged
        }
        throw firstError ?? MoeWallsSourceError.unavailable("Wallpaper catalog is unavailable.")
    }

    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        let curatedCatalog = curatedCatalog
        var firstError: Error?
        var scenicCatalog = await scenicProvider.loadCachedCatalog() ?? []
        if !scenicCatalog.isEmpty {
            await progress(Self.mergeCatalogs(curated: curatedCatalog, catalogs: [scenicCatalog]))
        }

        let animeCatalog: [CatalogWallpaper]
        do {
            let cachedScenicForAnimeProgress = scenicCatalog
            animeCatalog = try await animeProvider.fetchCatalog { partial in
                let merged = Self.mergeCatalogs(curated: curatedCatalog, catalogs: [partial, cachedScenicForAnimeProgress])
                if !merged.isEmpty {
                    await progress(merged)
                }
            }
        } catch {
            firstError = error
            animeCatalog = await animeProvider.loadCachedCatalog() ?? []
        }

        let partialMerged = Self.mergeCatalogs(curated: curatedCatalog, catalogs: [animeCatalog, scenicCatalog])
        if !partialMerged.isEmpty {
            await progress(partialMerged)
        }

        do {
            scenicCatalog = try await scenicProvider.fetchCatalog { partial in
                let merged = Self.mergeCatalogs(curated: curatedCatalog, catalogs: [animeCatalog, partial])
                if !merged.isEmpty {
                    await progress(merged)
                }
            }
        } catch {
            firstError = firstError ?? error
            scenicCatalog = await scenicProvider.loadCachedCatalog() ?? scenicCatalog
        }

        let merged = Self.mergeCatalogs(curated: curatedCatalog, catalogs: [animeCatalog, scenicCatalog])
        if !merged.isEmpty {
            return merged
        }
        throw firstError ?? MoeWallsSourceError.unavailable("Wallpaper catalog is unavailable.")
    }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        if let source = wallpaper.sources.first {
            return source.url
        }
        if wallpaper.catalogGroup == .scenic {
            return try await scenicProvider.resolveDownloadURL(for: wallpaper)
        }
        return try await animeProvider.resolveDownloadURL(for: wallpaper)
    }

    func clearCache() async {
        if let cacheClearingProvider = animeProvider as? CatalogCacheClearing {
            await cacheClearingProvider.clearCache()
        }
        if let cacheClearingProvider = scenicProvider as? CatalogCacheClearing {
            await cacheClearingProvider.clearCache()
        }
    }

    private static func mergeCatalogs(
        curated: [CatalogWallpaper],
        catalogs: [[CatalogWallpaper]]
    ) -> [CatalogWallpaper] {
        var seen = Set<String>()
        var merged: [CatalogWallpaper] = []
        let allCatalogs = [curated] + catalogs
        let maxCount = allCatalogs.map(\.count).max() ?? 0

        for index in 0..<maxCount {
            for catalog in allCatalogs where index < catalog.count {
                let wallpaper = catalog[index]
                if seen.insert(wallpaper.id).inserted {
                    merged.append(wallpaper)
                }
            }
        }

        return merged
    }
}

extension MoeWallsSource: CatalogCacheClearing {}
