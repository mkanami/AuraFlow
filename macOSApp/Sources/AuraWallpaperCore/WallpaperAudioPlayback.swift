import AVFoundation
import Foundation

/// Music has its own audio-only timeline. Video can keep moving behind a
/// window while this player pauses, retaining the exact music position.
@MainActor public final class WallpaperAudioPlayback {
    private struct Source: Equatable {
        let url: URL
        let size: Int64?
        let modified: Date?
    }
    private var source: Source?
    private var generation: UInt = 0
    private var preparation: Task<Void, Never>?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var volume: Float = 0
    public private(set) var errorDescription: String?
    public var isPrepared: Bool { player != nil }
    public var rate: Float { player?.rate ?? 0 }
    public var time: Double? {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return nil }
        return seconds
    }

    public init() {}
    deinit { preparation?.cancel() }

    public func setSource(_ url: URL?) {
        let next = url.map(WallpaperAudioAttachment.source).map { url -> Source in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return Source(url: url.standardizedFileURL, size: (attributes?[.size] as? NSNumber)?.int64Value,
                modified: attributes?[.modificationDate] as? Date)
        }
        guard source != next else { return }
        stop()
        source = next
        prepareIfNeeded()
    }

    /// A zero effective volume pauses rather than silently advancing time.
    public func update(volume: Float) {
        self.volume = Float(WallpaperAudioPolicy.normalized(Double(volume)))
        prepareIfNeeded()
        apply()
    }

    public func stop() {
        generation &+= 1
        preparation?.cancel(); preparation = nil
        player?.pause()
        looper?.disableLooping(); looper = nil
        player?.removeAllItems(); player = nil
        source = nil
        errorDescription = nil
    }

    private func prepareIfNeeded() {
        guard volume > 0, let source, player == nil, preparation == nil, errorDescription == nil else { return }
        let revision = generation
        preparation = Task { [weak self] in
            do {
                let composition = try await Self.audioComposition(for: source.url)
                try Task.checkCancellation()
                guard let self, self.generation == revision else { return }
                self.preparation = nil
                guard let composition else { self.errorDescription = "No audio track"; return }
                let player = AVQueuePlayer()
                player.volume = 0
                player.isMuted = true
                player.actionAtItemEnd = .none
                self.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: composition))
                self.player = player
                self.apply()
            } catch {
                guard !Task.isCancelled, let self, self.generation == revision else { return }
                self.preparation = nil
                self.errorDescription = error.localizedDescription
            }
        }
    }

    private func apply() {
        player?.volume = volume
        player?.isMuted = volume == 0
        if volume == 0 { player?.pause() }
        else if player?.rate == 0 { player?.playImmediately(atRate: 1) }
    }

    /// Selecting only the audio track avoids a second video decoder/GPU path.
    static func audioComposition(for url: URL) async throws -> AVMutableComposition? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let range = try await track.load(.timeRange)
        try Task.checkCancellation()
        guard range.isValid, range.duration.seconds.isFinite, range.duration.seconds > 0 else { return nil }
        let composition = AVMutableComposition()
        guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        try audio.insertTimeRange(range, of: track, at: CMTimeMaximum(.zero, range.start))
        return composition
    }
}
