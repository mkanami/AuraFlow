import AVFoundation
import CoreGraphics
import CoreMedia
import CryptoKit
import Foundation
import ImageIO
import VideoToolbox

enum OptimizationProfile: String, CaseIterable, Codable, Identifiable {
    case quality
    case balanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quality:
            return "Quality (HEVC)"
        case .balanced:
            return "Balanced (HEVC 1080p)"
        }
    }
}

struct VideoOptimizationSettings: Codable {
    var enabled: Bool
    var allowAV1PassthroughOnHardwareDecode: Bool
    var transcodeH264ToHEVC: Bool
    var forceSoftwareAV1Encode: Bool
    var profile: OptimizationProfile

    static let `default` = VideoOptimizationSettings(
        enabled: true,
        allowAV1PassthroughOnHardwareDecode: true,
        transcodeH264ToHEVC: true,
        forceSoftwareAV1Encode: false,
        profile: .quality
    )

    enum CodingKeys: String, CodingKey {
        case enabled
        case allowAV1PassthroughOnHardwareDecode
        case transcodeH264ToHEVC
        case forceSoftwareAV1Encode
        case profile
    }

    init(
        enabled: Bool,
        allowAV1PassthroughOnHardwareDecode: Bool,
        transcodeH264ToHEVC: Bool,
        forceSoftwareAV1Encode: Bool,
        profile: OptimizationProfile
    ) {
        self.enabled = enabled
        self.allowAV1PassthroughOnHardwareDecode = allowAV1PassthroughOnHardwareDecode
        self.transcodeH264ToHEVC = transcodeH264ToHEVC
        self.forceSoftwareAV1Encode = forceSoftwareAV1Encode
        self.profile = profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        allowAV1PassthroughOnHardwareDecode =
            try container.decodeIfPresent(Bool.self, forKey: .allowAV1PassthroughOnHardwareDecode) ?? true
        transcodeH264ToHEVC =
            try container.decodeIfPresent(Bool.self, forKey: .transcodeH264ToHEVC) ?? true
        forceSoftwareAV1Encode =
            try container.decodeIfPresent(Bool.self, forKey: .forceSoftwareAV1Encode) ?? false
        profile = try container.decodeIfPresent(OptimizationProfile.self, forKey: .profile) ?? .balanced
    }
}

enum VideoOptimizationDecision {
    case passthrough(reason: String)
    case transcode(reason: String)
}

struct VideoOptimizationResult {
    let outputURL: URL
    let decision: VideoOptimizationDecision
    let fromCache: Bool
}

enum VideoOptimizerError: LocalizedError {
    case exportUnavailable
    case exportFailed(String)
    case noVideoTrack
    case invalidAnimatedImage

    var errorDescription: String? {
        switch self {
        case .exportUnavailable:
            return "Video export is unavailable for the selected file."
        case .exportFailed(let details):
            return details.isEmpty ? "Video optimization failed." : details
        case .noVideoTrack:
            return "Video track was not found."
        case .invalidAnimatedImage:
            return "Failed to decode GIF frames."
        }
    }
}

final class VideoOptimizationStore {
    private let defaults: UserDefaults
    private let key = "auraflow.video.optimization.settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> VideoOptimizationSettings {
        guard let data = defaults.data(forKey: key) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(VideoOptimizationSettings.self, from: data)
        } catch {
            return .default
        }
    }

    func save(_ settings: VideoOptimizationSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

final class VideoOptimizer {
    private let applicationSupportName = "AuraFlow"
    private let optimizedDirectoryName = "OptimizedVideos"
    private let av1CodecType: CMVideoCodecType = CMVideoCodecType(0x61763031) // 'av01'
    private let vp9CodecType: CMVideoCodecType = CMVideoCodecType(0x76703039) // 'vp09'
    private let vp8CodecType: CMVideoCodecType = CMVideoCodecType(0x76703038) // 'vp08'
    private let gifConversionRevision = 2
    private let softwareAV1Revision = 1
    private let compatibilityTranscodeRevision = 1

    func optimizeIfNeeded(
        inputURL: URL,
        settings: VideoOptimizationSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VideoOptimizationResult {
        if isGIF(inputURL) {
            let decision = VideoOptimizationDecision.transcode(
                reason: "GIF converted to MP4 for wallpaper playback."
            )
            let outputURL = try optimizedOutputURL(
                inputURL: inputURL,
                settings: settings,
                codecType: 0,
                kindTag: "gif-r\(gifConversionRevision)"
            )
            if FileManager.default.fileExists(atPath: outputURL.path) {
                progress(1.0)
                return VideoOptimizationResult(outputURL: outputURL, decision: decision, fromCache: true)
            }
            try await convertGIFToMP4(
                inputURL: inputURL,
                outputURL: outputURL,
                settings: settings,
                progress: progress
            )
            return VideoOptimizationResult(outputURL: outputURL, decision: decision, fromCache: false)
        }

        let asset = AVURLAsset(url: inputURL)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            if isCompatibilityFFmpegCandidate(inputURL) {
                return try await transcodeToCompatibilityUsingFFmpeg(
                    inputURL: inputURL,
                    settings: settings,
                    codecType: 0,
                    reason: "Web container metadata unavailable. Converted with ffmpeg.",
                    progress: progress
                )
            }
            throw error
        }
        guard let track = tracks.first else {
            if isCompatibilityFFmpegCandidate(inputURL) {
                return try await transcodeToCompatibilityUsingFFmpeg(
                    inputURL: inputURL,
                    settings: settings,
                    codecType: 0,
                    reason: "No readable video track. Converted with ffmpeg.",
                    progress: progress
                )
            }
            throw VideoOptimizerError.noVideoTrack
        }

        let codecType = try await videoCodecType(for: track)
        let decision = makeDecision(inputURL: inputURL, codecType: codecType, settings: settings)

        switch decision {
        case .passthrough:
            return VideoOptimizationResult(outputURL: inputURL, decision: decision, fromCache: false)
        case .transcode:
            if shouldForceSoftwareAV1Encode(codecType: codecType, settings: settings) {
                let outputURL = try optimizedOutputURL(
                    inputURL: inputURL,
                    settings: settings,
                    codecType: codecType,
                    kindTag: "video-av1-sw-r\(softwareAV1Revision)"
                )
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    progress(1.0)
                    return VideoOptimizationResult(outputURL: outputURL, decision: decision, fromCache: true)
                }

                let duration = try await asset.load(.duration)
                let durationSeconds = CMTimeGetSeconds(duration)
                try await transcodeToAV1Software(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    settings: settings,
                    durationSeconds: durationSeconds.isFinite ? durationSeconds : nil,
                    progress: progress
                )
                return VideoOptimizationResult(outputURL: outputURL, decision: decision, fromCache: false)
            }

            let outputURL = try optimizedOutputURL(
                inputURL: inputURL,
                settings: settings,
                codecType: codecType
            )
            if FileManager.default.fileExists(atPath: outputURL.path) {
                progress(1.0)
                return VideoOptimizationResult(outputURL: outputURL, decision: decision, fromCache: true)
            }

            let preset = exportPreset(for: asset, settings: settings)
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
                if isCompatibilityFFmpegCandidate(inputURL) {
                    return try await transcodeToCompatibilityUsingFFmpeg(
                        inputURL: inputURL,
                        settings: settings,
                        codecType: codecType,
                        reason: "AVFoundation export unavailable. Converted with ffmpeg.",
                        progress: progress
                    )
                }
                throw VideoOptimizerError.exportUnavailable
            }

            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4
            exportSession.shouldOptimizeForNetworkUse = false

            do {
                try await export(session: exportSession, progress: progress)
            } catch {
                if isCompatibilityFFmpegCandidate(inputURL) {
                    return try await transcodeToCompatibilityUsingFFmpeg(
                        inputURL: inputURL,
                        settings: settings,
                        codecType: codecType,
                        reason: "AVFoundation export failed. Converted with ffmpeg.",
                        progress: progress
                    )
                }
                throw error
            }
            return VideoOptimizationResult(outputURL: outputURL, decision: decision, fromCache: false)
        }
    }

    private func makeDecision(
        inputURL: URL,
        codecType: CMVideoCodecType,
        settings: VideoOptimizationSettings
    ) -> VideoOptimizationDecision {
        guard settings.enabled else {
            return .passthrough(reason: "Optimization disabled.")
        }

        if isWebContainer(inputURL) || codecType == vp9CodecType || codecType == vp8CodecType {
            return .transcode(reason: "Web video converted for macOS wallpaper compatibility.")
        }

        if shouldForceSoftwareAV1Encode(codecType: codecType, settings: settings) {
            return .transcode(reason: "Force AV1 software encode enabled.")
        }

        if codecType == av1CodecType {
            if supportsHardwareAV1Decode() && settings.allowAV1PassthroughOnHardwareDecode {
                return .passthrough(reason: "AV1 hardware decode detected. Keeping source codec.")
            }
            return .transcode(reason: "AV1 hardware decode unavailable. Converting to HEVC.")
        }

        if codecType == kCMVideoCodecType_H264 && settings.transcodeH264ToHEVC {
            return .transcode(reason: "H.264 selected for HEVC optimization.")
        }

        return .passthrough(reason: "Source codec already acceptable for playback.")
    }

    private func isWebContainer(_ inputURL: URL) -> Bool {
        let ext = inputURL.pathExtension.lowercased()
        return ext == "webm" || ext == "mkv"
    }

    private func isCompatibilityFFmpegCandidate(_ inputURL: URL) -> Bool {
        isWebContainer(inputURL)
    }

    private func transcodeToCompatibilityUsingFFmpeg(
        inputURL: URL,
        settings: VideoOptimizationSettings,
        codecType: CMVideoCodecType,
        reason: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VideoOptimizationResult {
        guard let ffmpeg = resolveFFmpegExecutableForCompatibility() else {
            throw VideoOptimizerError.exportFailed(
                "This video requires ffmpeg conversion. Install ffmpeg (brew install ffmpeg) and retry."
            )
        }

        let decision = VideoOptimizationDecision.transcode(reason: reason)
        let outputURL = try optimizedOutputURL(
            inputURL: inputURL,
            settings: settings,
            codecType: codecType,
            kindTag: "video-compat-r\(compatibilityTranscodeRevision)"
        )
        if FileManager.default.fileExists(atPath: outputURL.path) {
            progress(1.0)
            return VideoOptimizationResult(outputURL: outputURL, decision: decision, fromCache: true)
        }

        let duration = try? await AVURLAsset(url: inputURL).load(.duration)
        let seconds = duration.map(CMTimeGetSeconds)
        let durationSeconds = (seconds?.isFinite == true) ? seconds : nil

        try await transcodeToH264Compatibility(
            ffmpegExecutable: ffmpeg,
            inputURL: inputURL,
            outputURL: outputURL,
            settings: settings,
            durationSeconds: durationSeconds,
            progress: progress
        )
        return VideoOptimizationResult(outputURL: outputURL, decision: decision, fromCache: false)
    }

    func supportsHardwareAV1Decode() -> Bool {
        if #available(macOS 14.0, *) {
            return VTIsHardwareDecodeSupported(av1CodecType)
        }
        return false
    }

    private func shouldForceSoftwareAV1Encode(
        codecType: CMVideoCodecType,
        settings: VideoOptimizationSettings
    ) -> Bool {
        if codecType == av1CodecType {
            return false
        }
        return settings.forceSoftwareAV1Encode && supportsHardwareAV1Decode()
    }

    private func exportPreset(for asset: AVAsset, settings: VideoOptimizationSettings) -> String {
        let available = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let preferred: [String]
        switch settings.profile {
        case .quality:
            preferred = [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality]
        case .balanced:
            preferred = [
                AVAssetExportPresetHEVCHighestQuality,
                AVAssetExportPresetHEVC1920x1080,
                AVAssetExportPresetHighestQuality,
            ]
        }
        for candidate in preferred where available.contains(candidate) {
            return candidate
        }
        return AVAssetExportPresetHighestQuality
    }

    private func export(
        session: AVAssetExportSession,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        progress(0.0)
        let progressTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                let status = session.status
                progress(Double(session.progress))
                if status != .waiting && status != .exporting {
                    break
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        await withCheckedContinuation { continuation in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        progressTask.cancel()

        switch session.status {
        case .completed:
            progress(1.0)
            return
        case .failed, .cancelled:
            let details = session.error?.localizedDescription ?? "Unknown export error."
            throw VideoOptimizerError.exportFailed(details)
        default:
            throw VideoOptimizerError.exportFailed("Unexpected export state: \(session.status.rawValue)")
        }
    }

    private func transcodeToAV1Software(
        ffmpegExecutable: String? = nil,
        inputURL: URL,
        outputURL: URL,
        settings: VideoOptimizationSettings,
        durationSeconds: Double?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let resolvedFFmpeg = ffmpegExecutable ?? resolveFFmpegExecutableForAV1()
        guard let ffmpeg = resolvedFFmpeg else {
            throw VideoOptimizerError.exportFailed(
                "Force AV1 requires ffmpeg with libsvtav1/libaom-av1 (install via Homebrew)."
            )
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        let arguments = ffmpegArgumentsForSoftwareAV1(
            inputURL: inputURL,
            outputURL: outputURL,
            settings: settings
        )
        try await runFFmpegProcess(
            executable: ffmpeg,
            arguments: arguments,
            durationSeconds: durationSeconds,
            failurePrefix: "AV1 software encode failed",
            launchFailureMessage: "Unable to start ffmpeg for AV1 software encode.",
            progress: progress
        )
    }

    private func transcodeToH264Compatibility(
        ffmpegExecutable: String,
        inputURL: URL,
        outputURL: URL,
        settings: VideoOptimizationSettings,
        durationSeconds: Double?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        let arguments = ffmpegArgumentsForCompatibility(
            inputURL: inputURL,
            outputURL: outputURL,
            settings: settings
        )
        try await runFFmpegProcess(
            executable: ffmpegExecutable,
            arguments: arguments,
            durationSeconds: durationSeconds,
            failurePrefix: "Compatibility transcode failed",
            launchFailureMessage: "Unable to start ffmpeg for compatibility transcode.",
            progress: progress
        )
    }

    private func runFFmpegProcess(
        executable: String,
        arguments: [String],
        durationSeconds: Double?,
        failurePrefix: String,
        launchFailureMessage: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let safeDuration = max(durationSeconds ?? 0, 0)
        final class StderrBufferState {
            let lock = NSLock()
            var data = Data()
        }
        let bufferState = StderrBufferState()

        progress(0.0)
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    return
                }
                bufferState.lock.lock()
                defer { bufferState.lock.unlock() }

                bufferState.data.append(chunk)
                while let newline = bufferState.data.firstIndex(of: 0x0A) {
                    let lineData = Data(bufferState.data.prefix(upTo: newline))
                    bufferState.data.removeSubrange(...newline)
                    guard
                        let line = String(data: lineData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        !line.isEmpty
                    else {
                        continue
                    }
                    if line.hasPrefix("out_time_ms=") {
                        let rawValue = line.dropFirst("out_time_ms=".count)
                        if let microseconds = Double(rawValue), safeDuration > 0 {
                            let seconds = microseconds / 1_000_000.0
                            let value = min(max(seconds / safeDuration, 0.0), 0.98)
                            progress(value)
                        } else {
                            progress(0.5)
                        }
                    } else if line == "progress=end" {
                        progress(0.99)
                    }
                }
            }

            process.terminationHandler = { proc in
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    progress(1.0)
                    continuation.resume()
                    return
                }

                let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let details = String(data: stderrTail, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let message = details.isEmpty
                    ? "\(failurePrefix)."
                    : "\(failurePrefix): \(details)"
                continuation.resume(throwing: VideoOptimizerError.exportFailed(message))
            }

            do {
                try process.run()
            } catch {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(
                    throwing: VideoOptimizerError.exportFailed(launchFailureMessage)
                )
            }
        }
    }

    private func ffmpegArgumentsForSoftwareAV1(
        inputURL: URL,
        outputURL: URL,
        settings: VideoOptimizationSettings
    ) -> [String] {
        var args: [String] = [
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-progress",
            "pipe:2",
            "-i",
            inputURL.path,
            "-map_metadata",
            "-1",
            "-an",
            "-sn",
            "-dn",
            "-pix_fmt",
            "yuv420p",
            "-c:v",
            "libsvtav1",
        ]

        switch settings.profile {
        case .quality:
            args.append(contentsOf: ["-preset", "6", "-crf", "30"])
        case .balanced:
            args.append(contentsOf: ["-preset", "8", "-crf", "34"])
            args.append(contentsOf: ["-vf", "scale=if(gt(iw\\,1920)\\,1920\\,iw):-2"])
        }

        args.append(contentsOf: ["-movflags", "+faststart", "-f", "mp4", outputURL.path])
        return args
    }

    private func ffmpegArgumentsForCompatibility(
        inputURL: URL,
        outputURL: URL,
        settings: VideoOptimizationSettings
    ) -> [String] {
        var args: [String] = [
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-progress",
            "pipe:2",
            "-i",
            inputURL.path,
            "-map_metadata",
            "-1",
            "-an",
            "-sn",
            "-dn",
            "-pix_fmt",
            "yuv420p",
            "-c:v",
            "libx264",
        ]

        switch settings.profile {
        case .quality:
            args.append(contentsOf: ["-preset", "slow", "-crf", "17"])
        case .balanced:
            args.append(contentsOf: ["-preset", "medium", "-crf", "19"])
        }

        args.append(contentsOf: ["-movflags", "+faststart", "-f", "mp4", outputURL.path])
        return args
    }

    private func ffmpegCandidateExecutables() -> [String] {
        let env = ProcessInfo.processInfo.environment["AURAFLOW_FFMPEG_PATH"] ?? ""
        var candidates: [String] = []
        if !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(env)
        }
        if let bundled = bundledToolExecutable(named: "ffmpeg") {
            candidates.append(bundled.path)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ])
        if let fromPath = resolveBinaryFromPATH("ffmpeg") {
            candidates.append(fromPath)
        }
        return candidates
    }

    private func resolveFFmpegExecutableForCompatibility() -> String? {
        let candidates = ffmpegCandidateExecutables()
        var seen = Set<String>()
        for candidate in candidates where !candidate.isEmpty {
            if seen.contains(candidate) {
                continue
            }
            seen.insert(candidate)
            guard FileManager.default.isExecutableFile(atPath: candidate) else {
                continue
            }
            return candidate
        }
        return nil
    }

    private func bundledToolExecutable(named name: String) -> URL? {
        let bundle = Bundle.main

        if let direct = bundle.resourceURL?.appendingPathComponent("BundledTools/\(name)"),
           FileManager.default.isExecutableFile(atPath: direct.path) {
            return direct
        }

        if let bundledBundle = bundle.resourceURL?.appendingPathComponent("WallpaperControlApp.bundle"),
           let nested = bundledBundle.appendingPathComponent("Contents/Resources/BundledTools/\(name)") as URL?,
           FileManager.default.isExecutableFile(atPath: nested.path) {
            return nested
        }

        return nil
    }

    private func resolveFFmpegExecutableForAV1() -> String? {
        let candidates = ffmpegCandidateExecutables()
        var seen = Set<String>()
        for candidate in candidates where !candidate.isEmpty {
            if seen.contains(candidate) {
                continue
            }
            seen.insert(candidate)
            guard FileManager.default.isExecutableFile(atPath: candidate) else {
                continue
            }
            if ffmpegSupportsAV1Encoding(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func resolveBinaryFromPATH(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let output, !output.isEmpty else {
            return nil
        }
        return output
    }

    private func ffmpegSupportsAV1Encoding(_ executable: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return false
        }
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?.lowercased() ?? ""
        return output.contains("libsvtav1") || output.contains("libaom-av1")
    }

    private func videoCodecType(for track: AVAssetTrack) async throws -> CMVideoCodecType {
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else {
            return 0
        }
        return CMFormatDescriptionGetMediaSubType(description)
    }

    private func optimizedOutputURL(
        inputURL: URL,
        settings: VideoOptimizationSettings,
        codecType: CMVideoCodecType,
        kindTag: String = "video"
    ) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent(applicationSupportName, isDirectory: true)
            .appendingPathComponent(optimizedDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let metadata = try FileManager.default.attributesOfItem(atPath: inputURL.path)
        let fileSize = (metadata[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (metadata[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let signature = [
            kindTag,
            inputURL.path,
            String(fileSize),
            String(modified),
            settings.enabled.description,
            settings.allowAV1PassthroughOnHardwareDecode.description,
            settings.transcodeH264ToHEVC.description,
            settings.forceSoftwareAV1Encode.description,
            settings.profile.rawValue,
            String(codecType),
        ].joined(separator: "|")

        let hash = SHA256.hash(data: Data(signature.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("\(hash).mp4")
    }

    private func isGIF(_ inputURL: URL) -> Bool {
        inputURL.pathExtension.lowercased() == "gif"
    }

    private func convertGIFToMP4(
        inputURL: URL,
        outputURL: URL,
        settings: VideoOptimizationSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.convertGIFToMP4Sync(
                        inputURL: inputURL,
                        outputURL: outputURL,
                        settings: settings,
                        progress: progress
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func convertGIFToMP4Sync(
        inputURL: URL,
        outputURL: URL,
        settings: VideoOptimizationSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        guard let imageSource = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else {
            throw VideoOptimizerError.invalidAnimatedImage
        }

        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 0 else {
            throw VideoOptimizerError.invalidAnimatedImage
        }

        guard let firstFrame = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw VideoOptimizerError.invalidAnimatedImage
        }

        let width = Self.evenDimension(firstFrame.width)
        let height = Self.evenDimension(firstFrame.height)
        let bitrate = Self.gifBitrate(width: width, height: height, profile: settings.profile)

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: 30,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        guard writer.canAdd(writerInput) else {
            throw VideoOptimizerError.exportFailed("Unable to initialize GIF writer input.")
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            let details = writer.error?.localizedDescription ?? "Unable to start GIF conversion."
            throw VideoOptimizerError.exportFailed(details)
        }
        writer.startSession(atSourceTime: .zero)

        progress(0.0)
        var presentationTime = CMTime.zero
        let timescale: Int32 = 600

        for index in 0..<frameCount {
            guard let frame = CGImageSourceCreateImageAtIndex(imageSource, index, nil) else {
                throw VideoOptimizerError.invalidAnimatedImage
            }
            let delay = Self.gifFrameDuration(source: imageSource, index: index)
            let frameDuration = CMTime(seconds: delay, preferredTimescale: timescale)

            while !writerInput.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }

            guard let buffer = Self.makePixelBuffer(
                from: frame,
                width: width,
                height: height,
                pool: adaptor.pixelBufferPool
            ) else {
                throw VideoOptimizerError.exportFailed("Unable to encode GIF frame \(index + 1).")
            }
            if !adaptor.append(buffer, withPresentationTime: presentationTime) {
                let details = writer.error?.localizedDescription ?? "GIF frame append failed."
                throw VideoOptimizerError.exportFailed(details)
            }

            presentationTime = CMTimeAdd(presentationTime, frameDuration)
            progress(Double(index + 1) / Double(frameCount))
        }

        writerInput.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        if writer.status != .completed {
            let details = writer.error?.localizedDescription ?? "GIF conversion failed."
            throw VideoOptimizerError.exportFailed(details)
        }
        progress(1.0)
    }

    private static func gifFrameDuration(source: CGImageSource, index: Int) -> Double {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else {
            return 0.1
        }

        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        let duration = unclamped ?? clamped ?? 0.1
        if duration < 0.011 {
            return 0.1
        }
        return max(0.02, min(duration, 0.5))
    }

    private static func makePixelBuffer(
        from image: CGImage,
        width: Int,
        height: Int,
        pool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        guard let pool else {
            return nil
        }

        var maybeBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer)
        guard status == kCVReturnSuccess, let buffer = maybeBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return buffer
    }

    private static func gifBitrate(width: Int, height: Int, profile: OptimizationProfile) -> Int {
        let pixelCount = max(width * height, 1)
        switch profile {
        case .quality:
            return min(max(pixelCount * 8, 2_000_000), 28_000_000)
        case .balanced:
            return min(max(pixelCount * 5, 1_200_000), 18_000_000)
        }
    }

    private static func evenDimension(_ value: Int) -> Int {
        let clamped = max(value, 2)
        return clamped.isMultiple(of: 2) ? clamped : clamped - 1
    }
}
