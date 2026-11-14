import Foundation

protocol CatalogCacheClearing: Sendable {
    func clearCache() async
}

actor ManagedWallpaperCatalogProvider: WallpaperCatalogProviding, CatalogCacheClearing, WallpaperCatalogPaging, WallpaperCatalogMusicPaging, WallpaperCatalogSearching, WallpaperCatalogPreviewResolving, WallpaperCatalogMediaResolving, WallpaperCatalogMediaMetadataEnriching {
    private let animeProvider: WallpaperCatalogProviding
    private let animeNatureProvider: WallpaperCatalogProviding
    private let scenicProvider: WallpaperCatalogProviding
    private let musicProvider: WallpaperCatalogProviding
    private let curatedCatalog: [CatalogWallpaper]

    init(
        animeProvider: WallpaperCatalogProviding = AnimeWallpaperCatalogProvider(),
        animeNatureProvider: WallpaperCatalogProviding = MotionBGSAnimeNatureSource(),
        scenicProvider: WallpaperCatalogProviding = DarefulSource(),
        musicProvider: WallpaperCatalogProviding = MusicWallpaperCatalogProvider(),
        curatedCatalog: [CatalogWallpaper] = CatalogWallpaper.defaultCatalog
    ) {
        self.animeProvider = animeProvider
        self.animeNatureProvider = animeNatureProvider
        self.scenicProvider = scenicProvider
        self.musicProvider = musicProvider
        self.curatedCatalog = curatedCatalog
    }

    func loadCachedCatalog() async -> [CatalogWallpaper]? {
        let cachedAnime = await animeProvider.loadCachedCatalog() ?? []
        let cachedAnimeNature = await animeNatureProvider.loadCachedCatalog() ?? []
        let cachedScenic = await scenicProvider.loadCachedCatalog() ?? []
        let cachedMusic = await musicProvider.loadCachedCatalog() ?? []
        let merged = Self.mergeCatalogs(curated: curatedCatalog, catalogs: [cachedAnime, cachedAnimeNature, cachedScenic, cachedMusic])
        return merged.isEmpty ? nil : merged
    }

    func fetchCatalog() async throws -> [CatalogWallpaper] {
        let cachedAnime = await animeProvider.loadCachedCatalog() ?? []
        let cachedAnimeNature = await animeNatureProvider.loadCachedCatalog() ?? []
        let cachedScenic = await scenicProvider.loadCachedCatalog() ?? []
        async let animeResult = Self.fetchProviderCatalog(provider: animeProvider, cached: cachedAnime)
        async let animeNatureResult = Self.fetchProviderCatalog(provider: animeNatureProvider, cached: cachedAnimeNature)
        async let scenicResult = Self.fetchProviderCatalog(provider: scenicProvider, cached: cachedScenic)
        async let musicResult = Self.fetchProviderCatalog(provider: musicProvider, cached: await musicProvider.loadCachedCatalog() ?? [])
        let (animeCatalog, animeNatureCatalog, scenicCatalog, musicCatalog) = await (animeResult, animeNatureResult, scenicResult, musicResult)

        let merged = Self.mergeCatalogs(
            curated: curatedCatalog,
            catalogs: [animeCatalog.wallpapers, animeNatureCatalog.wallpapers, scenicCatalog.wallpapers, musicCatalog.wallpapers]
        )
        if !merged.isEmpty {
            return merged
        }
        throw MoeWallsSourceError.unavailable(
            animeCatalog.failureMessage ??
                animeNatureCatalog.failureMessage ??
                scenicCatalog.failureMessage ??
                musicCatalog.failureMessage ??
                "Wallpaper catalog is unavailable."
        )
    }

    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        let curatedCatalog = curatedCatalog
        let cachedAnime = await animeProvider.loadCachedCatalog() ?? []
        let cachedAnimeNature = await animeNatureProvider.loadCachedCatalog() ?? []
        let cachedScenic = await scenicProvider.loadCachedCatalog() ?? []
        let cachedMusic = await musicProvider.loadCachedCatalog() ?? []
        let progressState = CatalogProgressState(curated: curatedCatalog, progress: progress)
        await progressState.prime(anime: cachedAnime, animeNature: cachedAnimeNature, scenic: cachedScenic, music: cachedMusic)

        async let animeResult = Self.fetchProviderCatalog(
            provider: animeProvider,
            cached: cachedAnime,
            progress: { partial in
                await progressState.replaceAnime(partial)
            }
        )
        async let animeNatureResult = Self.fetchProviderCatalog(
            provider: animeNatureProvider,
            cached: cachedAnimeNature,
            progress: { partial in
                await progressState.replaceAnimeNature(partial)
            }
        )
        async let scenicResult = Self.fetchProviderCatalog(
            provider: scenicProvider,
            cached: cachedScenic,
            progress: { partial in
                await progressState.replaceScenic(partial)
            }
        )

        async let musicResult = Self.fetchProviderCatalog(provider: musicProvider, cached: cachedMusic,
            progress: { partial in await progressState.replaceMusic(partial) })

        let (animeCatalog, animeNatureCatalog, scenicCatalog, musicCatalog) = await (animeResult, animeNatureResult, scenicResult, musicResult)
        let merged = await progressState.finish(
            anime: animeCatalog.wallpapers,
            animeNature: animeNatureCatalog.wallpapers,
            scenic: scenicCatalog.wallpapers,
            music: musicCatalog.wallpapers
        )
        if !merged.isEmpty {
            return merged
        }
        throw MoeWallsSourceError.unavailable(
            animeCatalog.failureMessage ??
                animeNatureCatalog.failureMessage ??
                scenicCatalog.failureMessage ??
                musicCatalog.failureMessage ??
                "Wallpaper catalog is unavailable."
        )
    }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        try CatalogContentPolicy.validate(wallpaper)
        if let source = wallpaper.sources.first {
            return source.url
        }
        switch wallpaper.catalogGroup {
        case .anime:
            return try await animeProvider.resolveDownloadURL(for: wallpaper)
        case .animeNature:
            return try await animeNatureProvider.resolveDownloadURL(for: wallpaper)
        case .scenic:
            return try await scenicProvider.resolveDownloadURL(for: wallpaper)
        }
    }

    func resolvePreviewSources(for wallpaper: CatalogWallpaper) async throws -> [CatalogVideoSource] {
        try await resolveMedia(for: wallpaper).previewSources
    }

    func resolveMedia(for wallpaper: CatalogWallpaper) async throws -> CatalogResolvedMedia {
        try CatalogContentPolicy.validate(wallpaper)
        let provider: WallpaperCatalogProviding
        switch wallpaper.catalogGroup {
        case .anime:
            provider = animeProvider
        case .animeNature:
            provider = animeNatureProvider
        case .scenic:
            provider = scenicProvider
        }
        if let mediaProvider = provider as? any WallpaperCatalogMediaResolving {
            return try await mediaProvider.resolveMedia(for: wallpaper)
        }
        let previewSources: [CatalogVideoSource]
        if let previewProvider = provider as? any WallpaperCatalogPreviewResolving {
            previewSources = try await previewProvider.resolvePreviewSources(for: wallpaper)
        } else {
            previewSources = wallpaper.sources
        }
        let originalURL = try await provider.resolveDownloadURL(for: wallpaper)
        return CatalogResolvedMedia(
            previewSources: previewSources,
            originalSources: [CatalogVideoSource(url: originalURL, width: 0, height: 0)],
            provider: wallpaper.attribution,
            validUntil: Date().addingTimeInterval(24 * 60 * 60)
        )
    }

    func invalidateResolvedMedia(for wallpaper: CatalogWallpaper) async {
        let provider: WallpaperCatalogProviding
        switch wallpaper.catalogGroup {
        case .anime:
            provider = animeProvider
        case .animeNature:
            provider = animeNatureProvider
        case .scenic:
            provider = scenicProvider
        }
        if let mediaProvider = provider as? any WallpaperCatalogMediaResolving {
            await mediaProvider.invalidateResolvedMedia(for: wallpaper)
        }
    }

    func enrichMediaMetadata(
        for wallpaper: CatalogWallpaper,
        media: CatalogResolvedMedia
    ) async throws -> CatalogResolvedMedia {
        let provider: WallpaperCatalogProviding
        switch wallpaper.catalogGroup {
        case .anime:
            provider = animeProvider
        case .animeNature:
            provider = animeNatureProvider
        case .scenic:
            provider = scenicProvider
        }
        guard let enricher = provider as? any WallpaperCatalogMediaMetadataEnriching else {
            return media
        }
        return try await enricher.enrichMediaMetadata(
            for: wallpaper,
            media: media
        )
    }

    func fetchNextCatalogPage() async throws -> CatalogPage {
        try await withThrowingTaskGroup(of: (CatalogPage?, String?).self) { group in
            for provider in [animeProvider, musicProvider] {
                guard let paging = provider as? any WallpaperCatalogPaging else { continue }
                group.addTask {
                    do { return (try await paging.fetchNextCatalogPage(), nil) }
                    catch {
                        try Task.checkCancellation()
                        if error is CancellationError { throw error }
                        return (nil, error.localizedDescription)
                    }
                }
            }
            var pages: [[CatalogWallpaper]] = [], hasMore = false
            var failure: String?
            for try await (page, error) in group {
                if let page { pages.append(page.wallpapers); hasMore = hasMore || page.hasMore }
                else { failure = error }
            }
            if pages.isEmpty, let failure { throw LearnedCatalogError.unavailable(failure) }
            return CatalogPage(wallpapers: Self.mergeCatalogs(curated: [], catalogs: pages), hasMore: hasMore)
        }
    }

    func fetchNextMusicCatalogPage() async throws -> CatalogPage {
        guard let paging = musicProvider as? any WallpaperCatalogPaging else {
            return CatalogPage(wallpapers: [], hasMore: false)
        }
        let page = try await paging.fetchNextCatalogPage()
        return CatalogPage(wallpapers: page.wallpapers.filter(CatalogContentPolicy.allows), hasMore: page.hasMore)
    }

    func searchCatalog(query: String) async throws -> [CatalogWallpaper] {
        try await searchCatalog(query: query, progress: { _ in })
    }

    func searchCatalog(
        query: String,
        progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void
    ) async throws -> [CatalogWallpaper] {
        let progressState = CatalogSearchProgressState(progress: progress)
        async let animeResults = Self.searchProvider(
            animeProvider,
            query: query,
            progress: { partial in await progressState.replace(partial, at: 0) }
        )
        async let animeNatureResults = Self.searchProvider(
            animeNatureProvider,
            query: query,
            progress: { partial in await progressState.replace(partial, at: 1) }
        )
        async let scenicResults = Self.searchProvider(
            scenicProvider,
            query: query,
            progress: { partial in await progressState.replace(partial, at: 2) }
        )
        async let musicResults = Self.searchProvider(musicProvider, query: query,
            progress: { partial in await progressState.replace(partial, at: 3) })
        let results = await (animeResults, animeNatureResults, scenicResults, musicResults)
        return await progressState.finish(with: [results.0, results.1, results.2, results.3])
    }

    func clearCache() async {
        if let cacheClearingProvider = animeProvider as? CatalogCacheClearing {
            await cacheClearingProvider.clearCache()
        }
        if let cacheClearingProvider = animeNatureProvider as? CatalogCacheClearing {
            await cacheClearingProvider.clearCache()
        }
        if let cacheClearingProvider = scenicProvider as? CatalogCacheClearing {
            await cacheClearingProvider.clearCache()
        }
        await (musicProvider as? any CatalogCacheClearing)?.clearCache()
    }

    fileprivate static func mergeCatalogs(
        curated: [CatalogWallpaper],
        catalogs: [[CatalogWallpaper]]
    ) -> [CatalogWallpaper] {
        var indices: [String: Int] = [:]
        var merged: [CatalogWallpaper] = []
        let allCatalogs = [curated] + catalogs
        let maxCount = allCatalogs.map(\.count).max() ?? 0

        for index in 0..<maxCount {
            for catalog in allCatalogs where index < catalog.count {
                let wallpaper = catalog[index]
                guard CatalogContentPolicy.allows(wallpaper) else { continue }
                if let existing = indices[wallpaper.id] {
                    if wallpaper.hasMusic == true { merged[existing].hasMusic = true }
                } else {
                    indices[wallpaper.id] = merged.count
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

    private static func searchProvider(
        _ provider: WallpaperCatalogProviding,
        query: String,
        progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void
    ) async -> [CatalogWallpaper] {
        guard let searchableProvider = provider as? any WallpaperCatalogSearching else {
            return []
        }
        return (try? await searchableProvider.searchCatalog(query: query, progress: progress)) ?? []
    }

    fileprivate static func mergeSearchResults(_ catalogs: [[CatalogWallpaper]]) -> [CatalogWallpaper] {
        var ids: [String: Int] = [:]
        var titles: [String: Int] = [:]
        var merged: [CatalogWallpaper] = []
        let maxCount = catalogs.map(\.count).max() ?? 0

        for index in 0..<maxCount {
            for catalog in catalogs where index < catalog.count {
                let wallpaper = catalog[index]
                guard CatalogContentPolicy.allows(wallpaper) else { continue }
                let titleKey = wallpaper.title
                    .folding(
                        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                        locale: Locale(identifier: "en_US_POSIX")
                    )
                    .lowercased()
                    .replacingOccurrences(of: " live wallpaper", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let existing = ids[wallpaper.id] ?? titles[titleKey] {
                    // Keep the actual audible source, rather than labelling a
                    // different site's silent copy of the same title as music.
                    if wallpaper.hasMusic == true { merged[existing] = wallpaper }
                    ids[wallpaper.id] = existing; titles[titleKey] = existing
                    continue
                }
                ids[wallpaper.id] = merged.count; titles[titleKey] = merged.count
                merged.append(wallpaper)
            }
        }

        return merged
    }
}

private actor CatalogSearchProgressState {
    private let progress: @Sendable ([CatalogWallpaper]) async -> Void
    private var catalogs = Array(repeating: [CatalogWallpaper](), count: 4)
    private var lastEmittedIDs: [String] = []

    init(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) {
        self.progress = progress
    }

    func replace(_ wallpapers: [CatalogWallpaper], at index: Int) async {
        guard catalogs.indices.contains(index) else { return }
        catalogs[index] = wallpapers
        await emitIfNeeded()
    }

    func finish(with finalCatalogs: [[CatalogWallpaper]]) async -> [CatalogWallpaper] {
        for index in catalogs.indices where finalCatalogs.indices.contains(index) {
            if !finalCatalogs[index].isEmpty || catalogs[index].isEmpty {
                catalogs[index] = finalCatalogs[index]
            }
        }
        await emitIfNeeded()
        return ManagedWallpaperCatalogProvider.mergeSearchResults(catalogs)
    }

    private func emitIfNeeded() async {
        let merged = ManagedWallpaperCatalogProvider.mergeSearchResults(catalogs)
        let ids = merged.map(\.id)
        guard ids != lastEmittedIDs else { return }
        lastEmittedIDs = ids
        await progress(merged)
    }
}

extension MoeWallsSource: CatalogCacheClearing {}
extension MoeWallsSource: WallpaperCatalogSearching {}

private struct ProviderCatalogFetchResult: Sendable {
    let wallpapers: [CatalogWallpaper]
    let failureMessage: String?
}

private actor CatalogProgressState {
    private let curated: [CatalogWallpaper]
    private let progress: @Sendable ([CatalogWallpaper]) async -> Void
    private var anime: [CatalogWallpaper] = []
    private var animeNature: [CatalogWallpaper] = []
    private var scenic: [CatalogWallpaper] = []
    private var music: [CatalogWallpaper] = []
    private var lastEmittedIDs: [String] = []

    init(
        curated: [CatalogWallpaper],
        progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void
    ) {
        self.curated = curated
        self.progress = progress
    }

    func prime(anime: [CatalogWallpaper], animeNature: [CatalogWallpaper], scenic: [CatalogWallpaper], music: [CatalogWallpaper]) async {
        self.anime = anime
        self.animeNature = animeNature
        self.scenic = scenic
        self.music = music
        await emitIfNeeded()
    }

    func replaceAnime(_ wallpapers: [CatalogWallpaper]) async {
        anime = wallpapers
        await emitIfNeeded()
    }

    func replaceAnimeNature(_ wallpapers: [CatalogWallpaper]) async {
        animeNature = wallpapers
        await emitIfNeeded()
    }

    func replaceScenic(_ wallpapers: [CatalogWallpaper]) async {
        scenic = wallpapers
        await emitIfNeeded()
    }

    func replaceMusic(_ wallpapers: [CatalogWallpaper]) async {
        music = wallpapers
        await emitIfNeeded()
    }

    func finish(anime: [CatalogWallpaper], animeNature: [CatalogWallpaper], scenic: [CatalogWallpaper], music: [CatalogWallpaper]) async -> [CatalogWallpaper] {
        self.anime = anime
        self.animeNature = animeNature
        self.scenic = scenic
        self.music = music
        let merged = ManagedWallpaperCatalogProvider.mergeCatalogs(
            curated: curated,
            catalogs: [anime, animeNature, scenic, music]
        )
        await emitIfNeeded(merged)
        return merged
    }

    private func emitIfNeeded(_ merged: [CatalogWallpaper]? = nil) async {
        let merged = merged ?? ManagedWallpaperCatalogProvider.mergeCatalogs(
            curated: curated,
            catalogs: [anime, animeNature, scenic, music]
        )
        guard !merged.isEmpty else { return }

        let emittedIDs = merged.map(\.id)
        guard emittedIDs != lastEmittedIDs else { return }
        lastEmittedIDs = emittedIDs
        await progress(merged)
    }
}
