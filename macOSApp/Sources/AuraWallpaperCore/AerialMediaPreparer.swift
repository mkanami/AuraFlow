import AppKit
import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers

/// Prepares media for the native macOS Aerial Lock Screen provider.
///
/// The native provider accepts HEVC video in a QuickTime movie. Noncanonical
/// wallpaper stores are used by the test and fallback routes and retain the
/// source media unchanged.
internal final class AerialMediaPreparer {
    private let fileManager: FileManager
    private let usesCanonicalWallpaperStore: Bool
    private let preparedCacheDirectoryURL: URL

    internal init(
        fileManager: FileManager,
        usesCanonicalWallpaperStore: Bool,
        preparedCacheDirectoryURL: URL
    ) {
        self.fileManager = fileManager
        self.usesCanonicalWallpaperStore = usesCanonicalWallpaperStore
        self.preparedCacheDirectoryURL = preparedCacheDirectoryURL
    }

    internal func prepare(from sourceURL: URL) throws -> URL {
        guard usesCanonicalWallpaperStore else {
            return sourceURL
        }

        guard !isCompatible(at: sourceURL) else {
            return sourceURL
        }

        try fileManager.createDirectory(
            at: preparedCacheDirectoryURL,
            withIntermediateDirectories: true
        )

        // Keep the prepared result keyed by the source signature so reopening
        // Settings, restarting the agent, or switching back to a wallpaper
        // does not transcode the same file again.
        let sourceSignature = try fileSignature(at: sourceURL)
        let cacheURL = preparedCacheDirectoryURL.appendingPathComponent(
            "prepared-v2-\(sourceSignature).mov"
        )
        if fileManager.fileExists(atPath: cacheURL.path),
           isCompatible(at: cacheURL) {
            return cacheURL
        }

        let outputURL = preparedCacheDirectoryURL.appendingPathComponent(
            ".prepared-\(UUID().uuidString).mov"
        )
        defer { try? fileManager.removeItem(at: outputURL) }

        if let image = NSImage(contentsOf: sourceURL) {
            try writeStillImageAerialVideo(image, to: outputURL)
            guard isCompatible(at: outputURL) else {
                throw AerialLockScreenInstallerError
                    .aerialVideoPreparationFailed(
                        "The prepared image video is not HEVC compatible."
                    )
            }
            try replaceCacheItem(at: cacheURL, with: outputURL)
            return cacheURL
        }

        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/avconvert")
        process.arguments = [
            "--source", sourceURL.path,
            "--preset", "PresetHEVCHighestQuality",
            "--output", outputURL.path,
            "--replace",
        ]
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0,
              fileManager.fileExists(atPath: outputURL.path),
              isCompatible(at: outputURL)
        else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(
                    detail?.isEmpty == false
                        ? detail!
                        : "HEVC QuickTime conversion failed."
                )
        }

        try replaceCacheItem(at: cacheURL, with: outputURL)
        return cacheURL
    }

    /// Returns true only for a local QuickTime movie whose first video track
    /// uses HEVC. The synchronous boundary is intentional because the
    /// installer performs this check while it holds its operation lock.
    internal func isCompatible(at url: URL) -> Bool {
        guard url.isFileURL,
              let contentType = UTType(filenameExtension: url.pathExtension),
              contentType.conforms(to: .quickTimeMovie)
        else {
            return false
        }

        let asset = AVURLAsset(url: url)
        let completion = DispatchSemaphore(value: 0)
        final class CompatibilityResult: @unchecked Sendable {
            var value = false
        }
        let result = CompatibilityResult()

        let compatibilityTask = Task.detached(priority: .utility) {
            defer { completion.signal() }
            do {
                let tracks = try await asset.load(.tracks)
                guard let videoTrack = tracks.first(where: {
                    $0.mediaType == .video
                }) else {
                    return
                }
                let formatDescriptions = try await videoTrack.load(
                    .formatDescriptions
                )
                guard let firstDescription = formatDescriptions.first else {
                    return
                }
                result.value = CMFormatDescriptionGetMediaSubType(
                    firstDescription
                ) == kCMVideoCodecType_HEVC
            } catch {
                // An unreadable or incomplete asset is not compatible.
            }
        }

        guard completion.wait(timeout: .now() + 10) == .success else {
            compatibilityTask.cancel()
            asset.cancelLoading()
            return false
        }
        return result.value
    }

    /// Returns the stable size + prefix + suffix FNV-like signature used for
    /// prepared-media cache keys and installer state validation.
    internal func fileSignature(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let sampleSize = 64 * 1_024
        let prefix = try handle.read(upToCount: sampleSize) ?? Data()
        let suffixOffset =
            size > UInt64(sampleSize) ? size - UInt64(sampleSize) : 0
        try handle.seek(toOffset: suffixOffset)
        let suffix = try handle.read(upToCount: sampleSize) ?? Data()

        var hash: UInt64 = 14_695_981_039_346_656_037
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        withUnsafeBytes(of: size.littleEndian) { bytes in
            for byte in bytes {
                mix(byte)
            }
        }
        for byte in prefix {
            mix(byte)
        }
        for byte in suffix {
            mix(byte)
        }
        return String(format: "%016llx", hash)
    }

    private func replaceCacheItem(at cacheURL: URL, with outputURL: URL) throws {
        if fileManager.fileExists(atPath: cacheURL.path) {
            try fileManager.removeItem(at: cacheURL)
        }
        try fileManager.moveItem(at: outputURL, to: cacheURL)
    }

    private func writeStillImageAerialVideo(
        _ image: NSImage,
        to outputURL: URL
    ) throws {
        guard let sourceImage = image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed("The image could not be decoded.")
        }

        let maximumWidth = 3840.0
        let maximumHeight = 2160.0
        let scale = min(
            1.0,
            maximumWidth / Double(sourceImage.width),
            maximumHeight / Double(sourceImage.height)
        )
        func evenDimension(_ value: Int) -> Int {
            max(2, value - value % 2)
        }
        let width = evenDimension(
            Int((Double(sourceImage.width) * scale).rounded())
        )
        let height = evenDimension(
            Int((Double(sourceImage.height) * scale).rounded())
        )

        try? fileManager.removeItem(at: outputURL)
        let writer = try AVAssetWriter(
            outputURL: outputURL,
            fileType: .mov
        )
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoAverageBitRateKey: max(
                        2_000_000,
                        min(20_000_000, width * height * 2)
                    ),
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else {
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(
                    "The HEVC image writer could not be initialized."
                )
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(
                    writer.error?.localizedDescription
                        ?? "The HEVC image writer could not start."
                )
        }
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        let bufferStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary,
            &pixelBuffer
        )
        guard bufferStatus == kCVReturnSuccess,
              let pixelBuffer
        else {
            writer.cancelWriting()
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(
                    "The image video pixel buffer could not be created."
                )
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            writer.cancelWriting()
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(
                    "The image video frame could not be rendered."
                )
        }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(
            sourceImage,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )

        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData,
                  writer.status == .writing {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard writer.status == .writing,
                  adaptor.append(
                      pixelBuffer,
                      withPresentationTime: CMTime(
                          value: Int64(frame),
                          timescale: 30
                      )
                  )
            else {
                writer.cancelWriting()
                throw AerialLockScreenInstallerError
                    .aerialVideoPreparationFailed(
                        writer.error?.localizedDescription
                            ?? "The image video frame could not be encoded."
                    )
            }
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 30) == .success,
              writer.status == .completed
        else {
            writer.cancelWriting()
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(
                    writer.error?.localizedDescription
                        ?? "The image video could not be finalized."
                )
        }
    }
}
