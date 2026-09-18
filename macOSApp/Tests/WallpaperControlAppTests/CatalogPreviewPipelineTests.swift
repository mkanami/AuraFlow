import Foundation
import Testing
@testable import WallpaperControlApp

@Suite(.serialized)
struct CatalogPreviewPipelineTests {
@Test func visiblePrefetchResolvesMetadataWithoutDownloadingMedia() async throws {
    CatalogPreviewURLProtocol.configure(statusCode: 206, byteCount: 4_096)
    let session = previewTestSession()
    defer { session.invalidateAndCancel() }
    let resolver = CatalogPreviewResolverSpy()
    let directory = previewTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pipeline = CatalogPreviewPipeline(
        resolver: resolver,
        catalogDirectoryURL: directory,
        session: session,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )
    let wallpaper = previewPipelineWallpaper(id: "metadata-only")

    await pipeline.prefetchMetadata(wallpaper, priority: .visible)
    _ = try await pipeline.resolvedMediaForForegroundDownload(wallpaper)

    #expect(await resolver.callCount == 1)
    #expect(CatalogPreviewURLProtocol.fullRequestCount == 0)
}

@Test func warmedMetadataIsReusedByForegroundDownloadWithoutResolvingAgain() async throws {
    let directory = previewTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let resolver = CatalogMediaResolverSpy()
    let pipeline = CatalogPreviewPipeline(
        resolver: nil,
        mediaResolver: resolver,
        catalogDirectoryURL: directory,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )
    let wallpaper = previewPipelineWallpaper(id: "route-reuse")

    await pipeline.prefetchMetadata(wallpaper, priority: .visible)
    let first = try await pipeline.resolvedMediaForForegroundDownload(wallpaper)
    let second = try await pipeline.resolvedMediaForForegroundDownload(wallpaper)

    #expect(first == second)
    #expect(await resolver.callCount == 1)
}

@Test func resolvedMediaDecodesMetadataCachedBeforeDetailFieldsWereAdded() throws {
    let original = CatalogResolvedMedia(
        previewSources: [],
        originalSources: [],
        provider: "MoeWalls",
        validUntil: Date(timeIntervalSinceReferenceDate: 1_000)
    )
    let encoded = try JSONEncoder().encode(original)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "fileSizeMB")
    object.removeValue(forKey: "framesPerSecond")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(CatalogResolvedMedia.self, from: legacyData)

    #expect(decoded.provider == "MoeWalls")
    #expect(decoded.fileSizeMB == nil)
    #expect(decoded.framesPerSecond == nil)
}

@Test func displayMetadataEnrichmentUpdatesSizeWithoutResolvingRoutesAgain() async throws {
    let directory = previewTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let resolver = CatalogMetadataEnricherSpy(blocksEnrichment: false)
    let pipeline = CatalogPreviewPipeline(
        resolver: nil,
        mediaResolver: resolver,
        catalogDirectoryURL: directory,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )
    let wallpaper = previewPipelineWallpaper(id: "display-metadata")

    let resolved = try await pipeline.resolvedMediaForForegroundDownload(
        wallpaper
    )
    #expect(resolved.fileSizeMB == nil)
    let enriched = try await pipeline.enrichResolvedMediaForDisplay(
        wallpaper,
        resolvedMedia: resolved
    )

    #expect(enriched.fileSizeMB == 17.7)
    #expect(await resolver.resolveCount == 1)
    #expect(await resolver.enrichmentCount == 1)
}

@Test func foregroundDownloadCancelsDisplayMetadataEnrichment() async throws {
    let directory = previewTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let resolver = CatalogMetadataEnricherSpy(blocksEnrichment: true)
    let pipeline = CatalogPreviewPipeline(
        resolver: nil,
        mediaResolver: resolver,
        catalogDirectoryURL: directory,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )
    let wallpaper = previewPipelineWallpaper(id: "cancel-display-metadata")
    let resolved = try await pipeline.resolvedMediaForForegroundDownload(
        wallpaper
    )
    let enrichment = Task {
        try await pipeline.enrichResolvedMediaForDisplay(
            wallpaper,
            resolvedMedia: resolved
        )
    }
    try await waitUntil { await resolver.enrichmentStarted }

    let lease = await pipeline.beginForegroundDownload(for: wallpaper.id)
    await #expect(throws: CancellationError.self) {
        _ = try await enrichment.value
    }
    await pipeline.endForegroundDownload(lease)

    #expect(await resolver.enrichmentCancelled)
}

@Test func foregroundDownloadBlocksPreviewBodiesUntilLeaseEnds() async throws {
    CatalogPreviewURLProtocol.configure(statusCode: 206, byteCount: 4_096)
    let session = previewTestSession()
    defer { session.invalidateAndCancel() }
    let directory = previewTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pipeline = CatalogPreviewPipeline(
        resolver: CatalogPreviewResolverSpy(),
        catalogDirectoryURL: directory,
        session: session,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )
    let wallpaper = previewPipelineWallpaper(id: "foreground-priority")

    let lease = await pipeline.beginForegroundDownload(for: wallpaper.id)
    await pipeline.prefetch(wallpaper, priority: .selected)
    try await Task.sleep(nanoseconds: 250_000_000)
    #expect(CatalogPreviewURLProtocol.fullRequestCount == 0)

    await pipeline.endForegroundDownload(lease)
    _ = try await prepareAndAwaitReady(pipeline, wallpaper: wallpaper)
    #expect(CatalogPreviewURLProtocol.fullRequestCount == 1)
}

@Test func selectedPreviewPreemptsActiveViewportMetadata() async throws {
    let directory = previewTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let resolver = CatalogPreemptibleMediaResolver()
    let pipeline = CatalogPreviewPipeline(
        resolver: nil,
        mediaResolver: resolver,
        catalogDirectoryURL: directory,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )

    for index in 0..<4 {
        await pipeline.prefetchMetadata(
            previewPipelineWallpaper(id: "background-\(index)"),
            priority: .visible
        )
    }
    try await waitUntil { await resolver.activeBackgroundCount == 4 }

    let selected = previewPipelineWallpaper(id: "selected")
    await pipeline.prefetch(selected, priority: .selected)
    try await waitUntil { await resolver.didResolveSelected }

    #expect(await resolver.cancelledBackgroundCount == 4)
}

@Test func motionBGSSelectedPreviewPublishesDirectRouteBeforeMetadataFinishes() async throws {
    let directory = previewTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let resolver = CatalogBlockingMediaResolver()
    let pipeline = CatalogPreviewPipeline(
        resolver: nil,
        mediaResolver: resolver,
        catalogDirectoryURL: directory,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )
    let wallpaper = CatalogWallpaper(
        id: "motion-fast-route",
        title: "Fast Route",
        category: "Anime Nature",
        attribution: "MotionBGS",
        previewImageURL: URL(
            string: "https://motionbgs.com/i/c/364x205/media/9964/summer-mountain-paradise.3840x2160.jpg"
        ),
        sourcePageURL: URL(string: "https://motionbgs.com/summer-mountain-paradise"),
        sources: []
    )

    let stream = await pipeline.events(for: wallpaper)
    let directURL = try await firstDirectURL(stream)
    await pipeline.confirmDirectPlayback(wallpaperID: wallpaper.id, url: directURL)

    #expect(
        directURL.absoluteString ==
            "https://motionbgs.com/media/9964/summer-mountain-paradise.960x540.mp4"
    )
    #expect(await resolver.isStillResolving)
}

@Test func moeWallsSelectedPreviewBuildsAQuickRangeSampleInsteadOfWaitingForWebKit() async throws {
    CatalogPreviewURLProtocol.configure(statusCode: 206, byteCount: 4_096)
    let session = previewTestSession()
    defer { session.invalidateAndCancel() }
    let directory = previewTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let resolver = MoeWallsSampleMediaResolver()
    let pipeline = CatalogPreviewPipeline(
        resolver: nil,
        mediaResolver: resolver,
        catalogDirectoryURL: directory,
        session: session,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )
    let wallpaper = CatalogWallpaper(
        id: "moewalls-native-preview",
        title: "Native Preview",
        category: "Anime",
        attribution: "MoeWalls",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://moewalls.com/anime/native-preview/"),
        sources: []
    )

    let readyURL = try await awaitReadyURL(await pipeline.events(for: wallpaper))

    #expect(readyURL != nil)
    #expect(CatalogPreviewURLProtocol.requestedRanges == ["bytes=0-2097151"])
}

@Test func movingDirectPreviewCancelsDuplicateMediaDownload() async throws {
    CatalogPreviewURLProtocol.configure(statusCode: 206, byteCount: 4_096)
    let session = previewTestSession()
    defer { session.invalidateAndCancel() }
    let directory = previewTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pipeline = CatalogPreviewPipeline(
        resolver: CatalogPreviewResolverSpy(),
        catalogDirectoryURL: directory,
        session: session,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )
    let wallpaper = previewPipelineWallpaper(id: "direct-winner")

    let directURL = try await firstDirectURL(await pipeline.events(for: wallpaper))
    await pipeline.confirmDirectPlayback(wallpaperID: wallpaper.id, url: directURL)
    try await Task.sleep(nanoseconds: 1_350_000_000)

    #expect(CatalogPreviewURLProtocol.fullRequestCount == 0)
}

@Test func foregroundDownloadReusesSelectedMetadataAlreadyInFlight() async throws {
    let directory = previewTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let resolver = CatalogGateMediaResolver()
    let pipeline = CatalogPreviewPipeline(
        resolver: nil,
        mediaResolver: resolver,
        catalogDirectoryURL: directory,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )
    let wallpaper = previewPipelineWallpaper(id: "foreground-route")

    await pipeline.prefetch(wallpaper, priority: .selected)
    try await waitUntil { await resolver.callCount == 1 }
    let lease = await pipeline.beginForegroundDownload(for: wallpaper.id)
    let mediaTask = Task { try await pipeline.resolvedMediaForForegroundDownload(wallpaper) }
    await resolver.release()
    _ = try await mediaTask.value
    await pipeline.endForegroundDownload(lease)

    #expect(await resolver.callCount == 1)
}

@Test func catalogPreviewPipelineDeduplicatesPreparationAndReusesDiskCache() async throws {
    CatalogPreviewURLProtocol.configure(statusCode: 206, byteCount: 4_096)
    let session = previewTestSession()
    defer { session.invalidateAndCancel() }
    let resolver = CatalogPreviewResolverSpy()
    let directory = previewTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pipeline = CatalogPreviewPipeline(
        resolver: resolver,
        catalogDirectoryURL: directory,
        session: session,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )
    let wallpaper = previewPipelineWallpaper(id: "deduplicated")

    async let first = awaitReadyURL(await pipeline.events(for: wallpaper))
    async let second = awaitReadyURL(await pipeline.events(for: wallpaper))
    await pipeline.requestPreparedFallback(for: wallpaper)
    let urls = try await [first, second]

    #expect(urls[0] == urls[1])
    #expect(await resolver.callCount == 1)
    #expect(CatalogPreviewURLProtocol.fullRequestCount == 1)

    let cachedResult = try await awaitReadyURL(await pipeline.events(for: wallpaper))
    let cached = try #require(cachedResult)
    #expect(cached == urls[0])
    #expect(await resolver.callCount == 1)
}

@Test func catalogPreviewPipelineFailureFinishesWithPosterFallback() async throws {
    CatalogPreviewURLProtocol.configure(statusCode: 404, byteCount: 0)
    let session = previewTestSession()
    defer { session.invalidateAndCancel() }
    let directory = previewTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pipeline = CatalogPreviewPipeline(
        resolver: CatalogPreviewResolverSpy(),
        catalogDirectoryURL: directory,
        session: session,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )

    let wallpaper = previewPipelineWallpaper(id: "failed")
    let stream = await pipeline.events(for: wallpaper)
    await pipeline.requestPreparedFallback(for: wallpaper)
    let event = try await firstTerminalEvent(stream)

    #expect(event == .failed)
}

@Test func catalogPreviewPipelineUsesExistingDownloadedMediaBeforeNetworkResolution() async throws {
    let directory = previewTestDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let wallpaper = previewPipelineWallpaper(id: "already-downloaded")
    let localMedia = directory.appendingPathComponent("already-downloaded-autoxauto.mp4")
    try Data(repeating: 3, count: 4_096).write(to: localMedia)
    let resolver = CatalogPreviewResolverSpy()
    let pipeline = CatalogPreviewPipeline(
        resolver: resolver,
        catalogDirectoryURL: directory,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )

    let directURL = try await firstDirectURL(await pipeline.events(for: wallpaper))

    #expect(directURL.standardizedFileURL == localMedia.standardizedFileURL)
    #expect(await resolver.callCount == 0)
}

@Test func selectedDirectPreviewDoesNotStartABodyBeforeExplicitFallback() async throws {
    CatalogPreviewURLProtocol.configure(statusCode: 206, byteCount: 4_096)
    let session = previewTestSession()
    defer { session.invalidateAndCancel() }
    let directory = previewTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let pipeline = CatalogPreviewPipeline(
        resolver: CatalogPreviewResolverSpy(),
        catalogDirectoryURL: directory,
        session: session,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )
    let wallpaper = previewPipelineWallpaper(id: "explicit-fallback")

    _ = try await firstDirectURL(await pipeline.events(for: wallpaper))
    try await Task.sleep(nanoseconds: 1_350_000_000)
    #expect(CatalogPreviewURLProtocol.fullRequestCount == 0)

    _ = try await prepareAndAwaitReady(pipeline, wallpaper: wallpaper)
    #expect(CatalogPreviewURLProtocol.fullRequestCount == 1)
}

@Test func catalogPreviewPipelineEvictsLeastRecentlyUsedPreparedFile() async throws {
    CatalogPreviewURLProtocol.configure(statusCode: 206, byteCount: 4_096)
    let session = previewTestSession()
    defer { session.invalidateAndCancel() }
    let directory = previewTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = CatalogPreviewPipeline.Configuration(
        maximumCacheBytes: 6_000,
        successfulResolutionLifetime: 86_400,
        failureRetryInterval: 900
    )
    let pipeline = CatalogPreviewPipeline(
        resolver: CatalogPreviewResolverSpy(),
        catalogDirectoryURL: directory,
        session: session,
        configuration: configuration,
        mediaPreparer: CatalogPreviewMediaPreparerStub()
    )

    _ = try await prepareAndAwaitReady(
        pipeline,
        wallpaper: previewPipelineWallpaper(id: "older")
    )
    _ = try await prepareAndAwaitReady(
        pipeline,
        wallpaper: previewPipelineWallpaper(id: "newer")
    )

    let preparedDirectory = directory.appendingPathComponent("PreparedPreviews", isDirectory: true)
    let mp4Files = (try FileManager.default.contentsOfDirectory(
        at: preparedDirectory,
        includingPropertiesForKeys: nil
    )).filter { $0.pathExtension == "mp4" }
    #expect(mp4Files.count == 1)
    #expect(await pipeline.cachedURL(for: "older") == nil)
    #expect(await pipeline.cachedURL(for: "newer") != nil)
}

@Test func catalogPreviewPermitPoolServesSelectedBeforeLookahead() async throws {
    let pool = CatalogPreviewPermitPool(limit: 1)
    try await pool.acquire(priority: .visible)
    let recorder = CatalogPreviewOrderRecorder()

    let lookahead = Task {
        try await pool.acquire(priority: .lookahead)
        await recorder.append("lookahead")
        await pool.release()
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    let selected = Task {
        try await pool.acquire(priority: .selected)
        await recorder.append("selected")
        await pool.release()
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    await pool.release()
    try await lookahead.value
    try await selected.value

    #expect(await recorder.values == ["selected", "lookahead"])
}

@Test func catalogPreviewPermitPoolPromotesQueuedCardAfterSelection() async throws {
    let pool = CatalogPreviewPermitPool(limit: 1)
    try await pool.acquire(priority: .visible)
    let recorder = CatalogPreviewOrderRecorder()

    let promoted = Task {
        try await pool.acquire(priority: .lookahead, key: "promoted")
        await recorder.append("promoted")
        await pool.release()
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    let ordinary = Task {
        try await pool.acquire(priority: .visible, key: "ordinary")
        await recorder.append("ordinary")
        await pool.release()
    }
    try await Task.sleep(nanoseconds: 20_000_000)
    await pool.promote(key: "promoted", to: .selected)
    await pool.release()
    try await promoted.value
    try await ordinary.value

    #expect(await recorder.values == ["promoted", "ordinary"])
}

@Test func catalogPreviewViewportFollowsFastForwardScrollAndDropsOldCards() throws {
    let ids = (0..<60).map { "wallpaper-\($0)" }
    let visible = Set((24...31).map { "wallpaper-\($0)" })
    let plan = try #require(CatalogPreviewViewportPlan.make(
        wallpaperIDs: ids,
        visibleIDs: visible,
        previousCenterIndex: 5
    ))

    #expect(plan.visibleIDs == Array(ids[24...31]))
    #expect(plan.lookaheadIDs.first == "wallpaper-32")
    #expect(plan.lookaheadIDs.contains("wallpaper-39"))
    #expect(!plan.protectedIDs.contains("wallpaper-5"))
    #expect(plan.protectedIDs.count <= 20)
}

@Test func catalogPreviewViewportLooksBackwardWhenUserScrollsUp() throws {
    let ids = (0..<60).map { "wallpaper-\($0)" }
    let visible = Set((20...27).map { "wallpaper-\($0)" })
    let plan = try #require(CatalogPreviewViewportPlan.make(
        wallpaperIDs: ids,
        visibleIDs: visible,
        previousCenterIndex: 45
    ))

    #expect(plan.lookaheadIDs.first == "wallpaper-19")
    #expect(plan.lookaheadIDs.contains("wallpaper-12"))
    #expect(!plan.protectedIDs.contains("wallpaper-45"))
}
}

private actor CatalogPreviewResolverSpy: WallpaperCatalogPreviewResolving {
    private(set) var callCount = 0

    func resolvePreviewSources(for wallpaper: CatalogWallpaper) async throws -> [CatalogVideoSource] {
        callCount += 1
        return wallpaper.sources
    }
}

private actor CatalogMediaResolverSpy: WallpaperCatalogMediaResolving {
    private(set) var callCount = 0

    func resolveMedia(for wallpaper: CatalogWallpaper) async throws -> CatalogResolvedMedia {
        callCount += 1
        return CatalogResolvedMedia(
            previewSources: wallpaper.sources,
            originalSources: wallpaper.sources,
            provider: wallpaper.attribution,
            validUntil: Date().addingTimeInterval(86_400)
        )
    }

    func invalidateResolvedMedia(for wallpaper: CatalogWallpaper) async {}
}

private actor MoeWallsSampleMediaResolver: WallpaperCatalogMediaResolving {
    func resolveMedia(for wallpaper: CatalogWallpaper) async throws -> CatalogResolvedMedia {
        CatalogResolvedMedia(
            previewSources: [
                CatalogVideoSource(
                    url: URL(string: "https://media.example.test/native-preview.webm")!,
                    width: 1280,
                    height: 720
                )
            ],
            originalSources: [],
            provider: "MoeWalls",
            validUntil: Date().addingTimeInterval(86_400)
        )
    }
}

private actor CatalogMetadataEnricherSpy:
    WallpaperCatalogMediaResolving,
    WallpaperCatalogMediaMetadataEnriching
{
    private let blocksEnrichment: Bool
    private(set) var resolveCount = 0
    private(set) var enrichmentCount = 0
    private(set) var enrichmentStarted = false
    private(set) var enrichmentCancelled = false

    init(blocksEnrichment: Bool) {
        self.blocksEnrichment = blocksEnrichment
    }

    func resolveMedia(
        for wallpaper: CatalogWallpaper
    ) async throws -> CatalogResolvedMedia {
        resolveCount += 1
        return resolvedTestMedia(for: wallpaper)
    }

    func enrichMediaMetadata(
        for wallpaper: CatalogWallpaper,
        media: CatalogResolvedMedia
    ) async throws -> CatalogResolvedMedia {
        enrichmentCount += 1
        enrichmentStarted = true
        if blocksEnrichment {
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                enrichmentCancelled = true
                throw error
            }
        }
        return CatalogResolvedMedia(
            previewSources: media.previewSources,
            originalSources: media.originalSources,
            provider: media.provider,
            validUntil: media.validUntil,
            fileSizeMB: 17.7,
            framesPerSecond: media.framesPerSecond
        )
    }
}

private actor CatalogPreemptibleMediaResolver: WallpaperCatalogMediaResolving {
    private(set) var activeBackgroundCount = 0
    private(set) var cancelledBackgroundCount = 0
    private(set) var didResolveSelected = false

    func resolveMedia(for wallpaper: CatalogWallpaper) async throws -> CatalogResolvedMedia {
        if wallpaper.id.hasPrefix("background-") {
            activeBackgroundCount += 1
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                activeBackgroundCount -= 1
                cancelledBackgroundCount += 1
                throw error
            }
        } else {
            didResolveSelected = true
        }
        return resolvedTestMedia(for: wallpaper)
    }
}

private actor CatalogBlockingMediaResolver: WallpaperCatalogMediaResolving {
    private(set) var isStillResolving = false

    func resolveMedia(for wallpaper: CatalogWallpaper) async throws -> CatalogResolvedMedia {
        isStillResolving = true
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return resolvedTestMedia(for: wallpaper)
    }
}

private actor CatalogGateMediaResolver: WallpaperCatalogMediaResolving {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func resolveMedia(for wallpaper: CatalogWallpaper) async throws -> CatalogResolvedMedia {
        callCount += 1
        await withCheckedContinuation { continuation = $0 }
        return resolvedTestMedia(for: wallpaper)
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CatalogPreviewOrderRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private struct CatalogPreviewMediaPreparerStub: CatalogPreviewMediaPreparing {
    func convertToMP4(_ inputURL: URL) async throws -> URL { inputURL }
    func containsPlayableVideo(_ url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

private func previewPipelineWallpaper(id: String) -> CatalogWallpaper {
    CatalogWallpaper(
        id: id,
        title: id,
        category: "Anime",
        attribution: "Test",
        previewImageURL: nil,
        sourcePageURL: URL(string: "https://example.test/card/\(id)")!,
        sources: [
            CatalogVideoSource(
                url: URL(string: "https://media.example.test/\(id).mp4")!,
                width: 960,
                height: 540
            )
        ]
    )
}

private func previewTestDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("AuraFlow-CatalogPreviewTests-\(UUID().uuidString)", isDirectory: true)
}

private func previewTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CatalogPreviewURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func awaitReadyURL(_ stream: AsyncStream<CatalogPreviewEvent>) async throws -> URL? {
    for await event in stream {
        if case let .ready(url) = event { return url }
        if event == .failed { return nil }
    }
    return nil
}

private func prepareAndAwaitReady(
    _ pipeline: CatalogPreviewPipeline,
    wallpaper: CatalogWallpaper
) async throws -> URL? {
    let stream = await pipeline.events(for: wallpaper)
    await pipeline.requestPreparedFallback(for: wallpaper)
    return try await awaitReadyURL(stream)
}

private func firstTerminalEvent(_ stream: AsyncStream<CatalogPreviewEvent>) async throws -> CatalogPreviewEvent {
    for await event in stream where event == .failed || {
        if case .ready = event { return true }
        return false
    }() {
        return event
    }
    throw CancellationError()
}

private func firstDirectURL(_ stream: AsyncStream<CatalogPreviewEvent>) async throws -> URL {
    for await event in stream {
        if case let .direct(url) = event { return url }
        if event == .failed { throw URLError(.resourceUnavailable) }
    }
    throw CancellationError()
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let startedAt = ContinuousClock.now
    while !(await condition()) {
        if ContinuousClock.now - startedAt > .nanoseconds(Int64(timeoutNanoseconds)) {
            throw URLError(.timedOut)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private func resolvedTestMedia(for wallpaper: CatalogWallpaper) -> CatalogResolvedMedia {
    CatalogResolvedMedia(
        previewSources: wallpaper.sources,
        originalSources: wallpaper.sources,
        provider: wallpaper.attribution,
        validUntil: Date().addingTimeInterval(86_400)
    )
}

private final class CatalogPreviewURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responseStatusCode = 206
    private static var responseData = Data(repeating: 7, count: 4_096)
    private static var fullRequests = 0
    private static var ranges: [String] = []

    static var fullRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return fullRequests
    }

    static var requestedRanges: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ranges
    }

    static func configure(statusCode: Int, byteCount: Int) {
        lock.lock()
        responseStatusCode = statusCode
        responseData = Data(repeating: 7, count: byteCount)
        fullRequests = 0
        ranges = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "media.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let statusCode = Self.responseStatusCode
        let data = Self.responseData
        if let range = request.value(forHTTPHeaderField: "Range") {
            Self.ranges.append(range)
        } else {
            Self.fullRequests += 1
        }
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": url.pathExtension == "webm" ? "video/webm" : "video/mp4",
                "Accept-Ranges": "bytes",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
