import AppKit
import AVFoundation
import CoreImage
import CoreVideo
import CryptoKit
import Darwin
import Foundation

/// Bump when shared effect pixels change, so prepared Lock-only movies do not
/// retain a previous shader/simulation after an app update.
enum WallpaperEffectsRenderRevision { static let current = 3 }

public protocol NativeEffectsMediaPreparing {
    func prepare(source: URL, settings: WallpaperEffectsSettings, speed: Double,
        scaleMode: WallpaperScaleMode, shouldProceed: @escaping @Sendable () -> Bool) async throws -> URL
}

/// A bounded, cached movie for Apple's secure Aerial renderer. Desktop keeps
/// its original media and live cursor input; this movie contains ambient FX.
actor NativeEffectsMediaPreparer: NativeEffectsMediaPreparing {
    private let directory: URL
    private let canvas: CGSize?
    private let maximumDuration: Double
    private var task: Task<URL, Error>?
    private var taskKey: String?

    init(directory: URL, canvas: CGSize? = nil, maximumDuration: Double = 30) {
        self.directory = directory; self.canvas = canvas; self.maximumDuration = maximumDuration
    }

    public func prepare(source: URL, settings: WallpaperEffectsSettings, speed: Double,
        scaleMode: WallpaperScaleMode, shouldProceed: @escaping @Sendable () -> Bool) async throws -> URL {
        try Task.checkCancellation()
        guard shouldProceed() else { throw CancellationError() }
        guard settings.enabled && settings.hasVisibleEffects else { return source }
        let size = await Self.renderSize(override: canvas)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let values = "v\(WallpaperEffectsRenderRevision.current):\(source.standardizedFileURL.path):\(attributes[.size] ?? 0):\(modified):\(size.width):\(size.height):\(speed):\(scaleMode.rawValue):\(maximumDuration)"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var input = Data(values.utf8); input.append(try encoder.encode(settings.normalized()))
        let key = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        if taskKey == key, let task {
            return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        }
        task?.cancel()
        let directory = directory, maximumDuration = maximumDuration
        let next = Task { @MainActor in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let lockURL = directory.appendingPathComponent(key + ".lock")
            let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                try Task.checkCancellation()
                guard shouldProceed() else { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(50))
            }
            let output = directory.appendingPathComponent("native-effects-v\(WallpaperEffectsRenderRevision.current)-" + key + ".mov")
            if FileManager.default.isReadableFile(atPath: output.path),
               (try? await AVURLAsset(url: output).load(.isPlayable)) == true { return output }
            let temporary = directory.appendingPathComponent(".render-\(UUID()).mov")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await Self.writeMovie(source: source, settings: settings, speed: speed,
                scaleMode: scaleMode, size: size, maximumDuration: maximumDuration,
                output: temporary, shouldProceed: shouldProceed)
            try Task.checkCancellation()
            guard shouldProceed() else { throw CancellationError() }
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: output) }
            Self.trimCache(directory: directory, keeping: output)
            return output
        }
        taskKey = key; task = next
        do {
            let result = try await withTaskCancellationHandler(operation: { try await next.value }, onCancel: { next.cancel() })
            if taskKey == key { task = nil; taskKey = nil }
            return result
        } catch {
            if taskKey == key { task = nil; taskKey = nil }
            throw error
        }
    }

    @MainActor private static func renderSize(override: CGSize?) -> CGSize {
        let screen = override ?? NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
        let ratio = override == nil ? 1920/max(screen.width, screen.height) : min(1, 1920/max(screen.width, screen.height))
        return CGSize(width: max(2, (screen.width*ratio/2).rounded()*2),
            height: max(2, (screen.height*ratio/2).rounded()*2))
    }

    @MainActor private static func writeMovie(source: URL, settings: WallpaperEffectsSettings, speed: Double,
        scaleMode: WallpaperScaleMode, size: CGSize, maximumDuration: Double, output: URL,
        shouldProceed: @escaping @Sendable () -> Bool) async throws {
        let input = try await NativeEffectsFrameReader(url: source)
        let fps: Int32 = 30
        let rate = max(0.1, min(4, speed))
        let period = input.duration/rate
        let duration = input.isImage ? min(maximumDuration, settings.hasAnimatedEffects ? 20 : 2)
            : min(maximumDuration, max(1, period))
        let frames = max(1, Int(ceil(duration*Double(fps))))
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(4_000_000, Int(size.width*size.height*6)),
                AVVideoMaxKeyFrameIntervalKey: Int(fps)*2]])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(video) else { throw CocoaError(.featureUnsupported) }
        writer.add(video)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        let renderer = try WallpaperEffectsFrameRenderer(size: size, settings: settings)
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Prepare native Lock Screen effects")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        do {
            for index in 0..<frames {
                try Task.checkCancellation()
                guard shouldProceed() else { throw CancellationError() }
                while !video.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard shouldProceed() else { throw CancellationError() }
                    guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                    try await Task.sleep(for: .milliseconds(2))
                }
                try autoreleasepool {
                    var pixel: CVPixelBuffer?
                    guard let pool = adaptor.pixelBufferPool,
                          CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
                          let pixel else { throw CocoaError(.fileWriteUnknown) }
                    let time = Double(index)/Double(fps)
                    let image = try input.frame(at: time*rate)
                    try renderer.render(image: image, into: pixel, deltaTime: 1/Double(fps), scaleMode: scaleMode)
                    guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: fps)) else {
                        throw writer.error ?? CocoaError(.fileWriteUnknown)
                    }
                }
                await Task.yield()
            }
            video.markAsFinished()
            writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: fps))
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        } catch { writer.cancelWriting(); throw error }
    }

    private static func trimCache(directory: URL, keeping output: URL) {
        let mapping = directory.deletingLastPathComponent().appendingPathComponent("native-effects-source.json")
        let data = try? Data(contentsOf: mapping)
        let active = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["renderedPath"] as? String
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let movies = files.filter { $0.lastPathComponent.hasPrefix("native-effects-v") && $0.pathExtension == "mov" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for old in movies.dropFirst(6) where old != output && old.path != active { try? FileManager.default.removeItem(at: old) }
    }
}

@MainActor private final class NativeEffectsFrameReader {
    let isImage: Bool
    let duration: Double
    private let image: CIImage?
    private let asset: AVURLAsset?
    private let track: AVAssetTrack?
    private let transform: CGAffineTransform
    private let start: Double
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: CMSampleBuffer?
    private var next: CMSampleBuffer?
    private var last = -Double.infinity

    init(url: URL) async throws {
        if WallpaperMediaKind.forURL(url).isStaticImage, let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
            self.image = image; isImage = true; duration = 20; asset = nil; track = nil; transform = .identity; start = 0
        } else {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
            let range = try await track.load(.timeRange)
            let duration = range.duration.seconds
            guard duration.isFinite && duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
            self.asset = asset; self.track = track; self.duration = duration; start = max(0, range.start.seconds)
            transform = try await track.load(.preferredTransform)
            image = nil; isImage = false
        }
    }
    func frame(at time: Double) throws -> CIImage {
        if let image { return image }
        let position = time.truncatingRemainder(dividingBy: duration) + start
        if output == nil || position < last {
            guard let asset, let track else { throw CocoaError(.fileReadCorruptFile) }
            reader?.cancelReading()
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false; reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            self.reader = reader; self.output = output; current = nil; next = output.copyNextSampleBuffer()
        }
        last = position
        while let sample = next, current == nil || CMSampleBufferGetPresentationTimeStamp(sample).seconds <= position {
            current = sample; next = output?.copyNextSampleBuffer()
        }
        guard let current, let pixel = CMSampleBufferGetImageBuffer(current) else {
            throw reader?.error ?? CocoaError(.fileReadCorruptFile)
        }
        return CIImage(cvPixelBuffer: pixel).transformed(by: transform)
    }
}
