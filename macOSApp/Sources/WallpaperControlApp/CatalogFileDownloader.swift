import Foundation
import OSLog

enum CatalogHostTransferStrategy: String, Codable, Sendable {
    case parallelRange
    case singleStream
}

struct CatalogHostTransferProfile: Codable, Sendable {
    let strategy: CatalogHostTransferStrategy
    let validUntil: Date
}

actor CatalogHostTransferProfileStore {
    static let shared = CatalogHostTransferProfileStore()

    private static let defaultsKey = "CatalogHostTransferProfiles.v1"
    private let defaults: UserDefaults
    private var profiles: [String: CatalogHostTransferProfile]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(
               [String: CatalogHostTransferProfile].self,
               from: data
           ) {
            profiles = decoded
        } else {
            profiles = [:]
        }
    }

    func strategy(for host: String, now: Date = Date()) -> CatalogHostTransferStrategy? {
        guard let profile = profiles[host], profile.validUntil > now else {
            profiles[host] = nil
            persist()
            return nil
        }
        return profile.strategy
    }

    func record(_ strategy: CatalogHostTransferStrategy, for host: String) {
        profiles[host] = CatalogHostTransferProfile(
            strategy: strategy,
            validUntil: Date().addingTimeInterval(24 * 60 * 60)
        )
        persist()
    }

    func removeProfile(for host: String) {
        profiles[host] = nil
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

enum CatalogFileDownloader {
    private static let defaultParallelThreshold: Int64 = 32 * 1024 * 1024
    private static let defaultChunkSize: Int64 = 8 * 1024 * 1024
    // Four requests keep range-capable CDNs fast without triggering the
    // throttling that made the previous six-request version intermittent.
    private static let maximumConcurrentChunks = 4
    private static let maximumDownloadAttempts = 3
    private static let defaultValidationRangeBytes: Int64 = 256 * 1024
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "AuraFlow",
        category: "CatalogTransfer"
    )

    static func download(
        request: URLRequest,
        session: URLSession,
        parallelThreshold: Int64 = defaultParallelThreshold,
        chunkSize: Int64 = defaultChunkSize,
        validationRangeBytes: Int64 = defaultValidationRangeBytes
    ) async throws -> (temporaryURL: URL, response: URLResponse) {
        let host = request.url?.host?.lowercased() ?? "unknown"
        // MoeWalls' Cloudflare route is materially faster as one HTTP/2 body.
        // Multiple URLSession range tasks are throttled independently and
        // measured 3-4x slower for the same file on this CDN.
        if host.contains("moewalls.com") {
            logger.info("stage=range-strategy strategy=single-stream source=provider")
            return try await regularDownloadWithRetry(request: request, session: session)
        }
        if await CatalogHostTransferProfileStore.shared.strategy(for: host) == .singleStream {
            logger.info("stage=range-strategy strategy=single-stream source=cached")
            return try await regularDownloadWithRetry(request: request, session: session)
        }

        let probeStartedAt = Date()
        let rangeProbe: RangeProbeResult
        do {
            rangeProbe = try await probe(request: request, session: session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return try await regularDownloadWithRetry(
                request: request,
                session: session
            )
        }
        let firstByteMilliseconds = Int(Date().timeIntervalSince(probeStartedAt) * 1_000)
        logger.info("stage=first-byte elapsed_ms=\(firstByteMilliseconds)")

        // A server that ignores Range can make every parallel chunk download
        // the entire video. The probe is deliberately one byte and has a
        // short timeout, so that edge never turns into six duplicate files.
        if rangeProbe.statusCode == 200 {
            await CatalogHostTransferProfileStore.shared.record(.singleStream, for: host)
            logger.info("stage=range-strategy strategy=single-stream source=probe")
            return (rangeProbe.temporaryURL, rangeProbe.response)
        }

        guard rangeProbe.statusCode == 206,
              let totalBytes = rangeProbe.totalBytes,
              totalBytes >= parallelThreshold else {
            try? FileManager.default.removeItem(at: rangeProbe.temporaryURL)
            try Task.checkCancellation()
            return try await regularDownloadWithRetry(
                request: request,
                session: session
            )
        }

        try? FileManager.default.removeItem(at: rangeProbe.temporaryURL)
        let validationRange = Int64(0)...min(validationRangeBytes - 1, totalBytes - 1)
        let validationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraFlowRangeValidation-\(UUID().uuidString)")
        let validation = try await downloadRangeWithRetry(
            request: request,
            session: session,
            range: validationRange,
            destinationURL: validationURL,
            acceptsFullResponse: true
        )
        switch validation {
        case let .full(temporaryURL, response):
            await CatalogHostTransferProfileStore.shared.record(.singleStream, for: host)
            logger.info("stage=range-strategy strategy=single-stream source=validation")
            return (temporaryURL, response)
        case let .partial(initialChunk):
            await CatalogHostTransferProfileStore.shared.record(.parallelRange, for: host)
            logger.info("stage=range-strategy strategy=parallel-range")
            return try await parallelDownload(
                request: request,
                session: session,
                totalBytes: totalBytes,
                probeResponse: rangeProbe.response,
                initialChunk: initialChunk,
                chunkSize: chunkSize
            )
        }
    }

    private static func regularDownloadWithRetry(
        request: URLRequest,
        session: URLSession
    ) async throws -> (temporaryURL: URL, response: URLResponse) {
        var attempt = 0
        while true {
            do {
                let (temporaryURL, response) = try await session.download(
                    for: request
                )
                if let httpResponse = response as? HTTPURLResponse,
                   isRetryableStatus(httpResponse.statusCode),
                   attempt + 1 < maximumDownloadAttempts {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    try await retryDelay(after: attempt)
                    attempt += 1
                    continue
                }
                return (temporaryURL, response)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt + 1 < maximumDownloadAttempts,
                      isRetryableDownloadError(error) else {
                    throw error
                }
                try await retryDelay(after: attempt)
                attempt += 1
            }
        }
    }

    private static func probe(
        request: URLRequest,
        session: URLSession
    ) async throws -> RangeProbeResult {
        var probeRequest = request
        probeRequest.timeoutInterval = request.timeoutInterval > 0
            ? min(request.timeoutInterval, 8)
            : 8
        probeRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        probeRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (temporaryURL, response) = try await session.download(for: probeRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw RangeDownloadError.rangeUnsupported
        }

        guard httpResponse.statusCode == 200 else {
            guard httpResponse.statusCode == 206,
                  let contentRange = contentRangeComponents(httpResponse),
                  contentRange.range == 0...0 else {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw RangeDownloadError.rangeUnsupported
            }
            return RangeProbeResult(
                temporaryURL: temporaryURL,
                response: httpResponse,
                statusCode: httpResponse.statusCode,
                totalBytes: contentRange.totalBytes
            )
        }

        return RangeProbeResult(
            temporaryURL: temporaryURL,
            response: httpResponse,
            statusCode: httpResponse.statusCode,
            totalBytes: httpResponse.expectedContentLength > 0
                ? httpResponse.expectedContentLength
                : nil
        )
    }

    private static func parallelDownload(
        request: URLRequest,
        session: URLSession,
        totalBytes: Int64,
        probeResponse: HTTPURLResponse,
        initialChunk: DownloadedChunk,
        chunkSize: Int64
    ) async throws -> (temporaryURL: URL, response: URLResponse) {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraFlowDownload-\(UUID().uuidString)", isDirectory: true)
        let assembledURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuraFlowDownload-\(UUID().uuidString)")
        var keepAssembledFile = false
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: initialChunk.url)
            try? FileManager.default.removeItem(at: temporaryDirectory)
            if !keepAssembledFile {
                try? FileManager.default.removeItem(at: assembledURL)
            }
        }

        let remainingBytes = totalBytes - initialChunk.range.upperBound - 1
        let boundedChunkSize = max(
            chunkSize,
            (remainingBytes + Int64(maximumConcurrentChunks) - 1)
                / Int64(maximumConcurrentChunks)
        )
        let ranges = makeRanges(
            totalBytes: totalBytes,
            startingAt: initialChunk.range.upperBound + 1,
            chunkSize: boundedChunkSize
        )
        var chunks: [DownloadedChunk] = [initialChunk]

        try await withThrowingTaskGroup(of: DownloadedChunk.self) { group in
            var nextRange = ranges.makeIterator()
            var activeCount = 0

            func addNextChunk() {
                guard let range = nextRange.next() else { return }
                let chunkIndex = Int(range.lowerBound / chunkSize) + 1
                let chunkURL = temporaryDirectory.appendingPathComponent("chunk-\(chunkIndex)")
                group.addTask {
                    let result = try await downloadRangeWithRetry(
                        request: request,
                        session: session,
                        range: range,
                        destinationURL: chunkURL,
                        acceptsFullResponse: false
                    )
                    guard case let .partial(chunk) = result else {
                        throw RangeDownloadError.rangeUnsupported
                    }
                    return chunk
                }
                activeCount += 1
            }

            while activeCount < maximumConcurrentChunks {
                let before = activeCount
                addNextChunk()
                if before == activeCount { break }
            }

            while let chunk = try await group.next() {
                chunks.append(chunk)
                activeCount -= 1
                addNextChunk()
            }
        }

        guard chunks.count == ranges.count + 1 else {
            throw RangeDownloadError.incompleteDownload
        }

        FileManager.default.createFile(atPath: assembledURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: assembledURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(totalBytes))

        for chunk in chunks.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard fileSize(at: chunk.url) == chunk.range.count else {
                throw RangeDownloadError.incompleteDownload
            }
            try handle.seek(toOffset: UInt64(chunk.range.lowerBound))
            try copyFile(chunk.url, to: handle)
        }

        keepAssembledFile = true
        return (assembledURL, probeResponse)
    }

    private static func downloadRange(
        request: URLRequest,
        session: URLSession,
        range: ClosedRange<Int64>,
        destinationURL: URL,
        acceptsFullResponse: Bool
    ) async throws -> RangeResponse {
        var chunkRequest = request
        chunkRequest.setValue(
            "bytes=\(range.lowerBound)-\(range.upperBound)",
            forHTTPHeaderField: "Range"
        )
        chunkRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (temporaryURL, response) = try await session.download(for: chunkRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw RangeDownloadError.rangeUnsupported
        }
        if httpResponse.statusCode == 200, acceptsFullResponse {
            return .full(temporaryURL, httpResponse)
        }
        guard httpResponse.statusCode == 206 else {
            try? FileManager.default.removeItem(at: temporaryURL)
            if isRetryableStatus(httpResponse.statusCode) {
                throw RangeDownloadError.transientHTTPStatus(
                    httpResponse.statusCode
                )
            }
            throw RangeDownloadError.rangeUnsupported
        }

        guard contentRange(httpResponse) == range,
              fileSize(at: temporaryURL) == range.count else {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw RangeDownloadError.incompleteDownload
        }
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return .partial(DownloadedChunk(range: range, url: destinationURL))
    }

    private static func downloadRangeWithRetry(
        request: URLRequest,
        session: URLSession,
        range: ClosedRange<Int64>,
        destinationURL: URL,
        acceptsFullResponse: Bool
    ) async throws -> RangeResponse {
        var attempt = 0
        while true {
            do {
                return try await downloadRange(
                    request: request,
                    session: session,
                    range: range,
                    destinationURL: destinationURL,
                    acceptsFullResponse: acceptsFullResponse
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt + 1 < maximumDownloadAttempts,
                      isRetryableDownloadError(error) else {
                    throw error
                }
                try await retryDelay(after: attempt)
                attempt += 1
            }
        }
    }

    private static func contentRange(_ response: HTTPURLResponse) -> ClosedRange<Int64>? {
        contentRangeComponents(response)?.range
    }

    private static func retryDelay(after attempt: Int) async throws {
        let milliseconds = UInt64(250 * (attempt + 1))
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    private static func isRetryableDownloadError(_ error: Error) -> Bool {
        if let rangeError = error as? RangeDownloadError {
            switch rangeError {
            case .rangeUnsupported:
                return false
            case .incompleteDownload, .transientHTTPStatus:
                return true
            }
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .networkConnectionLost,
             .notConnectedToInternet,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private static func isRetryableStatus(_ statusCode: Int) -> Bool {
        statusCode == 408
            || statusCode == 425
            || statusCode == 429
            || (500...599).contains(statusCode)
    }

    private static func contentRangeComponents(
        _ response: HTTPURLResponse
    ) -> (range: ClosedRange<Int64>, totalBytes: Int64?)? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let rangePart = value.split(separator: "/").first,
              let totalPart = value.split(separator: "/").dropFirst().first else {
            return nil
        }
        let bounds = String(rangePart)
            .replacingOccurrences(of: "bytes ", with: "")
            .split(separator: "-")
        guard bounds.count == 2,
              let lowerBound = Int64(bounds[0]),
              let upperBound = Int64(bounds[1]) else {
            return nil
        }
        let totalBytes = Int64(totalPart)
        return (lowerBound...upperBound, totalBytes)
    }

    private static func makeRanges(
        totalBytes: Int64,
        startingAt start: Int64 = 0,
        chunkSize: Int64 = defaultChunkSize
    ) -> [ClosedRange<Int64>] {
        var ranges: [ClosedRange<Int64>] = []
        var lowerBound = start
        while lowerBound < totalBytes {
            ranges.append(lowerBound...min(lowerBound + chunkSize - 1, totalBytes - 1))
            lowerBound += chunkSize
        }
        return ranges
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private static func copyFile(_ sourceURL: URL, to destination: FileHandle) throws {
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        while true {
            let data = try source.read(upToCount: 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            try destination.write(contentsOf: data)
        }
    }

    private struct DownloadedChunk: Sendable {
        let range: ClosedRange<Int64>
        let url: URL
    }

    private enum RangeResponse: Sendable {
        case partial(DownloadedChunk)
        case full(URL, HTTPURLResponse)
    }

    private struct RangeProbeResult {
        let temporaryURL: URL
        let response: HTTPURLResponse
        let statusCode: Int
        let totalBytes: Int64?
    }

    private enum RangeDownloadError: Error {
        case rangeUnsupported
        case incompleteDownload
        case transientHTTPStatus(Int)
    }
}
