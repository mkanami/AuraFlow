import AVKit
import Combine
import Foundation

struct WallpaperPreviewSeed: Codable, Equatable {
    let video_path: String
    let playback_speed: Double
    let scale_mode: String?
}

/// Presentation state for the wallpaper preview.
///
/// The application model still coordinates optimization and runtime commits,
/// while this object owns the values that describe what the preview displays.
@MainActor
final class PreviewViewModel: ObservableObject {
    private let previewStateURL: URL

    @Published var appliedVideoURL: URL?
    @Published var pendingVideoURL: URL?
    @Published var playbackSpeed: Double = 1.0
    @Published var player: AVPlayer?
    @Published var scaleMode: WallpaperScaleMode = .fill

    init(previewStateURL: URL) {
        self.previewStateURL = previewStateURL
    }

    var selectedVideoURL: URL? {
        pendingVideoURL ?? appliedVideoURL
    }

    func selectPendingVideo(_ url: URL) {
        pendingVideoURL = url
    }

    func clearPendingVideo() {
        pendingVideoURL = nil
    }

    func loadSavedSeed() -> WallpaperPreviewSeed? {
        guard let data = try? Data(contentsOf: previewStateURL) else { return nil }
        return try? JSONDecoder().decode(WallpaperPreviewSeed.self, from: data)
    }

    func loadStartupSeed(from appSupportURL: URL) -> WallpaperPreviewSeed? {
        let configURL = appSupportURL.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(ControlConfig.self, from: data),
              !config.video_path.isEmpty
        else {
            return nil
        }
        return WallpaperPreviewSeed(
            video_path: config.video_path,
            playback_speed: config.playback_speed,
            scale_mode: config.scale_mode
        )
    }

    func saveSeed(for videoURL: URL, playbackSpeed: Double, scaleMode: WallpaperScaleMode) {
        let normalizedURL = videoURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else { return }
        let seed = WallpaperPreviewSeed(
            video_path: normalizedURL.path,
            playback_speed: playbackSpeed,
            scale_mode: scaleMode.rawValue
        )
        do {
            try FileManager.default.createDirectory(
                at: previewStateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(seed).write(to: previewStateURL, options: .atomic)
        } catch {
            // Preview persistence is best-effort and must not block playback.
        }
    }

    static func validPreviewURL(for seed: WallpaperPreviewSeed) -> URL? {
        let path = seed.video_path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isReadableKey,
        ]),
        values.isRegularFile == true,
        values.isReadable != false
        else {
            return nil
        }
        return url
    }
}
