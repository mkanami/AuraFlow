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

    let lease = await pipeline.beginForegroundDownload()
    await pipeline.prefetch(wallpaper, priority: .selected)
    try await Task.sleep(nanoseconds: 250_000_000)
    #expect(CatalogPreviewURLProtocol.fullRequestCount == 0)

    await pipeline.endForegroundDownload(lease)
    _ = try await awaitReadyURL(await pipeline.events(for: wallpaper))
    #expect(CatalogPreviewURLProtocol.fullRequestCount == 1)
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

    let event = try await firstTerminalEvent(
        await pipeline.events(for: previewPipelineWallpaper(id: "failed"))
    )

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

    let readyURL = try await awaitReadyURL(await pipeline.events(for: wallpaper))

    #expect(readyURL != nil)
    #expect(await resolver.callCount == 0)
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

    _ = try await awaitReadyURL(await pipeline.events(for: previewPipelineWallpaper(id: "older")))
    _ = try await awaitReadyURL(await pipeline.events(for: previewPipelineWallpaper(id: "newer")))

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

private func firstTerminalEvent(_ stream: AsyncStream<CatalogPreviewEvent>) async throws -> CatalogPreviewEvent {
    for await event in stream where event == .failed || {
        if case .ready = event { return true }
        return false
    }() {
        return event
    }
    throw CancellationError()
}

private final class CatalogPreviewURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responseStatusCode = 206
    private static var responseData = Data(repeating: 7, count: 4_096)
    private static var fullRequests = 0

    static var fullRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return fullRequests
    }

    static func configure(statusCode: Int, byteCount: Int) {
        lock.lock()
        responseStatusCode = statusCode
        responseData = Data(repeating: 7, count: byteCount)
        fullRequests = 0
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
        if request.value(forHTTPHeaderField: "Range") == nil { Self.fullRequests += 1 }
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "video/mp4", "Accept-Ranges": "bytes"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
