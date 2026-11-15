import Foundation
import Testing
@testable import WallpaperControlApp

@Test func musicCatalogIncludesOnlyAudibleOriginalsAndCachesVerification() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let items = [musicCard("sound"), musicCard("silent"), musicCard("no-track"), musicCard("unknown")]
    let backend = MusicFixtureSource(items: items)
    let recorder = MusicAudioRecorder()
    let entry = MusicWallpaperCatalogProvider.Entry(site: .desktophut, provider: backend, seeds: [])
    let provider = MusicWallpaperCatalogProvider(entries: [entry], directory: root,
        verifyAudio: { url, _ in await recorder.inspect(url) })
    let result = try await provider.fetchCatalog()
    #expect(result.map(\.id) == ["sound"])
    #expect(result.allSatisfy { $0.hasMusic == true })
    let inspected = await recorder.urls
    #expect(inspected.count == 4)
    #expect(inspected.allSatisfy { !$0.path.contains("preview") })
    let cached = await provider.loadCachedCatalog()
    #expect(cached == result)
    let restored = MusicWallpaperCatalogProvider(entries: [entry], directory: root,
        verifyAudio: { _, _ in Issue.record("A fresh cached route must not be probed again"); return .unknown })
    #expect(try await restored.fetchCatalog() == result)
    #expect(try await provider.searchCatalog(query: "Wallpaper").map(\.id) == ["sound"])
    #expect(await recorder.urls.count == 4)
    await provider.clearCache()
    #expect(await provider.loadCachedCatalog() == nil)
}

@Test func musicCatalogDoesNotTrustMusicTitlesOrPreviouslyClaimedFlags() async throws {
    var silent = musicCard("silent", title: "With Music Live Wallpaper")
    silent.hasMusic = true
    let source = MusicFixtureSource(items: [silent])
    let provider = MusicWallpaperCatalogProvider(entries: [.init(site: .desktophut, provider: source, seeds: [silent])],
        directory: nil, verifyAudio: { _, _ in .silent })
    #expect(try await provider.fetchCatalog().isEmpty)
    let voiceOnly = musicCard("sound-voice", title: "Welcome Home Sir with No Music")
    let voices = MusicWallpaperCatalogProvider(entries: [.init(site: .desktophut,
        provider: MusicFixtureSource(items: [voiceOnly]), seeds: [])], directory: nil, verifyAudio: { _, _ in .audible })
    #expect(try await voices.fetchCatalog().isEmpty)
}

@Test @MainActor func musicCatalogLateAudioProofSurvivesPagingSearchAndManifestStorage() async throws {
    let ordinary = musicCard("same")
    var verified = ordinary; verified.hasMusic = true
    let model = CatalogViewModel()
    model.wallpapers = [ordinary]
    model.appendCatalogPage(mergedWallpapers: [ordinary, verified], hasMoreRemotePages: false)
    #expect(model.wallpapers.count == 1)
    #expect(model.musicCount == 1)
    model.appendSearchResults([ordinary])
    model.appendSearchResults([verified])
    #expect(model.searchResults.first?.hasMusic == true)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let backend = MusicFixtureSource(items: [], next: [verified])
    let repository = CatalogRepository(provider: backend, catalogDirectoryURL: root)
    let page = try await repository.loadNextCatalogPage(existing: [ordinary])
    #expect(page.wallpapers.first?.hasMusic == true)
    #expect(page.persistenceStatus.didPersist)
    let file = root.appendingPathComponent("wallpaper.mp4")
    try Data("fixture".utf8).write(to: file)
    let saved = repository.registerDownloadedWallpaper(verified, localURL: file, existing: [])
    #expect(saved.wallpapers.first?.hasMusic == true)
    #expect(repository.loadDownloadedWallpapers(preserving: []).wallpapers.first?.hasMusic == true)
}

@Test func musicCatalogPagesThroughCandidatesAndSurvivesAnotherSourceFailure() async throws {
    let candidates = (0..<4).map { musicCard("silent-\($0)") } + [musicCard("sound-next")]
    let good = MusicFixtureSource(items: candidates)
    let bad = MusicFixtureSource(items: [], fails: true)
    let recorder = MusicAudioRecorder()
    let provider = MusicWallpaperCatalogProvider(entries: [
        .init(site: .desktophut, provider: good, seeds: []),
        .init(site: .livewallpapers4free, provider: bad, seeds: []),
    ], directory: nil, batchSize: 4, verifyAudio: { url, _ in await recorder.inspect(url) })
    #expect(try await provider.fetchCatalog().isEmpty)
    let next = try await provider.fetchNextCatalogPage()
    #expect(next.wallpapers.map(\.id) == ["sound-next"])
    let end = try await provider.fetchNextCatalogPage()
    #expect(!end.hasMore)
}

@Test func musicCatalogAggregatePreservesMusicOnDuplicateCardsAndTheAudibleSearchRoute() async throws {
    let silent = musicCard("same", title: "Night Wallpaper")
    var audible = silent; audible.hasMusic = true
    let ordinary = MusicFixtureSource(items: [silent])
    let music = MusicFixtureSource(items: [audible])
    let empty = MusicFixtureSource(items: [])
    let provider = ManagedWallpaperCatalogProvider(animeProvider: ordinary, animeNatureProvider: empty,
        scenicProvider: empty, musicProvider: music, curatedCatalog: [])
    let listed = try await provider.fetchCatalog()
    #expect(listed.count == 1)
    #expect(listed.first?.hasMusic == true)
    let searched = try await provider.searchCatalog(query: "Night")
    #expect(searched.count == 1)
    #expect(searched.first?.hasMusic == true)
}

@Test @MainActor func musicCatalogTabFiltersSearchAndLetsConfirmedSilenceOverrideOldFlags() {
    let model = CatalogViewModel()
    let unknown = musicCard("unknown")
    var sound = musicCard("sound"); sound.hasMusic = true
    var silent = musicCard("silent"); silent.hasMusic = true
    model.wallpapers = [unknown, sound, silent]
    model.audioStatus = ["silent": false]
    model.toggleMusic()
    #expect(model.showsMusicOnly)
    #expect(model.filteredWallpapers.map(\.id) == ["sound"])
    #expect(model.musicCount == 1)
    var discovered = unknown; discovered.hasMusic = true
    model.appendSearchResults([discovered])
    model.searchText = "unknown"
    #expect(model.filteredWallpapers.map(\.id) == ["unknown"])
    model.toggleGroup(.anime)
    #expect(!model.showsMusicOnly)
    model.toggleMusic()
    model.resetCatalogNavigation()
    #expect(!model.showsMusicOnly)
}

@Test func musicCatalogFlagRemainsCompatibleWithExistingCachedCards() throws {
    var item = musicCard("sound"); item.hasMusic = true
    let data = try JSONEncoder().encode(item)
    #expect(try JSONDecoder().decode(CatalogWallpaper.self, from: data).hasMusic == true)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy["hasMusic"] = nil
    #expect(try JSONDecoder().decode(CatalogWallpaper.self, from: JSONSerialization.data(withJSONObject: legacy)).hasMusic == nil)
}

@Test func musicCatalogLiveVerifiesBundledSelectionsFromBothSites() async throws {
    guard ProcessInfo.processInfo.environment["AURAFLOW_LIVE_MUSIC_CATALOG"] == "1" else { return }
    let provider = MusicWallpaperCatalogProvider(directory: nil)
    var result = try await provider.fetchCatalog()
    print("[music-cold-start] initial \(result.count)/\(MusicWallpaperCatalogProvider.bundledSelections().count)")
    for _ in 0..<3 where await provider.hasMoreMusicCatalogPages() {
        do { result = CatalogWallpaperMerge.combining(result, try await provider.fetchNextCatalogPage().wallpapers) }
        catch { print("[music-cold-start] retry unavailable: \(error.localizedDescription)") }
    }
    #expect(result.count == MusicWallpaperCatalogProvider.bundledSelections().count)
    #expect(result.allSatisfy { $0.hasMusic == true })
    #expect(Set(result.map(\.attribution)) == ["DesktopHut", "LiveWallpapers4Free"])
    for fragment in ["summer-mountain-lake", "Rainy-Forest"] {
        #expect(result.contains { $0.id.contains(fragment) }, "Missing verified music selection: \(fragment)")
    }
    for item in result { print("[verified-music] \(item.attribution) | \(item.title)") }
}

private func musicCard(_ id: String, title: String? = nil) -> CatalogWallpaper {
    CatalogWallpaper(id: id, title: title ?? "Wallpaper \(id)", category: "Anime", attribution: "DesktopHut",
        previewImageURL: nil, sourcePageURL: URL(string: "https://www.desktophut.com/\(id)"), sources: [])
}

private actor MusicAudioRecorder {
    var urls: [URL] = []
    func inspect(_ url: URL) -> WallpaperAudioContent {
        urls.append(url)
        let name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("sound") { return .audible }
        if name.hasPrefix("silent") { return .silent }
        if name.hasPrefix("no-track") { return .noTrack }
        return .unknown
    }
}

private actor MusicFixtureSource: WallpaperCatalogProviding, WallpaperCatalogPaging, WallpaperCatalogSearching, WallpaperCatalogMediaResolving {
    let items: [CatalogWallpaper]
    let fails: Bool
    let failsNext: Bool
    private var next: [CatalogWallpaper]
    init(items: [CatalogWallpaper], fails: Bool = false, next: [CatalogWallpaper] = [], failsNext: Bool = false) {
        self.items = items; self.fails = fails; self.next = next; self.failsNext = failsNext
    }
    func loadCachedCatalog() async -> [CatalogWallpaper]? { nil }
    func fetchCatalog() async throws -> [CatalogWallpaper] {
        if fails { throw URLError(.cannotConnectToHost) }
        return items
    }
    func fetchNextCatalogPage() async throws -> CatalogPage {
        if failsNext { throw URLError(.timedOut) }
        let items = next; next = []
        return CatalogPage(wallpapers: items, hasMore: false)
    }
    func searchCatalog(query: String) async throws -> [CatalogWallpaper] {
        items.filter { WallpaperSearchMatcher.matches(query: query, fields: [$0.title, $0.id]) }
    }
    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        URL(string: "https://www.desktophut.com/files/\(wallpaper.id).mp4")!
    }
    func resolveMedia(for wallpaper: CatalogWallpaper) async throws -> CatalogResolvedMedia {
        CatalogResolvedMedia(previewSources: [.init(url: URL(string: "https://www.desktophut.com/\(wallpaper.id)-preview.mp4")!, width: 640, height: 360)],
            originalSources: [.init(url: try await resolveDownloadURL(for: wallpaper), width: 1920, height: 1080)],
            provider: "DesktopHut", validUntil: Date().addingTimeInterval(3600))
    }
}

@Test func musicCatalogShipsReviewedUniqueSelectionsWithoutTrustingBundledFlags() throws {
    let seeds = MusicWallpaperCatalogProvider.bundledSelections()
    #expect(seeds.count >= 300)
    let reviews = MusicCatalogReview.bundled()
    #expect(reviews.count == seeds.count)
    #expect(Set(reviews.values.map(\.originalURL)).count == seeds.count)
    #expect(seeds.allSatisfy { reviews[$0.id]?.matches($0) == true })
    #expect(seeds.allSatisfy(CatalogContentPolicy.allows))
    #expect(Set(seeds.map(\.id)).count == seeds.count)
    #expect(seeds.allSatisfy { $0.hasMusic == nil && $0.sources.isEmpty && $0.previewImageURL != nil && !$0.explicitlyExcludesMusic })
    #expect(seeds.allSatisfy { item in item.sourcePageURL.map { url in
        LearnedAnimeSite.allCases.contains { $0.accepts(url) }
    } == true })
    for item in seeds {
        let page = try #require(item.sourcePageURL)
        let site = try #require(LearnedAnimeSite.allCases.first { $0.accepts(page) })
        #expect(item.id == "\(site.rawValue)-\(page.lastPathComponent)")
    }
}

@Test @MainActor func musicTabRevealsVerifiedSelectionsBeyondTheFirstDisplayPage() {
    let model = CatalogViewModel()
    let unrelated = (0..<30).map { musicCard("ordinary-\($0)") }
    let music = (0..<32).map { index -> CatalogWallpaper in var item = musicCard("sound-\(index)"); item.hasMusic = true; return item }
    model.replaceCatalogForDisplay(with: unrelated + music, hasMoreRemotePages: true)
    #expect(model.wallpapers.count == 12)
    #expect(model.musicCount == 32)
    model.toggleMusic()
    #expect(model.filteredWallpapers == music)
    #expect(model.wallpapers.contains { $0.id == "sound-31" })
    // The remaining ordinary cached cards must not swallow a remote music-page
    // request while leaving the same music trailing card on screen.
    #expect(!model.loadNextDeferredPage())
    #expect(!model.hasDeferredWallpapers)
    #expect(model.hasMoreWallpapers)
    model.replaceCatalogForDisplay(with: unrelated + music, hasMoreRemotePages: true)
    #expect(model.filteredWallpapers == music)
}

@Test func musicCatalogChecksLargerPagesWithFourConcurrentProbesAtMost() async throws {
    let items = (0..<30).map { musicCard("sound-\($0)") }
    let tracker = MusicConcurrencyTracker()
    let provider = MusicWallpaperCatalogProvider(entries: [.init(site: .desktophut,
        provider: MusicFixtureSource(items: items), seeds: [])], directory: nil,
        verifyAudio: { _, _ in await tracker.inspect() })
    #expect(try await provider.fetchCatalog().count == 16)
    #expect(try await provider.fetchNextCatalogPage().wallpapers.count == 14)
    #expect(await tracker.peak <= 4)
    #expect(await tracker.peak > 1)
    #expect(await tracker.total == 30)
}

private actor MusicConcurrencyTracker {
    var active = 0, peak = 0, total = 0
    func inspect() async -> WallpaperAudioContent {
        active += 1; total += 1; peak = max(peak, active)
        try? await Task.sleep(for: .milliseconds(10))
        active -= 1
        return .audible
    }
}

@Test func musicCatalogNextPageKeepsWorkingWhenOneSiteTimesOut() async throws {
    let good = MusicFixtureSource(items: [], next: [musicCard("sound-page")])
    let bad = MusicFixtureSource(items: [], failsNext: true)
    let provider = MusicWallpaperCatalogProvider(entries: [
        .init(site: .desktophut, provider: good, seeds: []),
        .init(site: .livewallpapers4free, provider: bad, seeds: []),
    ], directory: nil, verifyAudio: { _, _ in .audible })
    #expect(try await provider.fetchCatalog().isEmpty)
    let page = try await provider.fetchNextCatalogPage()
    #expect(page.wallpapers.map(\.id) == ["sound-page"])
    #expect(page.hasMore) // the failed source can be retried on the next request
}
