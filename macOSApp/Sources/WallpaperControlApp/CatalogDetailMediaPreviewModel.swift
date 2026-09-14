import AVFoundation
import Combine
import Foundation
import SwiftUI

enum CatalogDetailImmediatePreviewSource: Equatable {
    case web(URL)
    case native(URL)
}

@MainActor
final class CatalogDetailMediaPreviewModel: ObservableObject {
    @Published private(set) var imageURL: URL?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var streamingVideoURL: URL?
    @Published private(set) var isVideoVisible = false

    private enum Winner { case native, web }

    private let pipeline: CatalogPreviewPipeline?
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var eventTask: Task<Void, Never>?
    private var nativeAttemptTask: Task<Void, Never>?
    private var generation = 0
    private var nativeAttemptGeneration = 0
    private var winner: Winner?
    private var attemptedURLs = Set<URL>()
    private var isNetworkSuspended = false
    private var activeWallpaperID: String?

    init(pipeline: CatalogPreviewPipeline? = nil) {
        self.pipeline = pipeline
    }

    func load(_ wallpaper: CatalogWallpaper) async {
        guard !isNetworkSuspended else { return }
        generation &+= 1
        let requestedGeneration = generation
        stopPlayback()
        activeWallpaperID = wallpaper.id
        imageURL = Self.preferredImageURL(for: wallpaper)

        if let immediate = Self.immediatePreviewSource(for: wallpaper) {
            start(immediate, requestedGeneration: requestedGeneration)
        }

        guard let pipeline else { return }
        eventTask = Task { [weak self] in
            let events = await pipeline.events(for: wallpaper, priority: .selected)
            for await event in events {
                guard !Task.isCancelled,
                      let self,
                      self.generation == requestedGeneration else { return }
                self.handle(event, requestedGeneration: requestedGeneration)
            }
        }
    }

    func streamingPreviewDidStart(url: URL) {
        guard winner == nil, streamingVideoURL == url else { return }
        winner = .web
        nativeAttemptTask?.cancel()
        nativeAttemptTask = nil
        clearAVPlayback()
        withAnimation(.easeInOut(duration: 0.16)) { isVideoVisible = true }
        confirmDirectPlayback(url: url)
    }

    func streamingPreviewDidFail(url: URL, wallpaper: CatalogWallpaper) {
        guard winner == nil, streamingVideoURL == url else { return }
        streamingVideoURL = nil
    }

    func stop() {
        generation &+= 1
        stopPlayback()
    }

    func setNetworkSuspended(_ suspended: Bool, wallpaper: CatalogWallpaper) {
        guard isNetworkSuspended != suspended else { return }
        isNetworkSuspended = suspended
        if suspended {
            generation &+= 1
            stopPlayback()
        } else {
            Task { [weak self] in
                await self?.load(wallpaper)
            }
        }
    }

    static func immediatePreviewSource(for wallpaper: CatalogWallpaper) -> CatalogDetailImmediatePreviewSource? {
        if let streamingURL = wallpaper.sources.map(\.url).first(where: {
            $0.isFileURL && streamingVideoExtensions.contains($0.pathExtension.lowercased())
        }) {
            return .web(streamingURL)
        }
        if let nativeURL = wallpaper.sources.map(\.url).first(where: {
            $0.isFileURL && nativeVideoExtensions.contains($0.pathExtension.lowercased())
        }) {
            return .native(nativeURL)
        }
        return nil
    }

    private func handle(_ event: CatalogPreviewEvent, requestedGeneration: Int) {
        guard winner == nil else { return }
        switch event {
        case let .direct(url):
            let pathExtension = url.pathExtension.lowercased()
            if Self.streamingVideoExtensions.contains(pathExtension) {
                start(.web(url), requestedGeneration: requestedGeneration)
            } else if Self.nativeVideoExtensions.contains(pathExtension) {
                start(.native(url), requestedGeneration: requestedGeneration)
            }
        case let .ready(url):
            start(.native(url), requestedGeneration: requestedGeneration, supersedePendingNative: true)
        case .state, .failed:
            break
        }
    }

    private func start(
        _ source: CatalogDetailImmediatePreviewSource,
        requestedGeneration: Int,
        supersedePendingNative: Bool = false
    ) {
        guard winner == nil, requestedGeneration == generation else { return }
        switch source {
        case let .web(url):
            guard streamingVideoURL != url else { return }
            streamingVideoURL = url
        case let .native(url):
            guard supersedePendingNative || !attemptedURLs.contains(url) else { return }
            attemptedURLs.insert(url)
            nativeAttemptTask?.cancel()
            nativeAttemptTask = Task { [weak self] in
                guard let self else { return }
                _ = await self.startAVPlayback(url, requestedGeneration: requestedGeneration)
            }
        }
    }

    private func startAVPlayback(_ videoURL: URL, requestedGeneration: Int) async -> Bool {
        guard !Task.isCancelled, winner == nil, requestedGeneration == generation else { return false }
        nativeAttemptGeneration &+= 1
        let attempt = nativeAttemptGeneration
        clearAVPlayback()

        let item = AVPlayerItem(url: videoURL)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        queuePlayer.actionAtItemEnd = .none
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        let playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        self.queuePlayer = queuePlayer
        self.playerLooper = playerLooper
        player = queuePlayer
        queuePlayer.play()

        for _ in 0..<240 {
            guard !Task.isCancelled,
                  winner == nil,
                  requestedGeneration == generation,
                  attempt == nativeAttemptGeneration else { return false }
            switch queuePlayer.currentItem?.status {
            case .readyToPlay:
                let seconds = queuePlayer.currentTime().seconds
                if seconds.isFinite, seconds > 0.03 {
                    winner = .native
                    streamingVideoURL = nil
                    withAnimation(.easeInOut(duration: 0.16)) { isVideoVisible = true }
                    confirmDirectPlayback(url: videoURL)
                    return true
                }
            case .failed:
                if attempt == nativeAttemptGeneration { clearAVPlayback() }
                return false
            default:
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        if attempt == nativeAttemptGeneration { clearAVPlayback() }
        return false
    }

    private func stopPlayback() {
        winner = nil
        attemptedURLs.removeAll()
        isVideoVisible = false
        streamingVideoURL = nil
        eventTask?.cancel()
        eventTask = nil
        nativeAttemptTask?.cancel()
        nativeAttemptTask = nil
        nativeAttemptGeneration &+= 1
        clearAVPlayback()
    }

    private func confirmDirectPlayback(url: URL) {
        guard let pipeline, let activeWallpaperID else { return }
        Task {
            await pipeline.confirmDirectPlayback(wallpaperID: activeWallpaperID, url: url)
        }
    }

    private func clearAVPlayback() {
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
        return wallpaper.sources.map(\.url).first(where: {
            imageExtensions.contains($0.pathExtension.lowercased())
        })
    }

    private static let streamingVideoExtensions: Set<String> = ["webm", "mkv"]
    private static let nativeVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp"]
}
