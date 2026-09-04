import AppKit
import AVFoundation
import CoreMedia
import Foundation
import UniformTypeIdentifiers

private struct AerialConversionResult: Sendable {
    let terminationStatus: Int32
    let standardError: Data
}

/// Bridges Process termination into async/await without blocking a Swift
/// concurrency executor. Process and Pipe are Foundation reference types with
/// no useful Sendable annotations, so this small state holder serializes their
/// access at the boundary where Foundation invokes the termination callback.
private final class AerialConversionProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private let errorPipe: Pipe
    private var continuation:
        CheckedContinuation<AerialConversionResult, Error>?
    private var process: Process?
    private var cancellationRequested = false
    private var finished = false

    init(errorPipe: Pipe) {
        self.errorPipe = errorPipe
    }

    func register(
        process: Process,
        continuation: CheckedContinuation<AerialConversionResult, Error>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !cancellationRequested, !finished else {
            return false
        }
        self.process = process
        self.continuation = continuation
        return true
    }

    func didStart(_ process: Process) {
        lock.lock()
        let shouldTerminate = cancellationRequested && !finished
        lock.unlock()

        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let process = self.process
        let shouldTerminate = !finished && process?.isRunning == true
        lock.unlock()

        if shouldTerminate {
            process?.terminate()
        }
    }

    func didTerminate(_ process: Process) {
        let standardError = errorPipe.fileHandleForReading.readDataToEndOfFile()
        finish(
            result: AerialConversionResult(
                terminationStatus: process.terminationStatus,
                standardError: standardError
            )
        )
    }

    func didFail(_ error: Error) {
        finish(error: error)
    }

    private func finish(result: AerialConversionResult? = nil, error: Error? = nil) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        let wasCancelled = cancellationRequested
        self.continuation = nil
        self.process = nil
        lock.unlock()

        guard let continuation else { return }
        if wasCancelled {
            continuation.resume(throwing: CancellationError())
        } else if let error {
            continuation.resume(throwing: error)
        } else if let result {
            continuation.resume(returning: result)
        } else {
            continuation.resume(
                throwing: AerialLockScreenInstallerError
                    .aerialVideoPreparationFailed(
                        "The conversion process ended without a result."
                    )
            )
        }
    }
}

/// Prepares media for the native macOS Aerial Lock Screen provider.
///
/// The native provider accepts HEVC video in a QuickTime movie. Noncanonical
/// wallpaper stores are used by the test and fallback routes and retain the
/// source media unchanged.
internal final class AerialMediaPreparer {
    private let fileManager: FileManager
    private let usesCanonicalWallpaperStore: Bool
    private let preparedCacheDirectoryURL: URL
    private let conversionExecutableURL: URL

    internal init(
        fileManager: FileManager,
        usesCanonicalWallpaperStore: Bool,
        preparedCacheDirectoryURL: URL,
        conversionExecutableURL: URL = URL(
            fileURLWithPath: "/usr/bin/avconvert"
        )
    ) {
        self.fileManager = fileManager
        self.usesCanonicalWallpaperStore = usesCanonicalWallpaperStore
        self.preparedCacheDirectoryURL = preparedCacheDirectoryURL
        self.conversionExecutableURL = conversionExecutableURL
    }

    internal func prepare(from sourceURL: URL) async throws -> URL {
        try Task.checkCancellation()
        guard usesCanonicalWallpaperStore else {
            return sourceURL
        }

        guard !(try await isCompatible(at: sourceURL)) else {
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
           try await isCompatible(at: cacheURL) {
            return cacheURL
        }

        let outputURL = preparedCacheDirectoryURL.appendingPathComponent(
            ".prepared-\(UUID().uuidString).mov"
        )
        defer { try? fileManager.removeItem(at: outputURL) }

        if let image = NSImage(contentsOf: sourceURL) {
            try await writeStillImageAerialVideo(image, to: outputURL)
            guard try await isCompatible(at: outputURL) else {
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
        process.executableURL = conversionExecutableURL
        process.arguments = [
            "--source", sourceURL.path,
            "--preset", "PresetHEVCHighestQuality",
            "--output", outputURL.path,
            "--replace",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            let result = try await waitForConversion(
                process,
                errorPipe: errorPipe
            )

            guard result.terminationStatus == 0,
                  fileManager.fileExists(atPath: outputURL.path),
                  try await isCompatible(at: outputURL)
            else {
                let detail = String(
                    data: result.standardError,
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw AerialLockScreenInstallerError
                    .aerialVideoPreparationFailed(
                        detail?.isEmpty == false
                            ? detail!
                            : "HEVC QuickTime conversion failed."
                    )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(error.localizedDescription)
        }

        try replaceCacheItem(at: cacheURL, with: outputURL)
        return cacheURL
    }

    private func waitForConversion(
        _ process: Process,
        errorPipe: Pipe
    ) async throws -> AerialConversionResult {
        let state = AerialConversionProcessState(errorPipe: errorPipe)

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard state.register(
                    process: process,
                    continuation: continuation
                ) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                process.terminationHandler = { [state] process in
                    state.didTerminate(process)
                }

                do {
                    try process.run()
                    state.didStart(process)
                } catch {
                    process.terminationHandler = nil
                    state.didFail(error)
                }
            }
        }, onCancel: {
            state.cancel()
        })
    }

    /// Returns true only for a local QuickTime movie whose first video track
    /// uses HEVC.
    internal func isCompatible(at url: URL) async throws -> Bool {
        try Task.checkCancellation()
        guard url.isFileURL,
              let contentType = UTType(filenameExtension: url.pathExtension),
              contentType.conforms(to: .quickTimeMovie)
        else {
            return false
        }

        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.load(.tracks)
            guard let videoTrack = tracks.first(where: {
                $0.mediaType == .video
            }) else {
                return false
            }
            let formatDescriptions = try await videoTrack.load(
                .formatDescriptions
            )
            guard let firstDescription = formatDescriptions.first else {
                return false
            }
            return CMFormatDescriptionGetMediaSubType(firstDescription)
                == kCMVideoCodecType_HEVC
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // An unreadable or incomplete asset is not compatible.
            return false
        }
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
    ) async throws {
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
                do {
                    try await Task.sleep(nanoseconds: 2_000_000)
                } catch {
                    writer.cancelWriting()
                    throw error
                }
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
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
        try Task.checkCancellation()
        guard writer.status == .completed
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
