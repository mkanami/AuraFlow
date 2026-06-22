import Foundation

protocol CatalogCacheClearing: Sendable {
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
        let cachedAnime = await animeProvider.loadCachedCatalog() ?? []
        let cachedScenic = await scenicProvider.loadCachedCatalog() ?? []
        async let animeResult = Self.fetchProviderCatalog(provider: animeProvider, cached: cachedAnime)
        async let scenicResult = Self.fetchProviderCatalog(provider: scenicProvider, cached: cachedScenic)
        let (animeCatalog, scenicCatalog) = await (animeResult, scenicResult)

        let merged = Self.mergeCatalogs(
            curated: curatedCatalog,
            catalogs: [animeCatalog.wallpapers, scenicCatalog.wallpapers]
        )
        if !merged.isEmpty {
            return merged
        }
        throw MoeWallsSourceError.unavailable(
            animeCatalog.failureMessage ??
                scenicCatalog.failureMessage ??
                "Wallpaper catalog is unavailable."
        )
    }

    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        let curatedCatalog = curatedCatalog
        let cachedAnime = await animeProvider.loadCachedCatalog() ?? []
        let cachedScenic = await scenicProvider.loadCachedCatalog() ?? []
        let progressState = CatalogProgressState(curated: curatedCatalog, progress: progress)
        await progressState.prime(anime: cachedAnime, scenic: cachedScenic)

        async let animeResult = Self.fetchProviderCatalog(
            provider: animeProvider,
            cached: cachedAnime,
            progress: { partial in
                await progressState.replaceAnime(partial)
            }
        )
        async let scenicResult = Self.fetchProviderCatalog(
            provider: scenicProvider,
            cached: cachedScenic,
            progress: { partial in
                await progressState.replaceScenic(partial)
            }
        )

        let (animeCatalog, scenicCatalog) = await (animeResult, scenicResult)
        let merged = await progressState.finish(
            anime: animeCatalog.wallpapers,
            scenic: scenicCatalog.wallpapers
        )
        if !merged.isEmpty {
            return merged
        }
        throw MoeWallsSourceError.unavailable(
            animeCatalog.failureMessage ??
                scenicCatalog.failureMessage ??
                "Wallpaper catalog is unavailable."
        )
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

    fileprivate static func mergeCatalogs(
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

    private static func fetchProviderCatalog(
        provider: WallpaperCatalogProviding,
        cached: [CatalogWallpaper],
        progress: (@Sendable ([CatalogWallpaper]) async -> Void)? = nil
    ) async -> ProviderCatalogFetchResult {
        do {
            let wallpapers: [CatalogWallpaper]
            if let progress {
                wallpapers = try await provider.fetchCatalog(progress: progress)
            } else {
                wallpapers = try await provider.fetchCatalog()
            }
            return ProviderCatalogFetchResult(wallpapers: wallpapers, failureMessage: nil)
        } catch {
            return ProviderCatalogFetchResult(
                wallpapers: cached,
                failureMessage: error.localizedDescription
            )
        }
    }
}

extension MoeWallsSource: CatalogCacheClearing {}

private struct ProviderCatalogFetchResult: Sendable {
    let wallpapers: [CatalogWallpaper]
    let failureMessage: String?
}

private actor CatalogProgressState {
    private let curated: [CatalogWallpaper]
    private let progress: @Sendable ([CatalogWallpaper]) async -> Void
    private var anime: [CatalogWallpaper] = []
    private var scenic: [CatalogWallpaper] = []
    private var lastEmittedIDs: [String] = []

    init(
        curated: [CatalogWallpaper],
        progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void
    ) {
        self.curated = curated
        self.progress = progress
    }

    func prime(anime: [CatalogWallpaper], scenic: [CatalogWallpaper]) async {
        self.anime = anime
        self.scenic = scenic
        await emitIfNeeded()
    }

    func replaceAnime(_ wallpapers: [CatalogWallpaper]) async {
        anime = wallpapers
        await emitIfNeeded()
    }

    func replaceScenic(_ wallpapers: [CatalogWallpaper]) async {
        scenic = wallpapers
        await emitIfNeeded()
    }

    func finish(anime: [CatalogWallpaper], scenic: [CatalogWallpaper]) async -> [CatalogWallpaper] {
        self.anime = anime
        self.scenic = scenic
        let merged = ManagedWallpaperCatalogProvider.mergeCatalogs(
            curated: curated,
            catalogs: [anime, scenic]
        )
        await emitIfNeeded(merged)
        return merged
    }

    private func emitIfNeeded(_ merged: [CatalogWallpaper]? = nil) async {
        let merged = merged ?? ManagedWallpaperCatalogProvider.mergeCatalogs(
            curated: curated,
            catalogs: [anime, scenic]
        )
        guard !merged.isEmpty else { return }

        let emittedIDs = merged.map(\.id)
        guard emittedIDs != lastEmittedIDs else { return }
        lastEmittedIDs = emittedIDs
        await progress(merged)
    }
}
