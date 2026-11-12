import AVFoundation
import Combine
import Foundation

/// Reads MP4/MOV track headers, never the video payload. An unsupported or
/// incomplete response stays unknown rather than being labelled silent.
enum MP4AudioMetadata {
    enum Step: Equatable {
        case result(Bool), next(Int64), movie(Int64, Int), unknown
    }
    static let maximumMovieBytes = 512 * 1024

    static func scan(_ data: Data, offset: Int64, total: Int64?) -> Step {
        let bytes = [UInt8](data)
        var position = 0
        while position + 8 <= bytes.count {
            guard let box = box(bytes, at: position, total: total.map { $0 - offset }) else { return .unknown }
            guard ["ftyp", "moov", "mdat", "free", "skip", "wide", "uuid", "pnot", "pdin"].contains(box.type),
                  Int64(box.size) <= Int64.max - offset - Int64(position) else { return .unknown }
            if box.type == "moov" {
                guard box.size <= maximumMovieBytes else { return .unknown }
                if box.size > bytes.count - position { return .movie(offset + Int64(position), box.size) }
                var handlers: [String] = []
                guard collectHandlers(bytes, range: position..<(position + box.size), into: &handlers),
                      handlers.contains("vide") else { return .unknown }
                return .result(handlers.contains("soun"))
            }
            guard Int64(position) <= Int64.max - Int64(box.size) else { return .unknown }
            position += box.size
            if let total, offset + Int64(position) >= total { return .unknown }
            if position + 8 > bytes.count { return .next(offset + Int64(position)) }
        }
        return .unknown
    }

    private static func box(_ bytes: [UInt8], at start: Int, total: Int64?) -> (size: Int, header: Int, type: String)? {
        guard start >= 0, start <= bytes.count - 8 else { return nil }
        func number(_ range: Range<Int>) -> UInt64 { range.reduce(0) { ($0 << 8) | UInt64(bytes[$1]) } }
        let small = number(start..<(start + 4))
        var length = small
        var header = 8
        if small == 1 {
            guard start <= bytes.count - 16 else { return nil }
            length = number((start + 8)..<(start + 16)); header = 16
        } else if small == 0 {
            guard let total, total > Int64(start) else { return nil }
            length = UInt64(total - Int64(start))
        }
        guard length >= header, length <= UInt64(Int.max - start),
              let type = String(bytes: bytes[(start + 4)..<(start + 8)], encoding: .ascii) else { return nil }
        return (Int(length), header, type)
    }

    private static func collectHandlers(_ bytes: [UInt8], range: Range<Int>, into handlers: inout [String], depth: Int = 0) -> Bool {
        guard depth < 8 else { return false }
        var start = range.lowerBound
        while start < range.upperBound {
            guard let atom = box(bytes, at: start, total: Int64(range.upperBound)),
                  atom.size <= range.upperBound - start else { return false }
            if ["moov", "trak", "mdia"].contains(atom.type) {
                guard collectHandlers(bytes, range: (start + atom.header)..<(start + atom.size), into: &handlers, depth: depth + 1) else { return false }
            } else if atom.type == "hdlr" {
                guard atom.size >= atom.header + 12,
                      let handler = String(bytes: bytes[(start + atom.header + 8)..<(start + atom.header + 12)], encoding: .ascii) else { return false }
                handlers.append(handler)
            }
            start += atom.size
        }
        return true
    }

    static func inspect(url: URL, referer: URL?, session: URLSession) async throws -> Bool? {
        var offset: Int64 = 0
        var count = 64 * 1024
        for _ in 0..<4 {
            try Task.checkCancellation()
            let (data, total) = try await slice(url: url, referer: referer, offset: offset, count: count, session: session)
            switch scan(data, offset: offset, total: total) {
            case .result(let audio): return audio
            case .next(let next):
                guard next > offset else { return nil }
                offset = next; count = 64 * 1024
            case .movie(let next, let size): offset = next; count = size
            case .unknown: return nil
            }
        }
        return nil
    }

    private static func slice(url: URL, referer: URL?, offset: Int64, count: Int, session: URLSession) async throws -> (Data, Int64?) {
        guard url.scheme == "https", count > 0, count <= maximumMovieBytes, offset >= 0,
              offset <= Int64.max - Int64(count) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            request.setValue(catalogOriginHeaderValue(for: referer), forHTTPHeaderField: "Origin")
        }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.mimeType != "text/html" else { throw URLError(.badServerResponse) }
        let total: Int64?
        if http.statusCode == 206,
           let value = http.value(forHTTPHeaderField: "Content-Range"),
           value.hasPrefix("bytes \(offset)-"), let tail = value.split(separator: "/").last {
            total = Int64(tail)
        } else if http.statusCode == 200, offset == 0,
                  response.expectedContentLength > 0, response.expectedContentLength <= count {
            total = response.expectedContentLength
        } else { throw URLError(.cannotParseResponse) }
        var data = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            data.append(byte)
            if data.count >= count { break }
        }
        return (data, total)
    }
}

@MainActor
final class CatalogAudioMetadata: ObservableObject {
    @Published private(set) var audio: [String: Bool] = [:]
    private struct Entry: Codable { let hasAudio: Bool; let expires: Date; let source: String }
    private let provider: WallpaperCatalogProviding
    private let coordinator: CatalogTransferCoordinator
    private let cacheURL: URL
    private var cache: [String: Entry]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var active = 0
    private var retryAfter: [String: Date] = [:]
    private var cacheGeneration: UInt = 0

    init(provider: WallpaperCatalogProviding, coordinator: CatalogTransferCoordinator, cacheURL: URL) {
        self.provider = provider; self.coordinator = coordinator; self.cacheURL = cacheURL
        cache = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        audio = cache.filter { $0.value.expires > Date() }.mapValues(\.hasAudio)
    }

    func inspect(_ wallpaper: CatalogWallpaper) async {
        let source = wallpaper.sourcePageURL?.absoluteString ?? wallpaper.id
        if let entry = cache[wallpaper.id], entry.source == source, entry.expires > Date() { return }
        if let job = jobs[wallpaper.id] {
            await job.value
            if !Task.isCancelled { await inspect(wallpaper) }
            return
        }
        guard retryAfter[wallpaper.id, default: .distantPast] < Date() else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { jobs[wallpaper.id] = nil }
            do {
                while active >= 2 { try await Task.sleep(nanoseconds: 100_000_000) }
                try Task.checkCancellation()
                guard await coordinator.permitsBackgroundMedia() else { return }
                active += 1
                defer { active -= 1 }
                let url: URL?
                if let resolver = provider as? any WallpaperCatalogMediaResolving {
                    url = try await resolver.resolveMedia(for: wallpaper).originalSources.first?.url
                } else { url = try await provider.resolveDownloadURL(for: wallpaper) }
                try Task.checkCancellation()
                guard let url, await coordinator.permitsBackgroundMedia() else { return }
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                if let result = try await MP4AudioMetadata.inspect(url: url, referer: wallpaper.sourcePageURL, session: session) {
                    try Task.checkCancellation()
                    store(result, id: wallpaper.id, source: source)
                } else { retryAfter[wallpaper.id] = Date().addingTimeInterval(600) }
            } catch {
                if !Task.isCancelled { retryAfter[wallpaper.id] = Date().addingTimeInterval(600) }
            }
        }
        jobs[wallpaper.id] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func inspectLocal(id: String, url: URL) async {
        guard !WallpaperMediaKind.forURL(url).isStaticImage else { audio[id] = false; return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let source = "\(url.path)|\(String(describing: attributes?[.size]))|\(String(describing: attributes?[.modificationDate]))"
        if let entry = cache[id], entry.source == source, entry.expires > Date() { return }
        let generation = cacheGeneration
        do {
            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
            try Task.checkCancellation()
            guard generation == cacheGeneration else { return }
            store(!tracks.isEmpty, id: id, source: source)
        } catch {}
    }

    func cancel() { jobs.values.forEach { $0.cancel() } }

    func clear() {
        cacheGeneration &+= 1
        cancel()
        audio.removeAll(); cache.removeAll(); retryAfter.removeAll()
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func store(_ result: Bool, id: String, source: String) {
        audio[id] = result
        cache[id] = Entry(hasAudio: result, expires: Date().addingTimeInterval(7 * 86400), source: source)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
