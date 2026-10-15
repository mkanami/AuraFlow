import AppKit
import Combine
import Foundation
import Testing
@testable import WallpaperControlApp

@Suite(.serialized)
@MainActor
struct CatalogPreviewImageLoaderTests {
    @Test func fastScrollingCancelsActiveAndQueuedImagesBeforeLoadingLatestCard() async throws {
        let session = try makeSession()
        defer { session.invalidateAndCancel() }
        let first = (0..<3).map { _ in CatalogPreviewImageLoader(session: session) }
        for (index, loader) in first.enumerated() {
            loader.load(url: url("hold-\(index)"), referer: nil)
        }
        try await eventually { PreviewImageURLProtocol.startedCount == 3 }

        let queued = (0..<12).map { _ in CatalogPreviewImageLoader(session: session) }
        for (index, loader) in queued.enumerated() {
            loader.load(url: url("queued-\(index)"), referer: nil)
        }
        // The first three requests deliberately never complete. New cards must
        // get permits through cancellation, rather than their 20-second timeout.
        for loader in queued + first { loader.cancel() }
        let latest = CatalogPreviewImageLoader(session: session)
        latest.load(url: url("latest"), referer: nil)
        try await eventually { latest.image != nil }
        try await eventually { PreviewImageURLProtocol.stoppedCount == 3 }
        #expect(PreviewImageURLProtocol.startedCount == 4)
        #expect((queued + first).allSatisfy { $0.image == nil })
    }

    @Test func changingSourceCancelsOldRequestAndPreservesNewImage() async throws {
        let session = try makeSession()
        defer { session.invalidateAndCancel() }
        let loader = CatalogPreviewImageLoader(session: session)
        loader.load(url: url("hold-old"), referer: nil)
        try await eventually { PreviewImageURLProtocol.startedCount == 1 }
        loader.load(url: url("replacement"), referer: nil)
        try await eventually { loader.image != nil && PreviewImageURLProtocol.stoppedCount == 1 }
        #expect(PreviewImageURLProtocol.startedCount == 2)
    }

    @Test func cachedImageDoesNotFlashEmptyOrFetchAgain() async throws {
        let session = try makeSession()
        defer { session.invalidateAndCancel() }
        let source = url("cached")
        let loader = CatalogPreviewImageLoader(session: session)
        loader.load(url: source, referer: nil)
        try await eventually { loader.image != nil }
        let original = try #require(loader.image)
        var emptyUpdates = 0
        let observation = loader.$image.dropFirst().sink { if $0 == nil { emptyUpdates += 1 } }
        defer { observation.cancel() }
        loader.load(url: source, referer: nil)
        #expect(loader.image === original)
        #expect(emptyUpdates == 0)
        #expect(PreviewImageURLProtocol.startedCount == 1)
    }

    @Test func releasingLoaderCancelsItsNetworkRequest() async throws {
        let session = try makeSession()
        defer { session.invalidateAndCancel() }
        var loader: CatalogPreviewImageLoader? = CatalogPreviewImageLoader(session: session)
        loader?.load(url: url("hold-released"), referer: nil)
        try await eventually { PreviewImageURLProtocol.startedCount == 1 }
        loader = nil
        try await eventually { PreviewImageURLProtocol.stoppedCount == 1 }
    }

    private func makeSession() throws -> URLSession {
        CatalogPreviewImageLoader.clearCache()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
            bytesPerRow: 8, bitsPerPixel: 32))
        bitmap.bitmapData?.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        PreviewImageURLProtocol.reset(body: try #require(bitmap.representation(using: .png, properties: [:])))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PreviewImageURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func url(_ path: String) -> URL {
        URL(string: "https://preview-image.test/\(path)")!
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(condition(), "Preview request should finish or cancel promptly")
    }
}

private final class PreviewImageURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var body = Data()
    private static var started = 0
    private static var stopped = 0

    static var startedCount: Int {
        lock.lock(); defer { lock.unlock() }; return started
    }
    static var stoppedCount: Int {
        lock.lock(); defer { lock.unlock() }; return stopped
    }
    static func reset(body: Data) {
        lock.lock(); defer { lock.unlock() }
        self.body = body; started = 0; stopped = 0
    }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "preview-image.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.started += 1
        let body = Self.body
        Self.lock.unlock()
        guard request.url?.lastPathComponent.hasPrefix("hold-") != true,
              let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        if request.url?.lastPathComponent.hasPrefix("hold-") == true {
            Self.lock.lock(); Self.stopped += 1; Self.lock.unlock()
        }
    }
}
