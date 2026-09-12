import Foundation
import Testing
@testable import WallpaperControlApp

@Test func catalogDownloaderReusesAFullResponseWhenRangeIsIgnored() async throws {
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
