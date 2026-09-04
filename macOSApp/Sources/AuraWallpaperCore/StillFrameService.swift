import AppKit
import AVFoundation
import Foundation

/// Captures and caches the still image used by the legacy/Desktop fallback.
///
/// The service owns only frame generation and its source-revision cache. The
/// runtime store remains the compatibility facade for the public file URLs and
/// desktop wallpaper operations.
public final class StillFrameService {
    private struct LastFrameSourceRevision: Codable, Equatable {
        var path: String
        var size: UInt64?
        var modifiedAt: Double?
    }

    public let appSupportURL: URL

    public init(appSupportURL: URL) {
        self.appSupportURL = appSupportURL
    }

    public var lastFrameURL: URL {
        appSupportURL.appendingPathComponent("last_frame.png")
    }

    public var lastFrameSourceURL: URL {
        appSupportURL.appendingPathComponent("last_frame_source.json")
    }

    public func captureStillFrame(
        from videoURL: URL,
        time: CMTime = CMTime(seconds: 0.2, preferredTimescale: 600)
    ) throws -> URL {
        try ensureAppSupportDirectory()

        let image: CGImage
        if WallpaperMediaKind.forURL(videoURL).isStaticImage {
            guard let sourceImage = NSImage(contentsOf: videoURL),
                  let decodedImage = sourceImage.cgImage(
                      forProposedRect: nil,
                      context: nil,
                      hints: nil
                  )
            else {
                throw WallpaperRuntimeError.unavailable(
                    "Could not decode wallpaper image."
                )
            }
            image = decodedImage
        } else {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 3840, height: 2160)
            image = try generator.copyCGImage(at: time, actualTime: nil)
        }

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw WallpaperRuntimeError.unavailable("Could not encode wallpaper frame.")
        }
        try data.write(to: lastFrameURL, options: .atomic)
        try writeJSON(
            sourceRevision(for: videoURL),
            to: lastFrameSourceURL
        )
        return lastFrameURL
    }

    public func ensureCurrentStillFrame(from videoURL: URL) throws -> URL {
        let expectedRevision = sourceRevision(for: videoURL)
        let savedRevision: LastFrameSourceRevision? = try? readJSON(
            LastFrameSourceRevision.self,
            from: lastFrameSourceURL
        )
        if FileManager.default.fileExists(atPath: lastFrameURL.path),
           savedRevision == expectedRevision {
            return lastFrameURL
        }
        return try captureStillFrame(from: videoURL)
    }

    public func removeManagedFallback() {
        try? FileManager.default.removeItem(at: lastFrameURL)
        try? FileManager.default.removeItem(at: lastFrameSourceURL)
    }

    private func ensureAppSupportDirectory() throws {
        try FileManager.default.createDirectory(
            at: appSupportURL,
            withIntermediateDirectories: true
        )
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(type, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureAppSupportDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }

    private func sourceRevision(for videoURL: URL) -> LastFrameSourceRevision {
        let standardizedURL = videoURL.standardizedFileURL
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: standardizedURL.path
        )
        return LastFrameSourceRevision(
            path: standardizedURL.path,
            size: (attributes?[.size] as? NSNumber)?.uint64Value,
            modifiedAt: (attributes?[.modificationDate] as? Date)?
                .timeIntervalSince1970
        )
    }
}
