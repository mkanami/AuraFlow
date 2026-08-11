import Foundation

enum CatalogFileDownloader {
    private static let parallelThreshold: Int64 = 32 * 1024 * 1024
    private static let chunkSize: Int64 = 8 * 1024 * 1024
    private static let maximumConcurrentChunks = 6

    static func download(
        request: URLRequest,
        session: URLSession
    ) async throws -> (temporaryURL: URL, response: URLResponse) {
        guard let probe = try? await probe(request: request, session: session),
              let totalBytes = probe.totalBytes,
              totalBytes >= parallelThreshold else {
            return try await session.download(for: request)
        }

        do {
            return try await parallelDownload(
                request: request,
                session: session,
                totalBytes: totalBytes,
                probeResponse: probe.response
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Some CDNs advertise range support but reject larger ranges.
            // Keep those servers working with the regular downloader.
            return try await session.download(for: request)
        }
    }

    private static func probe(
        request: URLRequest,
        session: URLSession
    ) async throws -> (totalBytes: Int64?, response: HTTPURLResponse) {
        var probeRequest = request
        probeRequest.httpMethod = "HEAD"
        probeRequest.setValue(nil, forHTTPHeaderField: "Range")
        let (_, response) = try await session.data(for: probeRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              httpResponse.value(forHTTPHeaderField: "Accept-Ranges")?
                .localizedCaseInsensitiveContains("bytes") == true else {
            throw RangeDownloadError.rangeUnsupported
        }

        let totalBytes = httpResponse.value(forHTTPHeaderField: "Content-Length")
            .flatMap(Int64.init)
            ?? (httpResponse.expectedContentLength > 0 ? httpResponse.expectedContentLength : nil)
        return (totalBytes, httpResponse)
    }

    private static func parallelDownload(
        request: URLRequest,
        session: URLSession,
        totalBytes: Int64,
        probeResponse: HTTPURLResponse
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
            try? FileManager.default.removeItem(at: temporaryDirectory)
            if !keepAssembledFile {
                try? FileManager.default.removeItem(at: assembledURL)
            }
        }

        let ranges = makeRanges(totalBytes: totalBytes)
        var chunks: [DownloadedChunk] = []

        try await withThrowingTaskGroup(of: DownloadedChunk.self) { group in
            var nextRange = ranges.makeIterator()
            var activeCount = 0

            func addNextChunk() {
                guard let range = nextRange.next() else { return }
                let chunkIndex = chunks.count + activeCount
                let chunkURL = temporaryDirectory.appendingPathComponent("chunk-\(chunkIndex)")
                group.addTask {
                    try await downloadChunk(
                        request: request,
                        session: session,
                        range: range,
                        destinationURL: chunkURL
                    )
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

        guard chunks.count == ranges.count else {
            throw RangeDownloadError.incompleteDownload
        }

        FileManager.default.createFile(atPath: assembledURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: assembledURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(totalBytes))

        for chunk in chunks.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let data = try Data(contentsOf: chunk.url)
            guard Int64(data.count) == chunk.range.count else {
                throw RangeDownloadError.incompleteDownload
            }
            try handle.seek(toOffset: UInt64(chunk.range.lowerBound))
            try handle.write(contentsOf: data)
        }

        keepAssembledFile = true
        return (assembledURL, probeResponse)
    }

    private static func downloadChunk(
        request: URLRequest,
        session: URLSession,
        range: ClosedRange<Int64>,
        destinationURL: URL
    ) async throws -> DownloadedChunk {
        var chunkRequest = request
        chunkRequest.setValue(
            "bytes=\(range.lowerBound)-\(range.upperBound)",
            forHTTPHeaderField: "Range"
        )
        let (temporaryURL, response) = try await session.download(for: chunkRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 206,
              contentRange(httpResponse) == range else {
            throw RangeDownloadError.rangeUnsupported
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        return DownloadedChunk(range: range, url: destinationURL)
    }

    private static func contentRange(_ response: HTTPURLResponse) -> ClosedRange<Int64>? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let rangePart = value.split(separator: "/").first else {
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
        return lowerBound...upperBound
    }

    private static func makeRanges(totalBytes: Int64) -> [ClosedRange<Int64>] {
        var ranges: [ClosedRange<Int64>] = []
        var lowerBound: Int64 = 0
        while lowerBound < totalBytes {
            ranges.append(lowerBound...min(lowerBound + chunkSize - 1, totalBytes - 1))
            lowerBound += chunkSize
        }
        return ranges
    }

    private struct DownloadedChunk: Sendable {
        let range: ClosedRange<Int64>
        let url: URL
    }

    private enum RangeDownloadError: Error {
        case rangeUnsupported
        case incompleteDownload
    }
}
