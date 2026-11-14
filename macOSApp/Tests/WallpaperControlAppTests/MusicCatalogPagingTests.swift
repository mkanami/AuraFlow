import Foundation
import Testing
@testable import WallpaperControlApp

@Suite(.serialized)
struct MusicCatalogPagingTests {
    @Test func refreshPreservesAllPreviouslyVerifiedMusicAndPrioritizesNewCards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let items = (0..<64).map { musicPagingCard("cached-\($0)") }
        let backend = MusicPagingMediaSource(items: items)
        let entry = MusicWallpaperCatalogProvider.Entry(site: .desktophut, provider: backend, seeds: [])
        let provider = MusicWallpaperCatalogProvider(entries: [entry], directory: root, verifyAudio: { _, _ in .audible })
        #expect(try await provider.fetchCatalog().count == 16)
        for _ in 0..<3 { _ = try await provider.fetchNextCatalogPage() }
        #expect(await provider.loadCachedCatalog()?.count == 64)
        let progress = MusicPagingProgress()
        #expect(try await provider.fetchCatalog(progress: { await progress.add($0.count) }).count == 64)
        #expect(await progress.counts.allSatisfy { $0 >= 64 })

        let expanded = MusicPagingMediaSource(items: items + [musicPagingCard("new")])
        let restored = MusicWallpaperCatalogProvider(entries: [.init(site: .desktophut, provider: expanded, seeds: [])],
            directory: root, verifyAudio: { _, _ in .audible })
        let result = try await restored.fetchCatalog()
        #expect(result.count == 65)
        #expect(result.contains { $0.id == "new" })
    }

    @Test func cancelledMusicPageRestoresItsUnprocessedCandidates() async throws {
        let probe = MusicPagingCancellationProbe()
        let provider = MusicWallpaperCatalogProvider(entries: [.init(site: .desktophut,
            provider: MusicPagingMediaSource(items: (0..<3).map { musicPagingCard("item-\($0)") }), seeds: [])],
            directory: nil, batchSize: 1, verifyAudio: { url, _ in try await probe.inspect(url) })
        #expect(try await provider.fetchCatalog().map(\.id) == ["item-0"])
        let pending = Task { try await provider.fetchNextCatalogPage() }
        for _ in 0..<200 {
            if await probe.waiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await probe.waiting)
        pending.cancel()
        do { _ = try await pending.value; Issue.record("The cancelled page must throw") }
        catch { #expect(error is CancellationError) }
        #expect(try await provider.fetchNextCatalogPage().wallpapers.map(\.id) == ["item-1"])
    }

    @Test func refreshedSilenceStillRemovesAnOldCachedMusicClaim() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = MusicWallpaperCatalogProvider.Entry(site: .desktophut,
            provider: MusicPagingMediaSource(items: [musicPagingCard("changed")]), seeds: [])
        let first = MusicWallpaperCatalogProvider(entries: [entry], directory: root, verifyAudio: { _, _ in .audible })
        #expect(try await first.fetchCatalog().count == 1)
        try Data("{}".utf8).write(to: root.appendingPathComponent("verification.json"), options: .atomic)
        let refreshed = MusicWallpaperCatalogProvider(entries: [entry], directory: root, verifyAudio: { _, _ in .silent })
        #expect(try await refreshed.fetchCatalog().isEmpty)
    }

    @Test func repositoryMusicPagingDoesNotAdvanceUnrelatedSites() async throws {
        let ordinary = SequencePagedCatalogProvider(initial: [], pages: [.init(wallpapers: [musicPagingCard("ordinary")], hasMore: true)])
        let music = SequencePagedCatalogProvider(initial: [], pages: [.init(wallpapers: [musicPagingCard("music")], hasMore: false)])
        let empty = MockCatalogProvider(wallpapers: [])
        let managed = ManagedWallpaperCatalogProvider(animeProvider: ordinary, animeNatureProvider: empty,
            scenicProvider: empty, musicProvider: music, curatedCatalog: [])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await CatalogRepository(provider: managed, catalogDirectoryURL: root)
            .loadNextCatalogPage(existing: [], musicOnly: true)
        #expect(result.wallpapers.map(\.id) == ["music"])
        #expect(!result.hasMore)
        #expect(await music.pageRequestCount == 1)
        #expect(await ordinary.pageRequestCount == 0)
    }

    @MainActor @Test func emptyMusicPagesAdvanceWithoutAnotherScrollAndKeepOrdinaryPagingOpen() async throws {
        let first = musicPagingCard("first")
        var ordinary = musicPagingCard("silent"); ordinary.hasMusic = nil
        let source = MusicPagingFixtureSource(initial: [first], pages: [
            .init(wallpapers: [], hasMore: true), .init(wallpapers: [ordinary], hasMore: true),
            .init(wallpapers: [musicPagingCard("next")], hasMore: false),
        ])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppViewModel(controller: MockNativeWallpaperController(), catalogProvider: source, appSupportDirectoryURL: root)
        try await waitForMusicPagingModel(model)
        model.toggleCatalogMusic()
        model.catalogTrailingWallpaperBecameVisible(first.id)
        for _ in 0..<200 where model.catalogViewModel.musicCount < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.filteredCatalogWallpapers.map(\.id) == ["first", "next"])
        #expect(await source.musicRequests == 3)
        #expect(await source.ordinaryRequests == 0)
        #expect(!model.catalogViewModel.canLoadMore)
        model.toggleCatalogMusic()
        #expect(model.catalogViewModel.canLoadMore)
    }

    @MainActor @Test func threeEmptyMusicPagesPauseUntilAnExplicitLoadMore() async throws {
        let first = musicPagingCard("first")
        let source = MusicPagingFixtureSource(initial: [first], pages:
            Array(repeating: .init(wallpapers: [], hasMore: true), count: 4)
            + [.init(wallpapers: [musicPagingCard("next")], hasMore: false)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppViewModel(controller: MockNativeWallpaperController(), catalogProvider: source, appSupportDirectoryURL: root)
        try await waitForMusicPagingModel(model)
        model.toggleCatalogMusic()
        model.catalogTrailingWallpaperBecameVisible(first.id)
        for _ in 0..<200 where !model.catalogViewModel.automaticPaginationPaused { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await source.musicRequests == 3)
        model.catalogTrailingWallpaperBecameVisible(first.id)
        #expect(await source.musicRequests == 3)
        model.loadMoreCatalogWallpapers()
        for _ in 0..<200 where model.catalogViewModel.musicCount < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.catalogViewModel.musicCount == 2)
        #expect(await source.musicRequests == 5)
    }

    @MainActor @Test func expandingCachedCardsCannotExhaustMusicWhileInitialRefreshOwnsTheCursor() async throws {
        let first = musicPagingCard("first")
        let source = MusicPagingFixtureSource(initial: [first], pages: [.init(wallpapers: [musicPagingCard("next")], hasMore: false)])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppViewModel(controller: MockNativeWallpaperController(), catalogProvider: source, appSupportDirectoryURL: root)
        try await waitForMusicPagingModel(model)
        let ordinary = (0..<30).map { i -> CatalogWallpaper in
            var item = musicPagingCard("ordinary-\(i)"); item.hasMusic = nil; return item
        }
        model.catalogViewModel.replaceCatalogForDisplay(with: [first] + ordinary, hasMoreRemotePages: true)
        model.toggleCatalogMusic()
        model.catalogIsRefreshing = true
        model.catalogTrailingWallpaperBecameVisible(first.id)
        try await Task.sleep(for: .milliseconds(80))
        #expect(await source.musicRequests == 0)
        #expect(model.catalogViewModel.hasMoreMusicWallpapers)
        model.catalogIsRefreshing = false
        model.catalogTrailingWallpaperBecameVisible(first.id)
        for _ in 0..<200 where model.catalogViewModel.musicCount < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.catalogViewModel.musicCount == 2)
        #expect(await source.musicRequests == 1)
    }

    @MainActor @Test func failedMusicPageDoesNotRetryInALoopAndCanBeRetriedExplicitly() async throws {
        let source = MusicPagingFixtureSource(initial: [musicPagingCard("first")],
            pages: [.init(wallpapers: [musicPagingCard("next")], hasMore: false)], failFirst: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppViewModel(controller: MockNativeWallpaperController(), catalogProvider: source, appSupportDirectoryURL: root)
        try await waitForMusicPagingModel(model)
        model.toggleCatalogMusic()
        model.loadMoreCatalogWallpapers()
        for _ in 0..<200 where !model.catalogViewModel.loadMoreFailed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.catalogViewModel.automaticPaginationPaused)
        #expect(await source.musicRequests == 1)
        model.loadMoreCatalogWallpapers()
        for _ in 0..<200 where model.catalogViewModel.musicCount < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.catalogViewModel.loadMoreFailed)
        #expect(model.catalogViewModel.musicCount == 2)
        #expect(await source.musicRequests == 2)
    }
}

func musicPagingCard(_ id: String) -> CatalogWallpaper {
    var card = CatalogWallpaper(id: id, title: id, category: "Anime", attribution: "DesktopHut",
        previewImageURL: nil, sourcePageURL: URL(string: "https://www.desktophut.com/\(id)"), sources: [])
    card.hasMusic = true
    return card
}

@MainActor func waitForMusicPagingModel(_ model: AppViewModel) async throws {
    for _ in 0..<200 {
        if !model.catalogWallpapers.isEmpty && !model.catalogIsRefreshing { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!model.catalogWallpapers.isEmpty && !model.catalogIsRefreshing)
}

actor MusicPagingFixtureSource: WallpaperCatalogProviding, WallpaperCatalogPaging, WallpaperCatalogMusicPaging {
    let initial: [CatalogWallpaper]
    private var pages: [CatalogPage]
    private var failFirst: Bool
    private(set) var musicRequests = 0, ordinaryRequests = 0
    init(initial: [CatalogWallpaper], pages: [CatalogPage], failFirst: Bool = false) {
        self.initial = initial; self.pages = pages; self.failFirst = failFirst
    }
    func loadCachedCatalog() async -> [CatalogWallpaper]? { initial }
    func fetchCatalog() async throws -> [CatalogWallpaper] { initial }
    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL { throw URLError(.fileDoesNotExist) }
    func fetchNextCatalogPage() async throws -> CatalogPage {
        ordinaryRequests += 1
        return .init(wallpapers: [], hasMore: true)
    }
    func fetchNextMusicCatalogPage() async throws -> CatalogPage {
        musicRequests += 1
        try await Task.sleep(for: .milliseconds(15))
        if failFirst { failFirst = false; throw URLError(.timedOut) }
        return pages.isEmpty ? .init(wallpapers: [], hasMore: false) : pages.removeFirst()
    }
}

private actor MusicPagingProgress {
    var counts: [Int] = []
    func add(_ count: Int) { counts.append(count) }
}

private actor MusicPagingCancellationProbe {
    private var blockedOnce = false
    private(set) var waiting = false
    func inspect(_ url: URL) async throws -> WallpaperAudioContent {
        if url.deletingPathExtension().lastPathComponent == "item-1", !blockedOnce {
            blockedOnce = true; waiting = true
            defer { waiting = false }
            try await Task.sleep(for: .seconds(60))
        }
        return .audible
    }
}

private actor MusicPagingMediaSource: WallpaperCatalogProviding, WallpaperCatalogPaging {
    let items: [CatalogWallpaper]
    init(items: [CatalogWallpaper]) { self.items = items }
    func loadCachedCatalog() async -> [CatalogWallpaper]? { nil }
    func fetchCatalog() async throws -> [CatalogWallpaper] { items }
    func fetchNextCatalogPage() async throws -> CatalogPage { .init(wallpapers: [], hasMore: false) }
    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        URL(string: "https://www.desktophut.com/files/\(wallpaper.id).mp4")!
    }
}
