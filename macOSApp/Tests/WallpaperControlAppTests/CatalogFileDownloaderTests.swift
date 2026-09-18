import Foundation
import Testing
@testable import WallpaperControlApp

@Test func catalogDownloaderReusesAFullResponseWhenRangeIsIgnored() async throws {
    await CatalogHostTransferProfileStore.shared.removeProfile(for: "unit.test")
    let body = Data("one full response".utf8)
    RangeIgnoringURLProtocol.configure(body: body)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RangeIgnoringURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    var request = URLRequest(url: URL(string: "https://unit.test/wallpaper.mp4")!)
    request.timeoutInterval = 2
    let result = try await CatalogFileDownloader.download(request: request, session: session)
    defer { try? FileManager.default.removeItem(at: result.temporaryURL) }

    let downloadedBody = try Data(contentsOf: result.temporaryURL)
    #expect(downloadedBody == body)
    #expect(RangeIgnoringURLProtocol.requestCount == 1)
}

@Test func catalogDownloaderUsesOneSingleStreamForMoeWalls() async throws {
    MoeWallsSingleURLProtocol.configure(body: Data(repeating: 9, count: 4_096))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MoeWallsSingleURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let request = URLRequest(
        url: URL(string: "https://go.moewalls.com/download.php?video=test")!
    )
    let result = try await CatalogFileDownloader.download(
        request: request,
        session: session,
        parallelThreshold: 1
    )
    defer { try? FileManager.default.removeItem(at: result.temporaryURL) }

    #expect(MoeWallsSingleURLProtocol.requestCount == 1)
    #expect(MoeWallsSingleURLProtocol.requestedRanges == [nil])
}

@Test func catalogDownloaderReusesValidationBodyWhenLargeRangesAreIgnored() async throws {
    await CatalogHostTransferProfileStore.shared.removeProfile(for: "validation-range.test")
    let body = Data("validation became the one full stream".utf8)
    RangeValidationURLProtocol.configure(body: body)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RangeValidationURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    var request = URLRequest(
        url: URL(string: "https://validation-range.test/wallpaper.mp4")!
    )
    request.timeoutInterval = 2
    let result = try await CatalogFileDownloader.download(request: request, session: session)
    defer { try? FileManager.default.removeItem(at: result.temporaryURL) }

    #expect(try Data(contentsOf: result.temporaryURL) == body)
    #expect(RangeValidationURLProtocol.requestCount == 2)
    #expect(RangeValidationURLProtocol.requestedRanges == ["bytes=0-0", "bytes=0-262143"])
}

@Test func catalogDownloaderRetriesOnlyTheMissingChunkWithoutAFullRestart() async throws {
    await CatalogHostTransferProfileStore.shared.removeProfile(for: "parallel-range.test")
    RangeChunkURLProtocol.configure(totalBytes: 40, transientRange: "bytes=13-21")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RangeChunkURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let request = URLRequest(
        url: URL(string: "https://parallel-range.test/wallpaper.mp4")!
    )
    let result = try await CatalogFileDownloader.download(
        request: request,
        session: session,
        parallelThreshold: 16,
        chunkSize: 8,
        validationRangeBytes: 4
    )
    defer { try? FileManager.default.removeItem(at: result.temporaryURL) }

    #expect(
        try Data(contentsOf: result.temporaryURL)
            == Data((0..<40).map(UInt8.init))
    )
    #expect(RangeChunkURLProtocol.requestCount(for: "bytes=13-21") == 2)
    #expect(RangeChunkURLProtocol.uniqueRequestedRangeCount == 6)
    #expect(RangeChunkURLProtocol.fullRequestCount == 0)
}

private final class RangeIgnoringURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var configuredBody = Data()
    private static var requestCounter = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCounter
    }

    static func configure(body: Data) {
        lock.lock()
        configuredBody = body
        requestCounter = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "unit.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCounter += 1
        let body = Self.configuredBody
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: [
                      "Content-Length": String(body.count),
                      "Content-Type": "video/mp4"
                  ]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class MoeWallsSingleURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var configuredBody = Data()
    private static var ranges: [String?] = []

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ranges.count
    }

    static var requestedRanges: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return ranges
    }

    static func configure(body: Data) {
        lock.lock()
        configuredBody = body
        ranges = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "go.moewalls.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.ranges.append(request.value(forHTTPHeaderField: "Range"))
        let body = Self.configuredBody
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [
                "Content-Length": String(body.count),
                "Content-Type": "application/octet-stream",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RangeValidationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var configuredBody = Data()
    private static var ranges: [String] = []

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return ranges.count
    }

    static var requestedRanges: [String] {
        lock.lock()
        defer { lock.unlock() }
        return ranges
    }

    static func configure(body: Data) {
        lock.lock()
        configuredBody = body
        ranges = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "validation-range.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range") ?? "none"
        Self.lock.lock()
        Self.ranges.append(range)
        let body = Self.configuredBody
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let isProbe = range == "bytes=0-0"
        let responseBody = isProbe ? Data([body.first ?? 0]) : body
        let headers: [String: String] = isProbe
            ? [
                "Content-Length": "1",
                "Content-Range": "bytes 0-0/41943040",
                "Content-Type": "video/mp4",
            ]
            : [
                "Content-Length": String(body.count),
                "Content-Type": "video/mp4",
            ]
        let response = HTTPURLResponse(
            url: url,
            statusCode: isProbe ? 206 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RangeChunkURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var total = 0
    private static var transientRange = ""
    private static var counts: [String: Int] = [:]

    static var fullRequestCount: Int { requestCount(for: "none") }
    static var uniqueRequestedRangeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.keys.filter { $0 != "none" }.count
    }

    static func configure(totalBytes: Int, transientRange: String) {
        lock.lock()
        total = totalBytes
        self.transientRange = transientRange
        counts = [:]
        lock.unlock()
    }

    static func requestCount(for range: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[range, default: 0]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "parallel-range.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let rangeHeader = request.value(forHTTPHeaderField: "Range") ?? "none"
        Self.lock.lock()
        Self.counts[rangeHeader, default: 0] += 1
        let attempt = Self.counts[rangeHeader, default: 0]
        let total = Self.total
        let shouldFail = rangeHeader == Self.transientRange && attempt == 1
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if shouldFail {
            let response = HTTPURLResponse(
                url: url,
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        guard let range = Self.parseRange(rangeHeader) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = Data(range.map(UInt8.init))
        let response = HTTPURLResponse(
            url: url,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Length": String(body.count),
                "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound)/\(total)",
                "Content-Type": "video/mp4",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func parseRange(_ value: String) -> ClosedRange<Int>? {
        let bounds = value.replacingOccurrences(of: "bytes=", with: "")
            .split(separator: "-")
        guard bounds.count == 2,
              let lower = Int(bounds[0]),
              let upper = Int(bounds[1]) else { return nil }
        return lower...upper
    }
}
