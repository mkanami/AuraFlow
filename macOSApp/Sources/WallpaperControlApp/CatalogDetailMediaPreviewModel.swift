import AVFoundation
import Combine
import Foundation
import SwiftUI

@MainActor
final class CatalogDetailMediaPreviewModel: ObservableObject {
    @Published private(set) var imageURL: URL?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isVideoVisible = false

    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var generation = 0

    func load(_ wallpaper: CatalogWallpaper) async {
        generation &+= 1
        let requestedGeneration = generation
        stopPlayback()
        imageURL = Self.preferredImageURL(for: wallpaper)

        guard let videoURL = await Self.previewVideoURL(for: wallpaper),
              !Task.isCancelled,
              requestedGeneration == generation else {
            return
        }

        let item = AVPlayerItem(url: videoURL)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        queuePlayer.actionAtItemEnd = .none
        queuePlayer.automaticallyWaitsToMinimizeStalling = true
        let playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)

        self.queuePlayer = queuePlayer
        self.playerLooper = playerLooper
        player = queuePlayer
        queuePlayer.play()

        for _ in 0..<100 {
            guard !Task.isCancelled, requestedGeneration == generation else {
                return
            }
            switch queuePlayer.currentItem?.status {
            case .readyToPlay:
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, requestedGeneration == generation else {
                    return
                }
                withAnimation(.easeInOut(duration: 0.22)) {
                    isVideoVisible = true
                }
                return
            case .failed:
                stopPlayback()
                return
            default:
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        stopPlayback()
    }

    func stop() {
        generation &+= 1
        stopPlayback()
    }

    private func stopPlayback() {
        isVideoVisible = false
        queuePlayer?.pause()
        playerLooper?.disableLooping()
        queuePlayer?.removeAllItems()
        player = nil
        playerLooper = nil
        queuePlayer = nil
    }

    private static func preferredImageURL(for wallpaper: CatalogWallpaper) -> URL? {
        if let previewURL = wallpaper.previewImageURL {
            return MotionBGSParser.fullResolutionPreviewURL(from: previewURL)
        }
        return wallpaper.sources
            .map(\.url)
            .first(where: { imageExtensions.contains($0.pathExtension.lowercased()) })
    }

    private static func previewVideoURL(for wallpaper: CatalogWallpaper) async -> URL? {
        if wallpaper.sourcePageURL?.host?.localizedCaseInsensitiveContains("motionbgs.com") == true,
           let sourcePageURL = wallpaper.sourcePageURL,
           let motionBGSURL = await motionBGSPreviewVideoURL(from: sourcePageURL) {
            return motionBGSURL
        }

        return wallpaper.sources
            .map(\.url)
            .first(where: { videoExtensions.contains($0.pathExtension.lowercased()) })
    }

    private static func motionBGSPreviewVideoURL(from pageURL: URL) async -> URL? {
        var request = URLRequest(url: pageURL)
        request.timeoutInterval = 15
        request.setValue("AuraFlow/1.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }
            return MotionBGSParser.previewVideoURL(
                html: html,
                baseURL: URL(string: "https://motionbgs.com/")!
            )
        } catch {
            return nil
        }
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp"]
}
