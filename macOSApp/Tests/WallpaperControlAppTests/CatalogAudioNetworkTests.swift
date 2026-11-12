import Foundation
import Testing
@testable import WallpaperControlApp

@Suite(.serialized)
struct CatalogAudioNetworkTests {
    @Test func wallpaperAudioNetworkProbeBoundsRequestsAndRejectsIgnoredRanges() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "wallpaper-with-audio", withExtension: "mp4"))
        let data = try Data(contentsOf: fixture)
        for mode in ["range", "ignore", "html", "wrong-offset", "oversized-range"] {
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

    @Test func wallpaperAudioRemoteSamplesVerifySoundRatherThanTrackPresence() async throws {
        for (name, expected) in [("wallpaper-with-audio", WallpaperAudioContent.audible),
                                 ("wallpaper-with-silent-track", .silent),
                                 ("wallpaper-without-audio", .noTrack),
                                 ("wallpaper-with-delayed-audio", .audible)] {
            let fixture = try #require(Bundle.module.url(forResource: name, withExtension: "mp4"))
            let data = try audioProbeDataWithSparsePayloadGap(Data(contentsOf: fixture))
            AudioHeaderProtocol.configure(data, mode: "range")
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [AudioHeaderProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let result = try await MP4AudioMetadata.inspectSound(url: URL(string: "https://audio-metadata.test/original.mp4")!, referer: nil, session: session)
            #expect(result == expected, "\(name): \(result)")
            #expect(AudioHeaderProtocol.ranges.count <= 10)
            #expect(AudioHeaderProtocol.ranges.allSatisfy { $0.hasPrefix("bytes=") })
        }
    }
}

/// Move media samples beyond the initial 64 KiB header read, so the remote
/// test must retrieve the actual audio ranges rather than decode a tiny file
/// that happened to fit completely inside its first header request.
private func audioProbeDataWithSparsePayloadGap(_ original: Data) throws -> Data {
    var data = original
    let gap = 256 * 1024
    func number(_ start: Int) -> Int { data[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) } }
    func write(_ value: Int, at start: Int) {
        for index in 0..<4 { data[start + index] = UInt8((value >> ((3 - index) * 8)) & 255) }
    }
    var position = 0
    var payload: Int?
    while position + 8 <= data.count {
        let size = number(position)
        guard size >= 8, position + size <= data.count else { throw URLError(.cannotParseResponse) }
        let type = String(data: data[(position + 4)..<(position + 8)], encoding: .ascii)
        if type == "mdat" { write(size + gap, at: position); payload = position + 8 }
        if type == "moov" {
            var search = (position + 8)..<(position + size)
            while let field = data.range(of: Data("stco".utf8), in: search) {
                let count = number(field.lowerBound + 8)
                for index in 0..<count {
                    let start = field.lowerBound + 12 + index * 4
                    write(number(start) + gap, at: start)
                }
                search = field.upperBound..<search.upperBound
            }
        }
        position += size
    }
    let insertion = try #require(payload)
    data.insert(contentsOf: repeatElement(UInt8(0), count: gap), at: insertion)
    return data
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
        let data = Self.data, mode = Self.mode
        let range = request.value(forHTTPHeaderField: "Range") ?? "none"
        Self.recorded.append(range)
        Self.lock.unlock()
        let limits = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
        let start = limits.first ?? 0
        let end = min(limits.last ?? data.count - 1, data.count - 1)
        guard start >= 0, end >= start, end < data.count else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        let body = data.subdata(in: start..<(end + 1))
        let headers = ["Content-Type": mode == "html" ? "text/html" : "video/mp4",
            "Content-Length": String(mode == "ignore" ? 100_000_000 : body.count),
            "Content-Range": "bytes \(mode == "wrong-offset" ? start + 1 : start)-\(mode == "oversized-range" ? 100_000_000 : end)/\(data.count)"]
        let response = HTTPURLResponse(url: request.url!, statusCode: mode == "ignore" ? 200 : 206,
            httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if mode == "range" { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
