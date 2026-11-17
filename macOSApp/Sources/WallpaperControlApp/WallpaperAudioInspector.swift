import AuraWallpaperCore
import AVFoundation
import Foundation

enum WallpaperAudioContent: String, Codable, Sendable {
    case audible, silent, noTrack, unknown

    var containsSound: Bool { self == .audible }
    var isSilent: Bool { self == .silent || self == .noTrack }
    var explanation: String {
        switch self {
        case .silent: "This wallpaper's audio track contains silence."
        case .noTrack: "This wallpaper has no audio track."
        case .audible, .unknown: "Volume for the preview and installed wallpaper. Preview music pauses when hidden; Desktop music pauses for visible app windows. Zero mutes audio."
        }
    }
}

/// Decodes audio without playing it. Container metadata alone also matches
/// the empty AAC tracks included in many live-wallpaper downloads.
enum WallpaperAudioInspector {
    static func inspect(url: URL, windows: [Range<Double>]? = nil, complete: Bool = true) async throws -> WallpaperAudioContent {
        let task = Task.detached(priority: .utility) {
            try await decode(url: WallpaperAudioAttachment.source(for: url), windows: windows, complete: complete)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func decode(url: URL, windows: [Range<Double>]?, complete: Bool) async throws -> WallpaperAudioContent {
        guard url.isFileURL else { return .unknown }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return .noTrack }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { return .unknown }
        // A long silent introduction is not proof that the entire clip is
        // silent. Sample three positions and leave an inconclusive clip unknown.
        let requested = windows ?? (duration <= 30 ? [0..<duration] : [0..<5, (duration / 2)..<(duration / 2 + 5), (duration - 5)..<duration])
        let ranges = requested.prefix(3).map { $0.lowerBound..<min($0.upperBound, $0.lowerBound + (requested.count == 1 ? 30 : 10)) }
        let fullyScanned = complete && requested == ranges && (windows != nil || duration <= 30)
        var decodedSamples = false
        for track in tracks {
            for range in ranges {
                try Task.checkCancellation()
                let reader = try AVAssetReader(asset: asset)
                defer { reader.cancelReading() }
                let start = max(0, range.lowerBound), end = min(duration, range.upperBound)
                guard start.isFinite, end.isFinite, end > start else { return .unknown }
                reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60_000),
                    duration: CMTime(seconds: end - start, preferredTimescale: 60_000))
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                    AVLinearPCMIsBigEndianKey: false,
                ])
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { return .unknown }
                reader.add(output)
                guard reader.startReading() else { return .unknown }
                while let sample = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    guard let block = CMSampleBufferGetDataBuffer(sample) else { return .unknown }
                    let length = CMBlockBufferGetDataLength(block)
                    guard length > 0, length <= 1_048_576, length.isMultiple(of: MemoryLayout<Float>.size) else { return .unknown }
                    var copyResult: OSStatus = noErr
                    let values = [Float](unsafeUninitializedCapacity: length / MemoryLayout<Float>.size) { buffer, count in
                        copyResult = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
                        count = copyResult == noErr ? buffer.count : 0
                    }
                    guard copyResult == noErr else { return .unknown }
                    decodedSamples = true
                    // -80 dBFS peak rejects digital silence and codec residue,
                    // while retaining very quiet music and ambient recordings.
                    if values.contains(where: { $0.isFinite && abs($0) > 0.0001 }) { return .audible }
                }
                guard reader.status == .completed else { return .unknown }
            }
        }
        return fullyScanned && decodedSamples ? .silent : .unknown
    }
}
