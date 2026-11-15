import AuraWallpaperCore
import CryptoKit
import Foundation
import Testing
@testable import WallpaperControlApp

private actor SoundtrackRequests {
    var count = 0
    func record() { count += 1 }
}

@Test func catalogSoundtrackDownloadsOnceChecksFingerprintAndSurvivesCacheDeletion() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let data = Data("verified test audio".utf8)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let track = CatalogSoundtrack(id: "fixture", title: "Fixture", author: "Fixture",
        page: URL(string: "https://example.test/credit")!, url: URL(string: "https://example.test/track.mp3")!, bytes: data.count, sha256: digest)
    let calls = SoundtrackRequests()
    let cache = CatalogSoundtrackCache(tracks: [track], directory: root.appendingPathComponent("cache"),
        download: { _ in await calls.record(); return data }, inspect: { _ in .audible })
    let files = try await withThrowingTaskGroup(of: URL.self) { group in
        for _ in 0..<32 { group.addTask { try await cache.file(for: "fixture") } }
        var files: [URL] = []
        for try await file in group { files.append(file) }
        return files
    }
    #expect(Set(files).count == 1)
    #expect(await calls.count == 1)
    let video = root.appendingPathComponent("wallpaper.mp4")
    try Data("unchanged video".utf8).write(to: video)
    try WallpaperAudioAttachment.install(files[0], for: video)
    try WallpaperAudioAttachment.install(files[0], for: video)
    let replacement = root.appendingPathComponent("replacement.mp3")
    try Data("different track".utf8).write(to: replacement)
    try WallpaperAudioAttachment.install(replacement, for: video)
    #expect(try String(contentsOf: WallpaperAudioAttachment.source(for: video)) == "different track")
    try WallpaperAudioAttachment.install(files[0], for: video)
    try FileManager.default.removeItem(at: files[0].deletingLastPathComponent())
    #expect(try Data(contentsOf: WallpaperAudioAttachment.source(for: video)) == data)
    #expect(try String(contentsOf: video) == "unchanged video")
    WallpaperAudioAttachment.remove(for: video)
    #expect(WallpaperAudioAttachment.source(for: video) == video)

    let corrupt = CatalogSoundtrackCache(tracks: [track], directory: root.appendingPathComponent("bad"),
        download: { _ in Data("HTML instead of audio".utf8) }, inspect: { _ in .audible })
    await #expect(throws: (any Error).self) { try await corrupt.file(for: "fixture") }
    await #expect(throws: (any Error).self) { try await corrupt.file(for: "unlisted") }
    let silent = CatalogSoundtrackCache(tracks: [track], directory: root.appendingPathComponent("silent"),
        download: { _ in data }, inspect: { _ in .silent })
    await #expect(throws: (any Error).self) { try await silent.file(for: "fixture") }
}

@Test @MainActor func catalogSoundtrackUpdatesSilentVideoBadgeAndDownloadedMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let video = root.appendingPathComponent("silent.mp4")
    let silent = try #require(Bundle.module.url(forResource: "wallpaper-without-audio", withExtension: "mp4"))
    let sound = try #require(Bundle.module.url(forResource: "wallpaper-with-audio", withExtension: "mp4"))
    try FileManager.default.copyItem(at: silent, to: video)
    let metadata = CatalogAudioMetadata(provider: SoundtrackNoNetwork(), coordinator: CatalogTransferCoordinator(), cacheURL: root.appendingPathComponent("audio.json"))
    await metadata.inspectLocal(id: "pair", url: video)
    #expect(metadata.audio["pair"] == false)
    try WallpaperAudioAttachment.install(sound, for: video)
    await metadata.inspectLocal(id: "pair", url: video)
    #expect(metadata.audio["pair"] == true)
    WallpaperAudioAttachment.remove(for: video)
    await metadata.inspectLocal(id: "pair", url: video)
    #expect(metadata.audio["pair"] == false)
    var card = CatalogWallpaper(id: "pair", title: "Nature", category: "Scenic", attribution: "Fixture", previewImageURL: nil, sourcePageURL: nil, sources: [])
    card.soundtrackID = "cozy-piano"; card.hasMusic = true
    let repository = CatalogRepository(provider: SoundtrackNoNetwork(), catalogDirectoryURL: root)
    let result = repository.registerDownloadedWallpaper(card, localURL: video, existing: [])
    #expect(result.wallpapers.first?.soundtrackID == "cozy-piano")
    let merged = CatalogWallpaperMerge.combining([CatalogWallpaper(id: "pair", title: "Nature", category: "Scenic", attribution: "Fixture", previewImageURL: nil, sourcePageURL: nil, sources: [])], [card])
    #expect(merged.first?.soundtrackID == "cozy-piano")
}

@Test func musicCatalogAuditBundledSoundtracksAreAudible() async throws {
    guard let path = ProcessInfo.processInfo.environment["AURAFLOW_SOUNDTRACK_AUDIT_DIRECTORY"] else { return }
    let cache = CatalogSoundtrackCache(directory: URL(fileURLWithPath: path), download: { _ in throw URLError(.notConnectedToInternet) })
    for track in CatalogSoundtracks.all {
        let file = try await cache.file(for: track.id)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

private struct SoundtrackNoNetwork: WallpaperCatalogProviding {
    func loadCachedCatalog() async -> [CatalogWallpaper]? { nil }
    func fetchCatalog() async throws -> [CatalogWallpaper] { [] }
    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL { throw URLError(.notConnectedToInternet) }
}

@Test @MainActor func musicCatalogMergedWithOrdinarySourcesRetainsEverySoundtrackAndCard() async throws {
    let seeds = MusicWallpaperCatalogProvider.bundledSelections()
    let audible = seeds.map { card in var card = card; card.hasMusic = true; return card }
    let silent = seeds.map { card in var card = card; card.soundtrackID = nil; return card }
    let empty = MockCatalogProvider(wallpapers: [])
    let provider = ManagedWallpaperCatalogProvider(animeProvider: MockCatalogProvider(wallpapers: silent),
        animeNatureProvider: empty, scenicProvider: empty, musicProvider: MockCatalogProvider(wallpapers: audible), curatedCatalog: [])
    let result = try await provider.fetchCatalog()
    #expect(result.count == seeds.count)
    #expect(result.filter { $0.soundtrackID != nil }.count == seeds.filter { $0.soundtrackID != nil }.count)
    let model = CatalogViewModel()
    model.replaceCatalogForDisplay(with: result, hasMoreRemotePages: false)
    model.hasMoreMusicWallpapers = false
    model.toggleMusic()
    #expect(model.filteredWallpapers.count == seeds.count)
    #expect(!model.canLoadMore)
}

@Test func catalogSoundtrackInstallsForFreshAndCachedVideoWithoutDownloadingItAgain() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let audio = root.appendingPathComponent("fixture.mp3")
    try Data("shared track".utf8).write(to: audio)
    let calls = SoundtrackRequests()
    let service = CatalogDownloadService(provider: SoundtrackNoNetwork(), catalogDirectoryURL: root,
        fileDownloader: { request, _ in
            await calls.record()
            let temporary = root.appendingPathComponent("transfer.mp4")
            try Data("original video".utf8).write(to: temporary)
            return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "video/mp4"])!)
        }, soundtrackFile: { _ in audio })
    let source = CatalogVideoSource(url: URL(string: "https://www.desktophut.com/original.mp4")!, width: 1920, height: 1080)
    var card = CatalogWallpaper(id: "fixture", title: "Forest", category: "Anime Nature", attribution: "DesktopHut",
        previewImageURL: nil, sourcePageURL: URL(string: "https://www.desktophut.com/forest"), sources: [source])
    card.soundtrackID = "cozy-piano"
    let video = try await service.download(card, preferredSources: [source])
    #expect(try String(contentsOf: WallpaperAudioAttachment.source(for: video)) == "shared track")
    WallpaperAudioAttachment.remove(for: video)
    #expect(try await service.download(card, preferredSources: [source]) == video)
    #expect(try String(contentsOf: WallpaperAudioAttachment.source(for: video)) == "shared track")
    #expect(await calls.count == 1)
    #expect(try String(contentsOf: video) == "original video")
}

@Test @MainActor func musicCatalogPairedCollectionDrainsWithoutProbingSilentVideosOrRespectingOldSilence() async throws {
    let cards = (0..<320).map { index in
        CatalogWallpaper(id: "paired-\(index)", title: "Forest \(index)", category: "Anime Nature", attribution: "DesktopHut",
            previewImageURL: nil, sourcePageURL: URL(string: "https://www.desktophut.com/paired-\(index)"), sources: [], soundtrackID: "cozy-piano")
    }
    let provider = MusicWallpaperCatalogProvider(entries: [.init(site: .desktophut, provider: SoundtrackNoNetwork(), seeds: cards, curatedOnly: true)],
        directory: nil, verifySoundtrack: { _ in }, verifyAudio: { _, _ in throw URLError(.notConnectedToInternet) })
    let loaded = try await provider.fetchCatalog()
    #expect(loaded.count == 320 && loaded.allSatisfy { $0.hasMusic == true })
    #expect(await provider.hasMoreMusicCatalogPages() == false)
    let model = CatalogViewModel()
    model.setWallpapersDirectly(loaded)
    model.audioStatus = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, false) })
    model.toggleMusic()
    #expect(model.filteredWallpapers.count == 320)
}
