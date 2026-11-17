import AVFoundation
import Foundation
import Testing
@testable import AuraWallpaperCore
@testable import WallpaperControlApp

@Test func wallpaperAudioPolicyNormalizesAndPreventsDuplicateSound() {
    #expect(WallpaperAudioPolicy.normalized(.nan) == 0)
    #expect(WallpaperAudioPolicy.normalized(.infinity) == 0)
    #expect(WallpaperAudioPolicy.normalized(-1) == 0)
    #expect(WallpaperAudioPolicy.normalized(2) == 1)
    #expect(WallpaperAudioPolicy.previewVolume(0.4, desktopOwnsAudio: true, visible: true) == 0)
    #expect(WallpaperAudioPolicy.previewVolume(0.4, desktopOwnsAudio: false, visible: false) == 0)
    #expect(WallpaperAudioPolicy.previewVolume(0.4, desktopOwnsAudio: false, visible: true) == 0.4)
    #expect(WallpaperAudioPolicy.previewVolume(0.4, desktopOwnsAudio: false, visible: true, systemLocked: true) == 0)
}

@Test(arguments: ["manual-lock", "os-lock", "idle-before-password", "delayed-notification", "missing-notification", "sleep-wake", "lock-only"])
func wallpaperAudioSessionTransitionsRemainSilentUntilDesktopReturns(scenario: String) {
    var locked = false
    var inactive = false
    var sleeping = false
    var saver = false
    let lockOnly = scenario == "lock-only"
    func volume() -> Float {
        WallpaperAudioPolicy.desktopVolume(0.6, lockScreenOnly: lockOnly, sessionInactive: inactive,
            systemLocked: locked, sleeping: sleeping, screenSaverActive: saver)
    }
    #expect(volume() == (lockOnly ? 0 : 0.6))
    if scenario == "idle-before-password" { saver = true; #expect(volume() == 0) }
    if scenario == "sleep-wake" { sleeping = true; #expect(volume() == 0) }
    locked = true
    #expect(volume() == 0)
    if scenario != "missing-notification" { inactive = true }
    sleeping = false
    #expect(volume() == 0, "Wake must not unmute an OS-locked session")
    locked = false
    if inactive { #expect(volume() == 0, "Wait for the shared unlock state") }
    inactive = false; saver = false
    #expect(volume() == (lockOnly ? 0 : 0.6))
    #expect(WallpaperAudioPolicy.desktopVolume(0.6, lockScreenOnly: false, sessionInactive: false,
        systemLocked: false, sleeping: false, paused: true) == 0)
}

@Test(arguments: [true, false])
func wallpaperAudioMP4DetectionMatchesActualTracks(audio: Bool) async throws {
    let url = try audioFixture(audio)
    let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
    #expect(!tracks.isEmpty == audio)
    let data = try Data(contentsOf: url)
    #expect(MP4AudioMetadata.scan(data, offset: 0, total: Int64(data.count)) == .result(audio))
}

@Test func wallpaperAudioMetadataSeeksPastMoviePayloadAndRejectsCorruptHeaders() throws {
    let data = try Data(contentsOf: audioFixture(true))
    // Keep the real moov from ffmpeg, move it behind an un-fetched 8 MiB mdat.
    let bytes = [UInt8](data)
    var start = 0
    var movie = Data()
    while start + 8 <= bytes.count {
        let size = bytes[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) }
        guard size >= 8, start + size <= bytes.count else { break }
        if String(bytes: bytes[(start + 4)..<(start + 8)], encoding: .ascii) == "moov" { movie = Data(bytes[start..<(start + size)]); break }
        start += size
    }
    #expect(!movie.isEmpty)
    var header = Data([0, 128, 0, 0])
    header.append(Data("mdat".utf8))
    #expect(MP4AudioMetadata.scan(header, offset: 0, total: Int64(8 * 1024 * 1024 + movie.count)) == .next(Int64(8 * 1024 * 1024)))
    #expect(MP4AudioMetadata.scan(movie, offset: 8 * 1024 * 1024, total: Int64(8 * 1024 * 1024 + movie.count)) == .result(true))
    #expect(MP4AudioMetadata.scan(Data(movie.prefix(16)), offset: 0, total: Int64(movie.count)) == .movie(0, movie.count))
    #expect(MP4AudioMetadata.scan(Data("<html>blocked</html>".utf8), offset: 0, total: nil) == .unknown)
    #expect(MP4AudioMetadata.scan(Data([0, 0, 0, 4]) + Data("moov".utf8), offset: 0, total: 8) == .unknown)
    #expect(MP4AudioMetadata.scan(Data([0, 0, 0, 1]) + Data("mdat".utf8) + Data(repeating: 255, count: 8), offset: 0, total: nil) == .unknown)
}

@Test @MainActor func wallpaperAudioLocalMetadataPersistsForCatalogBadges() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("audio.json")
    let model = CatalogAudioMetadata(provider: NoAudioNetworkProvider(), coordinator: CatalogTransferCoordinator(), cacheURL: url)
    await model.inspectLocal(id: "music", url: try audioFixture(true))
    await model.inspectLocal(id: "silent", url: try audioFixture(false))
    #expect(model.audio["music"] == true)
    #expect(model.audio["silent"] == false)
    let restored = CatalogAudioMetadata(provider: NoAudioNetworkProvider(), coordinator: CatalogTransferCoordinator(), cacheURL: url)
    #expect(restored.audio == model.audio)
    restored.clear()
    #expect(restored.audio.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test(arguments: [true, false])
func wallpaperAudioSurvivesFrameBlending(audio: Bool) async throws {
    let executable = audioFFmpegURL()
    guard let executable else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = try await VideoFrameBlendCache(appSupportURL: root).prepare(audioFixture(audio), ffmpegURL: executable)
    let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
    #expect(!tracks.isEmpty == audio)
}

@Test func wallpaperAudioOverlayFitsNarrowAndWideWindows() {
    for width in [480.0, 640.0, 900.0, 1500.0] {
        let total = WallpaperPlaybackOverlayLayout.width(available: width, includesVolume: true)
        #expect(total <= width)
        #expect((total - 12) * 0.43 > 190)
    }
}

private func audioFixture(_ audio: Bool) throws -> URL {
    try #require(Bundle.module.url(forResource: audio ? "wallpaper-with-audio" : "wallpaper-without-audio", withExtension: "mp4"))
}

@Test func wallpaperAudioContentDistinguishesSilentTracksAndDelayedMusic() async throws {
    for (name, expected) in [("wallpaper-with-audio", WallpaperAudioContent.audible),
                             ("wallpaper-with-silent-track", .silent),
                             ("wallpaper-without-audio", .noTrack),
                             ("wallpaper-with-delayed-audio", .audible)] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "mp4"))
        let content = try await WallpaperAudioInspector.inspect(url: url)
        #expect(content == expected)
    }
}

@Test func wallpaperAudioSamplePlanRejectsMalformedTables() throws {
    let data = try Data(contentsOf: audioFixture(true))
    let tag = try #require(data.range(of: Data("moov".utf8)))
    let start = tag.lowerBound - 4
    let size = data[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) }
    let movie = data.subdata(in: start..<(start + size))
    let plan = try #require(MP4AudioSamplePlan(movie: movie))
    #expect(plan.chunks.count <= 6)
    #expect(plan.chunks.reduce(0) { $0 + $1.size } <= MP4AudioSamplePlan.maximumAudioBytes)
    for name in ["stsc", "stts"] {
        var broken = movie
        let field = try #require(broken.range(of: Data(name.utf8), options: .backwards))
        broken.replaceSubrange((field.lowerBound + 8)..<(field.lowerBound + 12), with: repeatElement(UInt8(255), count: 4))
        #expect(MP4AudioSamplePlan(movie: broken) == nil)
    }
}

@Test @MainActor func wallpaperAudioSilentTrackDoesNotAdvertiseMusicOrTrustOldCache() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cache = root.appendingPathComponent("audio.json")
    let old: [String: Any] = ["empty-aac": ["hasAudio": true, "expires": Date().addingTimeInterval(86400).timeIntervalSinceReferenceDate, "source": "https://wallpaper.test/silent"]]
    try JSONSerialization.data(withJSONObject: old).write(to: cache)
    let metadata = CatalogAudioMetadata(provider: NoAudioNetworkProvider(), coordinator: CatalogTransferCoordinator(), cacheURL: cache)
    #expect(metadata.audio["empty-aac"] == nil)
    let url = try #require(Bundle.module.url(forResource: "wallpaper-with-silent-track", withExtension: "mp4"))
    #expect(!(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)).isEmpty)
    await metadata.inspectLocal(id: "empty-aac", url: url, source: "https://wallpaper.test/silent")
    #expect(metadata.audio["empty-aac"] == false)
    #expect(metadata.localContent[url.standardizedFileURL] == .silent)
    let restored = CatalogAudioMetadata(provider: NoAudioNetworkProvider(), coordinator: CatalogTransferCoordinator(), cacheURL: cache)
    #expect(restored.audio["empty-aac"] == false)
    #expect(WallpaperAudioContent.silent.isSilent)
    #expect(!WallpaperAudioContent.unknown.isSilent)
}

private func audioFFmpegURL() -> URL? {
    if let path = ProcessInfo.processInfo.environment["AURAFLOW_FFMPEG_PATH"], FileManager.default.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
    }
    return (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        .map { URL(fileURLWithPath: String($0)).appendingPathComponent("ffmpeg") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

@Test func wallpaperAudioLiveCatalogMetadata() async throws {
    guard ProcessInfo.processInfo.environment["AURAFLOW_LIVE_AUDIO_METADATA"] == "1" else { return }
    for site in LearnedAnimeSite.allCases {
        let source = LearnedAnimeSource(site: site, cacheDirectory: nil)
        let items = try await source.fetchCatalog()
        for wallpaper in items.prefix(2) {
            let media = try await source.resolveMedia(for: wallpaper)
            let url = try #require(media.originalSources.first?.url)
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let audio = try await MP4AudioMetadata.inspect(url: url, referer: wallpaper.sourcePageURL, session: session)
            #expect(audio != nil)
            print("[audio-metadata-live] \(site.title) | \(wallpaper.title) | audio=\(String(describing: audio))")
        }
    }
}

@Test @MainActor func wallpaperAudioSurvivesVideoOptimization() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = VideoOptimizationSettings(enabled: true, allowAV1PassthroughOnHardwareDecode: true,
        transcodeH264ToHEVC: true, forceSoftwareAV1Encode: false, profile: .balanced)
    let output = try await VideoOptimizer(cacheDirectory: root).optimizeIfNeeded(inputURL: audioFixture(true), settings: settings, progress: { _ in })
    let tracks = try await AVURLAsset(url: output.outputURL).loadTracks(withMediaType: .audio)
    #expect(!tracks.isEmpty)
}

private struct NoAudioNetworkProvider: WallpaperCatalogProviding {
    func loadCachedCatalog() async -> [CatalogWallpaper]? { nil }
    func fetchCatalog() async throws -> [CatalogWallpaper] { [] }
    func resolveDownloadURL(for wallpaper: CatalogWallpaper) async throws -> URL { throw URLError(.notConnectedToInternet) }
}
