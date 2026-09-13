import AVFoundation
import Combine
import CryptoKit
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

    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var fallbackTask: Task<Void, Never>?
    private var streamingStartupTask: Task<Void, Never>?
    private var generation = 0

    func load(_ wallpaper: CatalogWallpaper) async {
        generation &+= 1
        let requestedGeneration = generation
        stopPlayback()
        imageURL = Self.preferredImageURL(for: wallpaper)

        switch Self.immediatePreviewSource(for: wallpaper) {
        case let .web(streamingURL):
            streamingVideoURL = streamingURL
            scheduleStreamingFallback(
                url: streamingURL,
                wallpaper: wallpaper,
                requestedGeneration: requestedGeneration
            )
            return
        case let .native(directVideoURL):
            if await startAVPlayback(directVideoURL, requestedGeneration: requestedGeneration) {
                return
            }
        case nil:
            break
        }

        guard let preparedURL = await CatalogDetailPreviewPreparationCache.shared.playableURL(for: wallpaper),
              !Task.isCancelled,
              requestedGeneration == generation else {
            return
        }
        _ = await startAVPlayback(preparedURL, requestedGeneration: requestedGeneration)
    }

    func streamingPreviewDidStart(url: URL) {
        guard streamingVideoURL == url else { return }
        streamingStartupTask?.cancel()
        streamingStartupTask = nil
        withAnimation(.easeInOut(duration: 0.18)) {
            isVideoVisible = true
        }
    }

    func streamingPreviewDidFail(url: URL, wallpaper: CatalogWallpaper) {
        guard streamingVideoURL == url else { return }
        streamingStartupTask?.cancel()
        streamingStartupTask = nil
        streamingVideoURL = nil
        isVideoVisible = false
        let requestedGeneration = generation
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            guard let self,
                  let preparedURL = await CatalogDetailPreviewPreparationCache.shared.playableURL(for: wallpaper),
                  !Task.isCancelled,
                  requestedGeneration == self.generation else {
                return
            }
            _ = await self.startAVPlayback(preparedURL, requestedGeneration: requestedGeneration)
        }
    }

    private func startAVPlayback(_ videoURL: URL, requestedGeneration: Int) async -> Bool {
        guard !Task.isCancelled, requestedGeneration == generation else { return false }
        clearAVPlayback()

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

        // Keep the already-loaded poster over AVPlayer until playback has
        // actually advanced. AVPlayerItem.readyToPlay only means that metadata
        // is available and can still expose a black/empty layer for a frame.
        for _ in 0..<160 {
            guard !Task.isCancelled, requestedGeneration == generation else {
                return false
            }
            switch queuePlayer.currentItem?.status {
            case .readyToPlay:
                let currentSeconds = queuePlayer.currentTime().seconds
                if currentSeconds.isFinite, currentSeconds > 0.03 {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isVideoVisible = true
                    }
                    return true
                }
            case .failed:
                clearAVPlayback()
                return false
            default:
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        clearAVPlayback()
        return false
    }

    func stop() {
        generation &+= 1
        stopPlayback()
    }

    static func preload(_ wallpaper: CatalogWallpaper, prioritize: Bool = false) {
        switch immediatePreviewSource(for: wallpaper) {
        case let .web(url):
            CatalogStreamingVideoSessionStore.shared.prewarm(
                url: url,
                referer: wallpaper.sourcePageURL,
                prioritize: prioritize
            )
        case .native:
            Task(priority: .utility) {
                _ = await CatalogDetailPreviewPreparationCache.shared.playableURL(for: wallpaper)
            }
        case nil:
            break
        }
    }

    private func stopPlayback() {
        isVideoVisible = false
        streamingVideoURL = nil
        streamingStartupTask?.cancel()
        streamingStartupTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        clearAVPlayback()
    }

    private func clearAVPlayback() {
        queuePlayer?.pause()
        playerLooper?.disableLooping()
        queuePlayer?.removeAllItems()
        player = nil
        playerLooper = nil
        queuePlayer = nil
    }

    private func scheduleStreamingFallback(
        url: URL,
        wallpaper: CatalogWallpaper,
        requestedGeneration: Int
    ) {
        streamingStartupTask?.cancel()
        streamingStartupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  requestedGeneration == self.generation,
                  self.streamingVideoURL == url,
                  !self.isVideoVisible else {
                return
            }
            self.streamingPreviewDidFail(url: url, wallpaper: wallpaper)
        }
    }

    private static func preferredImageURL(for wallpaper: CatalogWallpaper) -> URL? {
        if let previewURL = wallpaper.previewImageURL {
            return MotionBGSParser.fullResolutionPreviewURL(from: previewURL)
        }
        return wallpaper.sources
            .map(\.url)
            .first(where: { imageExtensions.contains($0.pathExtension.lowercased()) })
    }

    static func immediatePreviewSource(for wallpaper: CatalogWallpaper) -> CatalogDetailImmediatePreviewSource? {
        if let streamingURL = wallpaper.sources
            .map(\.url)
            .first(where: { streamingVideoExtensions.contains($0.pathExtension.lowercased()) }) {
            return .web(streamingURL)
        }

        if let nativeURL = wallpaper.sources
            .map(\.url)
            .first(where: { nativeVideoExtensions.contains($0.pathExtension.lowercased()) }) {
            return .native(nativeURL)
        }

        return nil
    }

    private static let streamingVideoExtensions: Set<String> = ["webm", "mkv"]
    private static let nativeVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp"]
}

@MainActor
private final class CatalogDetailPreviewPreparationCache {
    static let shared = CatalogDetailPreviewPreparationCache()

    private struct InFlightPreparation {
        let id: UUID
        let task: Task<URL?, Never>
    }

    private var preparedURLs: [String: URL] = [:]
    private var inFlight: [String: InFlightPreparation] = [:]

    func playableURL(for wallpaper: CatalogWallpaper) async -> URL? {
        if let cached = preparedURLs[wallpaper.id], Self.isReusable(cached) {
            return cached
        }
        preparedURLs[wallpaper.id] = nil

        if let existing = inFlight[wallpaper.id] {
            return await existing.task.value
        }

        let preparationID = UUID()
        let task = Task<URL?, Never> {
            await Self.preparePlayableURL(for: wallpaper)
        }
        inFlight[wallpaper.id] = InFlightPreparation(id: preparationID, task: task)

        let result = await task.value
        if inFlight[wallpaper.id]?.id == preparationID {
            inFlight[wallpaper.id] = nil
            if let result {
                preparedURLs[wallpaper.id] = result
            }
        }
        return result
    }

    private static func preparePlayableURL(for wallpaper: CatalogWallpaper) async -> URL? {
        if let direct = await firstPlayableURL(
            in: wallpaper.sources.map(\.url),
            referer: wallpaper.sourcePageURL
        ) {
            return direct
        }

        return await firstPlayableURL(
            in: await providerPreviewCandidates(for: wallpaper),
            referer: wallpaper.sourcePageURL
        )
    }

    private static func firstPlayableURL(in candidates: [URL], referer: URL?) async -> URL? {
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.absoluteString).inserted {
            guard !Task.isCancelled else { return nil }
            do {
                let preparedURL = try await prepare(candidate, referer: referer)
                guard await containsPlayableVideo(preparedURL) else { continue }
                return preparedURL
            } catch is CancellationError {
                return nil
            } catch {
                continue
            }
        }
        return nil
    }

    private static func prepare(_ candidate: URL, referer: URL?) async throws -> URL {
        let pathExtension = candidate.pathExtension.lowercased()
        guard pathExtension == "webm" || pathExtension == "mkv" else {
            return candidate
        }

        let localInput: URL
        if candidate.isFileURL {
            localInput = candidate
        } else {
            localInput = try await CatalogWebPreviewDownloadCache.shared.localURL(
                for: candidate,
                referer: referer
            )
        }

        let settings = VideoOptimizationSettings(
            enabled: true,
            allowAV1PassthroughOnHardwareDecode: true,
            transcodeH264ToHEVC: false,
            forceSoftwareAV1Encode: false,
            profile: .balanced
        )
        let result = try await VideoOptimizer().optimizeIfNeeded(
            inputURL: localInput,
            settings: settings,
            progress: { _ in }
        )
        return result.outputURL
    }

    private static func containsPlayableVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable) else { return false }
            return try await !asset.loadTracks(withMediaType: .video).isEmpty
        } catch {
            return false
        }
    }

    private static func providerPreviewCandidates(for wallpaper: CatalogWallpaper) async -> [URL] {
        guard let pageURL = wallpaper.sourcePageURL,
              let host = pageURL.host?.lowercased() else {
            return []
        }

        if host.contains("motionbgs.com") {
            return await motionBGSPreviewVideoURL(from: pageURL).map { [$0] } ?? []
        }

        if host.contains("moewalls.com") {
            guard let details = try? await MoeWallsSource().fetchDetails(pageURL: pageURL) else {
                return []
            }
            return details.previewCandidateURLs
        }

        if host.contains("dareful.com"),
           let resolved = try? await DarefulSource().resolveDownloadURL(for: wallpaper) {
            return [resolved]
        }

        return []
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

    private static func isReusable(_ url: URL) -> Bool {
        !url.isFileURL || FileManager.default.fileExists(atPath: url.path)
    }
}

private actor CatalogWebPreviewDownloadCache {
    static let shared = CatalogWebPreviewDownloadCache()

    private struct InFlightDownload {
        let id: UUID
        let task: Task<URL, Error>
    }

    private var inFlight: [String: InFlightDownload] = [:]

    func localURL(for remoteURL: URL, referer: URL?) async throws -> URL {
        let destination = try Self.destinationURL(for: remoteURL)
        if Self.isUsableFile(at: destination) {
            return destination
        }

        let key = remoteURL.absoluteString
        if let existing = inFlight[key] {
            return try await existing.task.value
        }

        let downloadID = UUID()
        let task = Task<URL, Error> {
            try await Self.download(remoteURL, referer: referer, to: destination)
        }
        inFlight[key] = InFlightDownload(id: downloadID, task: task)

        do {
            let result = try await task.value
            if inFlight[key]?.id == downloadID {
                inFlight[key] = nil
            }
            return result
        } catch {
            if inFlight[key]?.id == downloadID {
                inFlight[key] = nil
            }
            throw error
        }
    }

    private static func download(_ remoteURL: URL, referer: URL?, to destination: URL) async throws -> URL {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("video/webm,video/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        let (temporaryURL, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Task.checkCancellation()

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw URLError(.badServerResponse)
        }
        if let mimeType = response.mimeType?.lowercased(), !mimeType.hasPrefix("video/") {
            throw URLError(.cannotDecodeContentData)
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        guard isUsableFile(at: destination) else {
            throw URLError(.zeroByteResource)
        }
        return destination
    }

    private static func destinationURL(for remoteURL: URL) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("AuraFlow", isDirectory: true)
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("PreviewMedia", isDirectory: true)
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let pathExtension = remoteURL.pathExtension.isEmpty ? "webm" : remoteURL.pathExtension
        return directory.appendingPathComponent("\(digest).\(pathExtension)")
    }

    private static func isUsableFile(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return false
        }
        return size > 1_024
    }
}
