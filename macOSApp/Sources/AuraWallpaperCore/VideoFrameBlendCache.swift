import AVFoundation
import CryptoKit
import Foundation

/// Prepared temporal blending is shared by AVPlayer and the system Lock Screen
/// player. Originals remain the source of truth; only completed movies enter the cache.
public struct VideoFrameBlendCache: Sendable {
    private static let manifestLock = NSLock()
    public let directory: URL
    public init(appSupportURL: URL = WallpaperRuntimeStore.defaultAppSupportURL()) {
        directory = appSupportURL.appendingPathComponent("FrameBlendCache", isDirectory: true)
    }

    public func outputURL(for source: URL) throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let identity = ["blend-v1", source.standardizedFileURL.path,
                        String(describing: attributes[.systemFileNumber] ?? ""),
                        String(describing: attributes[.size] ?? ""),
                        String((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)]
            .joined(separator: "|")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".mp4")
    }

    public func playbackURL(for source: URL, enabled: Bool) -> URL {
        guard enabled, !WallpaperMediaKind.forURL(source).isStaticImage,
              let cached = try? outputURL(for: source),
              FileManager.default.fileExists(atPath: cached.path) else { return source }
        return cached
    }

    public func prepare(_ source: URL, ffmpegURL: URL? = nil) async throws -> URL {
        guard !WallpaperMediaKind.forURL(source).isStaticImage else { return source }
        let output = try outputURL(for: source)
        if await Self.isPlayable(output) {
            try register(source: source, prepared: output)
            return output
        }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw BlendError.failed("No video track for frame blending.")
        }
        let sourceFPS = Double(try await track.load(.nominalFrameRate))
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else { throw BlendError.failed("Invalid video duration.") }
        // Native 60+ fps video already supplies the target cadence. Avoid a
        // costly re-encode that would add no intermediate frames.
        if sourceFPS >= 59.94 { return source }
        guard let executable = ffmpegURL ?? Self.ffmpegURL() else {
            throw BlendError.failed("Frame blending requires the bundled ffmpeg tool or an installed ffmpeg.")
        }
        let fps = 60.0
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial.mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Pad the decoder's final look-ahead and trim back to the original duration.
        // No scale filter: resolution and aspect ratio remain intact.
        let args = ["-y", "-hide_banner", "-loglevel", "error", "-i", source.path,
                    "-an", "-sn", "-dn", "-vf",
                    "tpad=stop_mode=clone:stop_duration=1,minterpolate=fps=\(fps):mi_mode=blend:scd=none",
                    "-t", String(duration), "-c:v", "libx264", "-preset", "fast", "-crf", "16",
                    "-pix_fmt", "yuv420p", "-movflags", "+faststart", temporary.path]
        let job = BlendProcess()
        try await withTaskCancellationHandler {
            try await job.run(executable, arguments: args)
            try Task.checkCancellation()
        } onCancel: { job.cancel() }
        guard await Self.isPlayable(temporary) else { throw BlendError.failed("Frame blending produced an unreadable movie.") }
        guard try outputURL(for: source) == output else {
            throw BlendError.failed("The source video changed during frame blending. Try again.")
        }
        // A second preparer can finish the same source concurrently.
        if await Self.isPlayable(output) {
            try register(source: source, prepared: output)
            return output
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: temporary, to: output)
        try register(source: source, prepared: output)
        return output
    }

    private struct ManifestEntry: Codable {
        let path: String
        let size: Int64
        let modified: Double
    }
    private func register(source: URL, prepared: URL) throws {
        try Self.manifestLock.withLock {
            let manifest = directory.appendingPathComponent("sources.json")
            var entries = (try? Data(contentsOf: manifest)).flatMap {
                try? JSONDecoder().decode([String: ManifestEntry].self, from: $0)
            } ?? [:]
            let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
            entries[source.standardizedFileURL.path] = ManifestEntry(
                path: prepared.path,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
            try JSONEncoder().encode(entries).write(to: manifest, options: .atomic)
        }
    }

    private static func isPlayable(_ url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true,
              let duration = try? await asset.load(.duration) else { return false }
        return CMTimeGetSeconds(duration) > 0
    }

    private static func ffmpegURL() -> URL? {
        let resources = Bundle.main.resourceURL
        let candidates: [String?] = [ProcessInfo.processInfo.environment["AURAFLOW_FFMPEG_PATH"],
                          resources?.appendingPathComponent("BundledTools/ffmpeg").path,
                          resources?.appendingPathComponent("bin/ffmpeg").path,
                          "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.compactMap { $0 }.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    private enum BlendError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }

    private final class BlendProcess: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true; if process?.isRunning == true { process?.terminate() } } }
        func run(_ executable: URL, arguments: [String]) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    process.standardOutput = FileHandle.nullDevice
                    // Drain stderr before waiting; ffmpeg diagnostics can exceed a pipe buffer.
                    let pipe = Pipe()
                    process.standardError = pipe
                    do {
                        try self.lock.withLock {
                            if self.cancelled { throw CancellationError() }
                            self.process = process
                            try process.run()
                        }
                        let diagnostic = pipe.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        try self.lock.withLock {
                            self.process = nil
                            if self.cancelled { throw CancellationError() }
                        }
                        guard process.terminationStatus == 0 else {
                            throw BlendError.failed("Frame blending failed: " + String(decoding: diagnostic.suffix(2048), as: UTF8.self))
                        }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
}
