import Foundation

/// One category can contain several sites. Route media by its source host,
/// never by category (otherwise a DesktopHut card would be sent to MoeWalls).
actor AnimeWallpaperCatalogProvider: WallpaperCatalogProviding, WallpaperCatalogPaging, WallpaperCatalogSearching,
    WallpaperCatalogMediaResolving, WallpaperCatalogPreviewResolving, WallpaperCatalogMediaMetadataEnriching, CatalogCacheClearing {
    struct Entry: Sendable {
        let hosts: Set<String>
        let provider: WallpaperCatalogProviding
    }
    private let entries: [Entry]

    init(entries: [Entry] = [
        Entry(hosts: ["moewalls.com", "www.moewalls.com"], provider: MoeWallsSource()),
        Entry(hosts: ["www.desktophut.com"], provider: LearnedAnimeSource(site: .desktophut)),
        Entry(hosts: ["livewallpapers4free.com"], provider: LearnedAnimeSource(site: .livewallpapers4free)),
        Entry(hosts: ["livelywallpaper.app"], provider: LearnedAnimeSource(site: .livelywallpaper)),
    ]) { self.entries = entries }

    func loadCachedCatalog() async -> [CatalogWallpaper]? {
        var catalogs: [[CatalogWallpaper]] = []
        for entry in entries { catalogs.append(await entry.provider.loadCachedCatalog() ?? []) }
        let merged = Self.merge(catalogs)
        return merged.isEmpty ? nil : merged
    }

    func clearCache() async {
        for entry in entries { await (entry.provider as? any CatalogCacheClearing)?.clearCache() }
    }

    func fetchCatalog() async throws -> [CatalogWallpaper] { try await fetchCatalog(progress: { _ in }) }

    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        try await collect(query: nil, progress: progress)
    }

    func searchCatalog(query: String) async throws -> [CatalogWallpaper] { try await searchCatalog(query: query, progress: { _ in }) }

    func searchCatalog(query: String, progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        try await collect(query: query, progress: progress)
    }

    private struct Result: Sendable { let index: Int; let items: [CatalogWallpaper]; let failure: String? }

    private func collect(query: String?, progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        let state = AnimeCatalogProgress(count: entries.count, progress: progress)
        return try await withThrowingTaskGroup(of: Result.self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask {
                    do {
                        let items: [CatalogWallpaper]
                        if let query {
                            items = try await (entry.provider as? any WallpaperCatalogSearching)?.searchCatalog(query: query,
                                progress: { await state.replace($0, at: index) }) ?? []
                        } else {
                            items = try await entry.provider.fetchCatalog(progress: { await state.replace($0, at: index) })
                        }
                        try Task.checkCancellation()
                        return Result(index: index, items: items, failure: nil)
                    } catch {
                        try Task.checkCancellation()
                        if error is CancellationError { throw error }
                        let fallback = query == nil ? await entry.provider.loadCachedCatalog() ?? [] : []
                        return Result(index: index, items: fallback, failure: error.localizedDescription)
                    }
                }
            }
            var catalogs = Array(repeating: [CatalogWallpaper](), count: entries.count)
            var failures: [String] = []
            for try await result in group {
                catalogs[result.index] = result.items
                if let failure = result.failure { failures.append(failure) }
                await state.replace(result.items, at: result.index)
            }
            let merged = Self.merge(catalogs)
            if query == nil, merged.isEmpty, let failure = failures.first { throw LearnedCatalogError.unavailable(failure) }
            return merged
        }
    }

    func fetchNextCatalogPage() async throws -> CatalogPage {
        try await withThrowingTaskGroup(of: (Int, CatalogPage?, String?).self) { group in
            for (index, entry) in entries.enumerated() {
                guard let provider = entry.provider as? any WallpaperCatalogPaging else { continue }
                group.addTask {
                    do { return (index, try await provider.fetchNextCatalogPage(), nil) }
                    catch { try Task.checkCancellation(); return (index, nil, error.localizedDescription) }
                }
            }
            var pages = Array(repeating: [CatalogWallpaper](), count: entries.count)
            var hasMore = false
            var successes = 0
            var failure: String?
            for try await (index, page, message) in group {
                if let page { pages[index] = page.wallpapers; hasMore = hasMore || page.hasMore; successes += 1 }
                else { failure = message }
            }
            if successes == 0, let failure { throw LearnedCatalogError.unavailable(failure) }
            return CatalogPage(wallpapers: Self.merge(pages), hasMore: hasMore)
        }
    }

    private func provider(for wallpaper: CatalogWallpaper) throws -> WallpaperCatalogProviding {
        // Older cached MoeWalls cards can contain direct media but no page URL.
        if wallpaper.sourcePageURL == nil, wallpaper.attribution == "MoeWalls",
           let entry = entries.first(where: { $0.hosts.contains("moewalls.com") }) {
            return entry.provider
        }
        guard let host = wallpaper.sourcePageURL?.host?.lowercased(),
              let entry = entries.first(where: { $0.hosts.contains(host) }) else { throw URLError(.badURL) }
        return entry.provider
    }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        try await provider(for: wallpaper).resolveDownloadURL(for: wallpaper)
    }

    func resolvePreviewSources(for wallpaper: CatalogWallpaper) async throws -> [CatalogVideoSource] {
        try await resolveMedia(for: wallpaper).previewSources
    }

    func resolveMedia(for wallpaper: CatalogWallpaper) async throws -> CatalogResolvedMedia {
        let source = try provider(for: wallpaper)
        if let resolver = source as? any WallpaperCatalogMediaResolving { return try await resolver.resolveMedia(for: wallpaper) }
        let original = try await source.resolveDownloadURL(for: wallpaper)
        let previews = try await (source as? any WallpaperCatalogPreviewResolving)?.resolvePreviewSources(for: wallpaper) ?? wallpaper.sources
        return CatalogResolvedMedia(previewSources: previews,
            originalSources: [CatalogVideoSource(url: original, width: 0, height: 0)], provider: wallpaper.attribution,
            validUntil: Date().addingTimeInterval(3600))
    }

    func invalidateResolvedMedia(for wallpaper: CatalogWallpaper) async {
        guard let source = try? provider(for: wallpaper) as? any WallpaperCatalogMediaResolving else { return }
        await source.invalidateResolvedMedia(for: wallpaper)
    }

    func enrichMediaMetadata(for wallpaper: CatalogWallpaper, media: CatalogResolvedMedia) async throws -> CatalogResolvedMedia {
        guard let source = try provider(for: wallpaper) as? any WallpaperCatalogMediaMetadataEnriching else { return media }
        return try await source.enrichMediaMetadata(for: wallpaper, media: media)
    }

    static func merge(_ catalogs: [[CatalogWallpaper]]) -> [CatalogWallpaper] {
        var merged: [CatalogWallpaper] = []
        var ids = Set<String>()
        for row in 0..<(catalogs.map(\.count).max() ?? 0) {
            for catalog in catalogs where row < catalog.count {
                if ids.insert(catalog[row].id).inserted { merged.append(catalog[row]) }
            }
        }
        return merged
    }
}

private actor AnimeCatalogProgress {
    var catalogs: [[CatalogWallpaper]]
    let progress: @Sendable ([CatalogWallpaper]) async -> Void
    init(count: Int, progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) {
        catalogs = Array(repeating: [], count: count)
        self.progress = progress
    }
    func replace(_ items: [CatalogWallpaper], at index: Int) async {
        catalogs[index] = items
        await progress(AnimeWallpaperCatalogProvider.merge(catalogs))
    }
}
