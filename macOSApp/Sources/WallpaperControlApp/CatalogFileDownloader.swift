import Foundation

enum CatalogFileDownloader {
    private static let parallelThreshold: Int64 = 32 * 1024 * 1024
    private static let chunkSize: Int64 = 8 * 1024 * 1024
    // Four requests keep range-capable CDNs fast without triggering the
    // throttling that made the previous six-request version intermittent.
    private static let maximumConcurrentChunks = 4
    private static let chunkWriteBufferSize = 64 * 1024

    static func download(
        request: URLRequest,
        session: URLSession
    ) async throws -> (temporaryURL: URL, response: URLResponse) {
        let rangeProbe: RangeProbeResult
        do {
            rangeProbe = try await probe(request: request, session: session)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return try await session.download(for: request)
        }

        // A server that ignores Range can make every parallel chunk download
        // the entire video. The probe is deliberately one byte and has a
        // short timeout, so that edge never turns into six duplicate files.
        if rangeProbe.statusCode == 200 {
            return (rangeProbe.temporaryURL, rangeProbe.response)
        }

        guard rangeProbe.statusCode == 206,
              let totalBytes = rangeProbe.totalBytes,
              totalBytes >= parallelThreshold else {
            try? FileManager.default.removeItem(at: rangeProbe.temporaryURL)
            try Task.checkCancellation()
            return try await session.download(for: request)
        }

        try? FileManager.default.removeItem(at: rangeProbe.temporaryURL)

        do {
            return try await parallelDownload(
                request: request,
                session: session,
                totalBytes: totalBytes,
                probeResponse: rangeProbe.response
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Some CDNs advertise range support but reject larger ranges.
            // Keep those servers working with the regular downloader.
            try Task.checkCancellation()
            return try await session.download(for: request)
        }
    }

    private static func probe(
        request: URLRequest,
        session: URLSession
    ) async throws -> RangeProbeResult {
        var probeRequest = request
        probeRequest.timeoutInterval = request.timeoutInterval > 0
            ? min(request.timeoutInterval, 4)
            : 4
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
        // Read the response headers before consuming the body. Some CDNs
        // honour the one-byte probe but ignore larger ranges. Using
        // download(for:) here would then write a complete video to every
        // chunk before we could detect the bad response.
        chunkRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: chunkRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 206,
              contentRange(httpResponse) == range else {
            throw RangeDownloadError.rangeUnsupported
        }

        guard FileManager.default.createFile(
            atPath: destinationURL.path,
            contents: nil
        ) else {
            throw RangeDownloadError.incompleteDownload
        }
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(chunkWriteBufferSize)
        var receivedBytes: Int64 = 0

        for try await byte in bytes {
            guard receivedBytes + Int64(buffer.count) < range.count else {
                throw RangeDownloadError.incompleteDownload
            }
            buffer.append(byte)
            if buffer.count >= chunkWriteBufferSize {
                try handle.write(contentsOf: buffer)
                receivedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            receivedBytes += Int64(buffer.count)
        }

        guard receivedBytes == range.count else {
            throw RangeDownloadError.incompleteDownload
        }
        return DownloadedChunk(range: range, url: destinationURL)
    }

    private static func contentRange(_ response: HTTPURLResponse) -> ClosedRange<Int64>? {
        contentRangeComponents(response)?.range
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

    private struct RangeProbeResult {
        let temporaryURL: URL
        let response: HTTPURLResponse
        let statusCode: Int
        let totalBytes: Int64?
    }

    private enum RangeDownloadError: Error {
        case rangeUnsupported
        case incompleteDownload
    }
}
