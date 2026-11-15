import Foundation
import Testing
@testable import WallpaperControlApp

@Suite(.serialized)
struct MusicCatalogLoadingTests {
    @Test func coldReviewedCollectionLoadsBeyondTheFirstBatchWithoutScrolling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = reviewedMusicCards(320)
        let source = ReviewedMusicSource()
        let probe = ReviewedMusicProbe()
        let provider = MusicWallpaperCatalogProvider(entries: [.init(site: .desktophut,
            provider: source, seeds: cards, curatedOnly: true)], directory: root,
            verifyAudio: { url, _ in try await probe.inspect(url) })
        let result = try await provider.fetchCatalog()
        #expect(result.count == 320)
        #expect(result.allSatisfy { $0.hasMusic == true })
        #expect(await provider.loadCachedCatalog()?.count == 320)
        #expect(await probe.peak <= 4)
        #expect(await probe.total == 320)
        #expect(!(await provider.hasMoreMusicCatalogPages()))
        // Search used to silently cut a matching reviewed collection at 16/site.
        #expect(try await provider.searchCatalog(query: "Wallpaper").count == 320)
        #expect(await probe.total == 320)
        #expect(await source.discoveryRequests == 0)
    }

    @Test func outOfOrderProbesDoNotInsertCardsBeforePublishedResults() async throws {
        let progress = ReviewedMusicProgress()
        let cards = reviewedMusicCards(16)
        let provider = MusicWallpaperCatalogProvider(entries: [.init(site: .desktophut,
            provider: ReviewedMusicSource(), seeds: cards, curatedOnly: true)], directory: nil,
            verifyAudio: { url, _ in
                if url.lastPathComponent == "reviewed-audio-0.mp4" { try await Task.sleep(for: .milliseconds(50)) }
                return .audible
            })
        let result = try await provider.fetchCatalog(progress: { await progress.append($0.map(\.id)) })
        #expect(result.map(\.id) == cards.map(\.id))
        let snapshots = await progress.snapshots
        #expect(!snapshots.isEmpty)
        for pair in zip(snapshots, snapshots.dropFirst()) { #expect(pair.1.starts(with: pair.0)) }
    }

    @Test func nextPageInitializesAnUnstartedReviewedProvider() async throws {
        let provider = MusicWallpaperCatalogProvider(entries: [.init(site: .desktophut,
            provider: ReviewedMusicSource(), seeds: reviewedMusicCards(60), curatedOnly: true)],
            directory: nil, verifyAudio: { _, _ in .audible })
        let page = try await provider.fetchNextMusicCatalogPage()
        #expect(page.wallpapers.count == 60)
        #expect(!page.hasMore)
    }

    @Test func inconclusiveAndFailedAudioProbesKeepTheirCandidatesForRetry() async throws {
        for inconclusive in [false, true] {
            let probe = ReviewedMusicProbe(failFirstAfter: 20, inconclusive: inconclusive)
            let provider = MusicWallpaperCatalogProvider(entries: [.init(site: .desktophut,
                provider: ReviewedMusicSource(), seeds: reviewedMusicCards(60), curatedOnly: true)],
                directory: nil, verifyAudio: { url, _ in try await probe.inspect(url) })
            let initial = try await provider.fetchCatalog()
            #expect(initial.count == 20)
            #expect(await provider.hasMoreMusicCatalogPages())
            var ids = Set(initial.map(\.id))
            for _ in 0..<3 {
                let page = try await provider.fetchNextCatalogPage()
                ids.formUnion(page.wallpapers.map(\.id))
            }
            #expect(ids.count == 60)
            #expect(!(await provider.hasMoreMusicCatalogPages()))
            #expect(await probe.peak <= 4)
        }
    }

    @Test func repeatedFailuresReportRetryRatherThanAFalseEndOfCollection() async throws {
        let probe = ReviewedMusicProbe(alwaysUnavailable: true)
        let provider = MusicWallpaperCatalogProvider(entries: [.init(site: .desktophut,
            provider: ReviewedMusicSource(), seeds: reviewedMusicCards(3), curatedOnly: true)],
            directory: nil, verifyAudio: { url, _ in try await probe.inspect(url) })
        #expect(try await provider.fetchCatalog().isEmpty)
        await #expect(throws: (any Error).self) { try await provider.fetchNextCatalogPage() }
        #expect(await provider.hasMoreMusicCatalogPages())
        #expect(await probe.total == 6)
        await probe.restoreConnection()
        #expect(try await provider.fetchNextCatalogPage().wallpapers.count == 3)
        #expect(!(await provider.hasMoreMusicCatalogPages()))
    }

    @Test @MainActor func coldMusicTabReceivesTheWholeCollectionWithoutRowAppearanceEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ReviewedMusicProbe()
        let music = MusicWallpaperCatalogProvider(entries: [.init(site: .desktophut,
            provider: ReviewedMusicSource(), seeds: reviewedMusicCards(320), curatedOnly: true)],
            directory: nil, verifyAudio: { url, _ in try await probe.inspect(url) })
        let empty = MockCatalogProvider(wallpapers: [])
        let managed = ManagedWallpaperCatalogProvider(animeProvider: empty, animeNatureProvider: empty,
            scenicProvider: empty, musicProvider: music, curatedCatalog: [])
        let model = AppViewModel(controller: MockNativeWallpaperController(), catalogProvider: managed,
            appSupportDirectoryURL: root)
        model.openCatalogFromMenuBar()
        model.toggleCatalogMusic()
        try await waitForMusicPagingModel(model)
        #expect(model.filteredCatalogWallpapers.count == 320)
        #expect(model.catalogViewModel.musicCount == 320)
        #expect(!model.catalogViewModel.canLoadMore)
        #expect(!model.catalogViewModel.loadMoreFailed)
        #expect(await probe.total == 320)
    }
}

private func reviewedMusicCards(_ count: Int) -> [CatalogWallpaper] {
    (0..<count).map { index in
        CatalogWallpaper(id: "reviewed-audio-\(index)", title: "Wallpaper \(index)", category: "Anime",
            attribution: "DesktopHut", previewImageURL: nil,
            sourcePageURL: URL(string: "https://www.desktophut.com/reviewed-audio-\(index)"), sources: [])
    }
}

private actor ReviewedMusicSource: WallpaperCatalogProviding {
    var discoveryRequests = 0
    func loadCachedCatalog() async -> [CatalogWallpaper]? { nil }
    func fetchCatalog() async throws -> [CatalogWallpaper] { discoveryRequests += 1; return [] }
    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL {
        URL(string: "https://www.desktophut.com/files/\(wallpaper.id).mp4")!
    }
}

private actor ReviewedMusicProbe {
    let failFirstAfter: Int?
    let inconclusive: Bool
    private var unavailable: Bool
    private var attempts: [String: Int] = [:]
    var active = 0, peak = 0, total = 0
    init(failFirstAfter: Int? = nil, inconclusive: Bool = false, alwaysUnavailable: Bool = false) {
        self.failFirstAfter = failFirstAfter; self.inconclusive = inconclusive; unavailable = alwaysUnavailable
    }
    func restoreConnection() { unavailable = false }
    func inspect(_ url: URL) async throws -> WallpaperAudioContent {
        let key = url.deletingPathExtension().lastPathComponent
        attempts[key, default: 0] += 1
        let attempt = attempts[key, default: 0]
        active += 1; total += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(2))
        let index = Int(key.split(separator: "-").last ?? "0") ?? 0
        if unavailable || (failFirstAfter.map { index >= $0 && attempt == 1 } ?? false) {
            if inconclusive { return .unknown }
            throw URLError(.timedOut)
        }
        return .audible
    }
}

private actor ReviewedMusicProgress {
    var snapshots: [[String]] = []
    func append(_ ids: [String]) { snapshots.append(ids) }
}
