import Foundation

/// A separate collection of decoded, audible videos. Site tags and titles
/// supply candidates; they never supply the music badge themselves.
actor MusicWallpaperCatalogProvider: WallpaperCatalogProviding, WallpaperCatalogPaging, WallpaperCatalogSearching, CatalogCacheClearing {
    struct Entry: Sendable {
        let site: LearnedAnimeSite
        let provider: WallpaperCatalogProviding
        let seeds: [CatalogWallpaper]
    }
    typealias VerifyAudio = @Sendable (URL, URL?) async throws -> WallpaperAudioContent
    private struct AudioEntry: Codable { let content: WallpaperAudioContent; let expires: Date }
    private let entries: [Entry]
    private let verifyAudio: VerifyAudio
    private let directory: URL?
    private var audioCache: [String: AudioEntry]
    private var queues: [[CatalogWallpaper]]
    private var more: [Bool]
    private var loaded: [CatalogWallpaper] = []
    private var generation: UInt = 0
    private let batchSize: Int

    init(entries: [Entry]? = nil,
         directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AuraFlow/MusicCatalog", isDirectory: true),
         batchSize: Int = 16,
         verifyAudio: @escaping VerifyAudio = { url, referer in try await MusicWallpaperCatalogProvider.verifyOriginalAudio(url, referer) }) {
        let seeds = Self.bundledSelections()
        let sources = entries ?? [LearnedAnimeSite.desktophut, .livewallpapers4free].map { site in
            Entry(site: site, provider: LearnedAnimeSource(site: site, musicCollection: true),
                seeds: seeds.filter { $0.sourcePageURL.map { site.accepts($0) } == true })
        }
        self.entries = sources; self.directory = directory; self.verifyAudio = verifyAudio
        self.batchSize = max(1, min(batchSize, 32))
        queues = Array(repeating: [], count: sources.count)
        more = Array(repeating: true, count: sources.count)
        audioCache = directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("verification.json")) }
            .flatMap { try? JSONDecoder().decode([String: AudioEntry].self, from: $0) } ?? [:]
    }

    static func bundledSelections() -> [CatalogWallpaper] {
        Bundle.module.url(forResource: "music-catalog-seeds", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([CatalogWallpaper].self, from: $0) } ?? []
    }

    static func verifyOriginalAudio(_ url: URL, _ referer: URL?) async throws -> WallpaperAudioContent {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return try await MP4AudioMetadata.inspectSound(url: url, referer: referer, session: session)
    }

    func loadCachedCatalog() async -> [CatalogWallpaper]? {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("catalog.json")),
              let items = try? JSONDecoder().decode([CatalogWallpaper].self, from: data), !items.isEmpty else { return nil }
        return items.filter { $0.hasMusic == true }
    }

    func fetchCatalog() async throws -> [CatalogWallpaper] { try await fetchCatalog(progress: { _ in }) }

    func fetchCatalog(progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        generation &+= 1
        let revision = generation
        let cached = await loadCachedCatalog() ?? []
        try Task.checkCancellation()
        guard generation == revision else { throw CancellationError() }
        loaded = cached
        if !cached.isEmpty { await progress(cached) }
        let lists = await withTaskGroup(of: (Int, [CatalogWallpaper]).self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask { (index, (try? await entry.provider.fetchCatalog()) ?? []) }
            }
            var result = Array(repeating: [CatalogWallpaper](), count: entries.count)
            for await (index, items) in group { result[index] = items }
            return result
        }
        try Task.checkCancellation()
        guard generation == revision else { throw CancellationError() }
        let cachedIDs = Set(cached.map(\.id))
        queues = entries.indices.map {
            let candidates = Self.unique(entries[$0].seeds + lists[$0])
            return candidates.filter { !cachedIDs.contains($0.id) } + candidates.filter { cachedIDs.contains($0.id) }
        }
        more = Array(repeating: true, count: entries.count)
        let batch = try await nextBatch(revision: revision, progress: { await progress(Self.unique(cached + $0)) })
        try Task.checkCancellation()
        guard generation == revision else { throw CancellationError() }
        loaded = Self.unique(loaded + batch)
        persist()
        return loaded
    }

    func fetchNextCatalogPage() async throws -> CatalogPage {
        let revision = generation
        let pending = entries.indices.filter { queues[$0].isEmpty && more[$0] }
        let pages = try await withThrowingTaskGroup(of: (Int, CatalogPage?, String?).self) { group in
            for index in pending {
                let provider = entries[index].provider
                group.addTask {
                    guard let paging = provider as? any WallpaperCatalogPaging else {
                        return (index, CatalogPage(wallpapers: [], hasMore: false), nil)
                    }
                    do { return (index, try await paging.fetchNextCatalogPage(), nil) }
                    catch { try Task.checkCancellation(); return (index, nil, error.localizedDescription) }
                }
            }
            var result: [(Int, CatalogPage?, String?)] = []
            for try await page in group { result.append(page) }
            return result
        }
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
        for (index, page, _) in pages {
            if let page {
                queues[index] = Self.unique(page.wallpapers).filter { item in !loaded.contains { $0.id == item.id } }
                more[index] = page.hasMore
            }
        }
        if !pages.isEmpty, pages.allSatisfy({ $0.1 == nil }), queues.allSatisfy(\.isEmpty),
           let failure = pages.compactMap({ $0.2 }).first { throw LearnedCatalogError.unavailable(failure) }
        let additions = try await nextBatch(revision: revision, progress: { _ in })
        loaded = Self.unique(loaded + additions)
        persist()
        return CatalogPage(wallpapers: additions, hasMore: more.contains(true) || queues.contains { !$0.isEmpty })
    }

    private func nextBatch(revision: UInt, progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        let candidates = queues.map { Array($0.prefix(batchSize)) }
        for index in queues.indices { queues[index].removeFirst(candidates[index].count) }
        do { return try await verifyCandidates(candidates, revision: revision, progress: progress) }
        catch {
            // Foreground downloads cancel discovery. Restore this batch so
            // reopening the catalog cannot permanently skip those wallpapers.
            if revision == generation {
                for index in queues.indices { queues[index] = Self.unique(candidates[index] + queues[index]) }
            }
            throw error
        }
    }

    /// Four probes total, shared by all sites. A larger page must not create a
    /// burst of dozens of audio requests or delay a foreground download.
    private func verifyCandidates(_ batches: [[CatalogWallpaper]], revision: UInt,
                                  progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        var candidates: [(Entry, CatalogWallpaper)] = []
        for row in 0..<(batches.map(\.count).max() ?? 0) {
            for index in entries.indices where row < batches[index].count {
                candidates.append((entries[index], batches[index][row]))
            }
        }
        return try await withThrowingTaskGroup(of: (Int, CatalogWallpaper?).self) { group in
            var cursor = 0
            func schedule() {
                guard cursor < candidates.count else { return }
                let index = cursor, (entry, item) = candidates[cursor]
                cursor += 1
                group.addTask { (index, try await self.verified([item], entry: entry, revision: revision).first) }
            }
            for _ in 0..<4 { schedule() }
            var result: [Int: CatalogWallpaper] = [:]
            while let (index, item) = try await group.next() {
                try Task.checkCancellation()
                guard revision == generation else { throw CancellationError() }
                if let item {
                    result[index] = item
                    await progress(Self.unique(result.keys.sorted().compactMap { result[$0] }))
                }
                schedule()
            }
            return Self.unique(result.keys.sorted().compactMap { result[$0] })
        }
    }

    func searchCatalog(query: String) async throws -> [CatalogWallpaper] {
        try await searchCatalog(query: query, progress: { _ in })
    }

    func searchCatalog(query: String, progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let known = loaded
        let revision = generation
        let batches = await withTaskGroup(of: (Int, [CatalogWallpaper]).self) { group in
            for (index, entry) in entries.enumerated() {
                group.addTask {
                    let local = (entry.seeds + known).filter {
                        $0.sourcePageURL.map { entry.site.accepts($0) } == true &&
                        WallpaperSearchMatcher.matches(query: query, fields: [$0.title, $0.id])
                    }
                    let remote = (try? await (entry.provider as? any WallpaperCatalogSearching)?.searchCatalog(query: query)) ?? []
                    return (index, Array(Self.unique(local + remote).prefix(self.batchSize)))
                }
            }
            var batches = Array(repeating: [CatalogWallpaper](), count: entries.count)
            for await (index, items) in group { batches[index] = items }
            return batches
        }
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
        return try await verifyCandidates(batches, revision: revision, progress: progress)
    }

    private func verified(_ candidates: [CatalogWallpaper], entry: Entry, revision: UInt) async throws -> [CatalogWallpaper] {
        var result: [CatalogWallpaper] = []
        for item in candidates {
            try Task.checkCancellation()
            guard !item.explicitlyExcludesMusic, let page = item.sourcePageURL, entry.site.accepts(page) else { continue }
            do {
                let url: URL
                if let resolver = entry.provider as? any WallpaperCatalogMediaResolving {
                    guard let original = try await resolver.resolveMedia(for: item).originalSources.first else { continue }
                    url = original.url
                } else { url = try await entry.provider.resolveDownloadURL(for: item) }
                guard entry.site.accepts(url, media: true) else { continue }
                let content: WallpaperAudioContent
                if let saved = audioCache[url.absoluteString], saved.expires > Date() { content = saved.content }
                else {
                    content = try await verifyAudio(url, page)
                    try Task.checkCancellation()
                    guard revision == generation else { throw CancellationError() }
                    audioCache[url.absoluteString] = AudioEntry(content: content,
                        expires: Date().addingTimeInterval(content == .unknown ? 600 : 7 * 86400))
                }
                try Task.checkCancellation()
                guard revision == generation else { throw CancellationError() }
                if content == .audible {
                    var verified = item
                    verified.hasMusic = true
                    result.append(verified)
                } else if content == .silent || content == .noTrack {
                    loaded.removeAll { $0.id == item.id }
                }
            } catch {
                try Task.checkCancellation()
                guard revision == generation else { throw CancellationError() }
                if error is CancellationError { throw error }
                // One unavailable or unsupported video must not hide another
                // site's verified music collection.
            }
        }
        return result
    }

    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        guard let page = wallpaper.sourcePageURL, let entry = entries.first(where: { $0.site.accepts(page) }) else { throw URLError(.badURL) }
        return try await entry.provider.resolveDownloadURL(for: wallpaper)
    }

    func clearCache() async {
        generation &+= 1
        audioCache = [:]; loaded = []
        queues = Array(repeating: [], count: entries.count)
        more = Array(repeating: false, count: entries.count)
        if let directory {
            for name in ["catalog.json", "verification.json"] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        }
        for entry in entries { await (entry.provider as? any CatalogCacheClearing)?.clearCache() }
    }

    private func persist() {
        guard let directory else { return }
        if audioCache.count > 512 { audioCache = audioCache.filter { $0.value.expires > Date() } }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(loaded) { try? data.write(to: directory.appendingPathComponent("catalog.json"), options: .atomic) }
        if let data = try? JSONEncoder().encode(audioCache) { try? data.write(to: directory.appendingPathComponent("verification.json"), options: .atomic) }
    }

    private static func unique(_ items: [CatalogWallpaper]) -> [CatalogWallpaper] {
        var ids = Set<String>()
        return items.filter { ids.insert($0.id).inserted }
    }
}
