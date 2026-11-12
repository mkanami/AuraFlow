import Foundation
import Testing
@testable import WallpaperControlApp

@Test func wallpaperAudioNetworkProbeBoundsRequestsAndRejectsIgnoredRanges() async throws {
    let fixture = try #require(Bundle.module.url(forResource: "wallpaper-with-audio", withExtension: "mp4"))
    let data = try Data(contentsOf: fixture)
    for mode in ["range", "ignore", "html", "wrong-offset"] {
        AudioHeaderProtocol.configure(data, mode: mode)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AudioHeaderProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://audio-metadata.test/original.mp4")!
        do {
            let result = try await MP4AudioMetadata.inspect(url: url, referer: nil, session: session)
            #expect(mode == "range")
            #expect(result == true)
        } catch { #expect(mode != "range") }
        #expect(AudioHeaderProtocol.ranges == ["bytes=0-65535"])
    }
}

private final class AudioHeaderProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var data = Data()
    private static var mode = "range"
    private static var recorded: [String] = []
    static var ranges: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func configure(_ value: Data, mode: String) {
        lock.lock(); defer { lock.unlock() }; data = value; self.mode = mode; recorded = []
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "audio-metadata.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let body = Self.data, mode = Self.mode
        Self.recorded.append(request.value(forHTTPHeaderField: "Range") ?? "none")
        Self.lock.unlock()
        let headers = ["Content-Type": mode == "html" ? "text/html" : "video/mp4",
            "Content-Length": String(mode == "ignore" ? 100_000_000 : body.count),
            "Content-Range": "bytes \(mode == "wrong-offset" ? 1 : 0)-\(body.count - 1)/\(body.count)"]
        let response = HTTPURLResponse(url: request.url!, statusCode: mode == "ignore" ? 200 : 206,
            httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if mode == "range" { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
