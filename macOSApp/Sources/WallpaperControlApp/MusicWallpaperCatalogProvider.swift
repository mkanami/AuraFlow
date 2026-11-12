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
    private let batchSize = 4

    init(entries: [Entry]? = nil,
         directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AuraFlow/MusicCatalog", isDirectory: true),
         verifyAudio: @escaping VerifyAudio = { url, referer in try await MusicWallpaperCatalogProvider.verifyOriginalAudio(url, referer) }) {
        let seeds = Bundle.module.url(forResource: "music-catalog-seeds", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([CatalogWallpaper].self, from: $0) } ?? []
        let sources = entries ?? LearnedAnimeSite.allCases.map { site in
            Entry(site: site, provider: LearnedAnimeSource(site: site, musicCollection: true),
                seeds: seeds.filter { $0.sourcePageURL.map { site.accepts($0) } == true })
        }
        self.entries = sources; self.directory = directory; self.verifyAudio = verifyAudio
        queues = Array(repeating: [], count: sources.count)
        more = Array(repeating: true, count: sources.count)
        audioCache = directory.flatMap { try? Data(contentsOf: $0.appendingPathComponent("verification.json")) }
            .flatMap { try? JSONDecoder().decode([String: AudioEntry].self, from: $0) } ?? [:]
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
        loaded = []
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
        queues = entries.indices.map { Self.unique(entries[$0].seeds + lists[$0]) }
        more = Array(repeating: true, count: entries.count)
        let batch = try await nextBatch(revision: revision, progress: progress)
        loaded = batch
        persist()
        return loaded
    }

    func fetchNextCatalogPage() async throws -> CatalogPage {
        let revision = generation
        for index in entries.indices where queues[index].isEmpty && more[index] {
            guard let paging = entries[index].provider as? any WallpaperCatalogPaging else { more[index] = false; continue }
            let page = try await paging.fetchNextCatalogPage()
            try Task.checkCancellation()
            guard revision == generation else { throw CancellationError() }
            queues[index] = Self.unique(page.wallpapers).filter { item in !loaded.contains { $0.id == item.id } }
            more[index] = page.hasMore
        }
        let additions = try await nextBatch(revision: revision, progress: { _ in })
        loaded = Self.unique(loaded + additions)
        persist()
        return CatalogPage(wallpapers: additions, hasMore: more.contains(true) || queues.contains { !$0.isEmpty })
    }

    private func nextBatch(revision: UInt, progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        let candidates = queues.map { Array($0.prefix(batchSize)) }
        for index in queues.indices { queues[index].removeFirst(candidates[index].count) }
        return try await withThrowingTaskGroup(of: [CatalogWallpaper].self) { group in
            for index in entries.indices {
                let entry = entries[index], items = candidates[index]
                group.addTask { try await self.verified(items, entry: entry) }
            }
            var result: [CatalogWallpaper] = []
            for try await items in group {
                guard revision == generation else { throw CancellationError() }
                result = Self.unique(result + items)
                if !result.isEmpty { await progress(result) }
            }
            return result
        }
    }

    func searchCatalog(query: String) async throws -> [CatalogWallpaper] {
        try await searchCatalog(query: query, progress: { _ in })
    }

    func searchCatalog(query: String, progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void) async throws -> [CatalogWallpaper] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let known = loaded
        return try await withThrowingTaskGroup(of: [CatalogWallpaper].self) { group in
            for entry in entries {
                group.addTask {
                    let local = (entry.seeds + known).filter {
                        $0.sourcePageURL.map { entry.site.accepts($0) } == true &&
                        WallpaperSearchMatcher.matches(query: query, fields: [$0.title, $0.id])
                    }
                    let remote = (try? await (entry.provider as? any WallpaperCatalogSearching)?.searchCatalog(query: query)) ?? []
                    return try await self.verified(Array(Self.unique(local + remote).prefix(4)), entry: entry)
                }
            }
            var result: [CatalogWallpaper] = []
            for try await items in group {
                result = Self.unique(result + items)
                await progress(result)
            }
            return result
        }
    }

    private func verified(_ candidates: [CatalogWallpaper], entry: Entry) async throws -> [CatalogWallpaper] {
        let revision = generation
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
                if content == .audible {
                    var verified = item
                    verified.hasMusic = true
                    result.append(verified)
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
