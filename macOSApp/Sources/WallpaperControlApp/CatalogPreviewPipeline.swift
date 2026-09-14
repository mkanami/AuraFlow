import AVFoundation
import CryptoKit
import Foundation
import OSLog

enum CatalogPreviewState: String, Sendable {
    case resolving
    case downloading
    case preparing
    case ready
    case failed
}

enum CatalogPreviewPriority: Int, Sendable, Comparable {
    case lookahead = 0
    case visible = 1
    case hovered = 2
    case selected = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum CatalogPreviewEvent: Sendable, Equatable {
    case state(CatalogPreviewState)
    case direct(URL)
    case ready(URL)
    case failed
}

actor CatalogPreviewPermitPool {
    private struct Waiter {
        let id: UUID
        let key: String?
        let priority: CatalogPreviewPriority
        let order: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var available: Int
    private var order: UInt64 = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        available = max(1, limit)
    }

    func acquire(priority: CatalogPreviewPriority, key: String? = nil) async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                order &+= 1
                waiters.append(Waiter(
                    id: id,
                    key: key,
                    priority: priority,
                    order: order,
                    continuation: continuation
                ))
                sortWaiters()
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func promote(key: String, to priority: CatalogPreviewPriority) {
        guard waiters.contains(where: { $0.key == key && $0.priority < priority }) else { return }
        waiters = waiters.map { waiter in
            guard waiter.key == key, waiter.priority < priority else { return waiter }
            return Waiter(
                id: waiter.id,
                key: waiter.key,
                priority: priority,
                order: waiter.order,
                continuation: waiter.continuation
            )
        }
        sortWaiters()
    }

    func release() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
            return
        }
        available += 1
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func sortWaiters() {
        waiters.sort {
            $0.priority == $1.priority ? $0.order < $1.order : $0.priority > $1.priority
        }
    }
}

actor CatalogPreviewPipeline {
    struct Configuration: Sendable {
        var maximumCacheBytes: Int64 = 300 * 1_024 * 1_024
        var successfulResolutionLifetime: TimeInterval = 24 * 60 * 60
        var failureRetryInterval: TimeInterval = 15 * 60
    }

    private struct Manifest: Codable {
        var version = 1
        var entries: [String: Entry] = [:]
    }

    private struct Entry: Codable {
        let fileName: String
        let sourceFingerprint: String
        let byteCount: Int64
        var lastAccessedAt: Date
        let validatedAt: Date
    }

    private struct MetadataManifest: Codable {
        var version = 2
        var entries: [String: CatalogResolvedMedia] = [:]
    }

    private struct Job {
        let token: UUID
        var priority: CatalogPreviewPriority
        var state: CatalogPreviewState
        var directURL: URL?
        var task: Task<Void, Never>?
    }

    private let resolver: (any WallpaperCatalogPreviewResolving)?
    private let mediaResolver: (any WallpaperCatalogMediaResolving)?
    private let transferCoordinator: CatalogTransferCoordinator
    private let mediaPreparer: any CatalogPreviewMediaPreparing
    private let session: URLSession
    private let configuration: Configuration
    private let cacheDirectory: URL
    private let manifestURL: URL
    private let metadataManifestURL: URL
    private let metadataPermits = CatalogPreviewPermitPool(limit: 4)
    private let downloadPermits = CatalogPreviewPermitPool(limit: 2)
    private let conversionPermits = CatalogPreviewPermitPool(limit: 1)
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "AuraFlow",
        category: "CatalogPreview"
    )
    private let transferLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "AuraFlow",
        category: "CatalogTransfer"
    )

    private var manifest: Manifest
    private var metadataManifest: MetadataManifest
    private var jobs: [String: Job] = [:]
    private var failures: [String: Date] = [:]
    private var metadataResolutionTasks: [String: Task<CatalogResolvedMedia, Error>] = [:]
    private var subscribers: [String: [UUID: AsyncStream<CatalogPreviewEvent>.Continuation]] = [:]
    private var manifestSaveTask: Task<Void, Never>?
    private var metadataManifestSaveTask: Task<Void, Never>?

    init(
        resolver: (any WallpaperCatalogPreviewResolving)?,
        mediaResolver: (any WallpaperCatalogMediaResolving)? = nil,
        catalogDirectoryURL: URL,
        session: URLSession = .shared,
        configuration: Configuration = Configuration(),
        mediaPreparer: any CatalogPreviewMediaPreparing = DefaultCatalogPreviewMediaPreparer(),
        transferCoordinator: CatalogTransferCoordinator = CatalogTransferCoordinator()
    ) {
        self.resolver = resolver
        self.mediaResolver = mediaResolver
        self.transferCoordinator = transferCoordinator
        self.mediaPreparer = mediaPreparer
        self.session = session
        self.configuration = configuration
        cacheDirectory = catalogDirectoryURL.appendingPathComponent("PreparedPreviews", isDirectory: true)
        manifestURL = cacheDirectory.appendingPathComponent("manifest.json")
        metadataManifestURL = cacheDirectory.appendingPathComponent("media-routes.json")
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode(Manifest.self, from: data) {
            manifest = decoded
        } else {
            manifest = Manifest()
        }
        if let data = try? Data(contentsOf: metadataManifestURL),
           let decoded = try? JSONDecoder().decode(MetadataManifest.self, from: data),
           decoded.version == MetadataManifest().version {
            metadataManifest = decoded
        } else {
            metadataManifest = MetadataManifest()
        }
    }

    func prefetch(_ wallpaper: CatalogWallpaper, priority: CatalogPreviewPriority) {
        startIfNeeded(wallpaper, priority: priority)
    }

    func prefetchMetadata(_ wallpaper: CatalogWallpaper, priority: CatalogPreviewPriority) {
        startIfNeeded(wallpaper, priority: min(priority, .hovered))
    }

    func resolvedMediaForForegroundDownload(
        _ wallpaper: CatalogWallpaper
    ) async throws -> CatalogResolvedMedia {
        try await resolvedMedia(for: wallpaper, priority: .selected)
    }

    func invalidateResolvedMedia(for wallpaper: CatalogWallpaper) async {
        metadataResolutionTasks[wallpaper.id]?.cancel()
        metadataResolutionTasks[wallpaper.id] = nil
        metadataManifest.entries[wallpaper.id] = nil
        failures[wallpaper.id] = nil
        try? persistMetadataManifest()
        await mediaResolver?.invalidateResolvedMedia(for: wallpaper)
    }

    func beginForegroundDownload() async -> CatalogForegroundDownloadLease {
        let lease = await transferCoordinator.beginForegroundDownload()
        let cancelledCount = jobs.count
        cancelAll()
        transferLogger.info("stage=foreground-priority cancelled_background_tasks=\(cancelledCount)")
        return lease
    }

    func endForegroundDownload(_ lease: CatalogForegroundDownloadLease) async {
        await transferCoordinator.endForegroundDownload(lease)
    }

    func events(
        for wallpaper: CatalogWallpaper,
        priority: CatalogPreviewPriority = .selected
    ) -> AsyncStream<CatalogPreviewEvent> {
        let subscriberID = UUID()
        return AsyncStream { continuation in
            subscribers[wallpaper.id, default: [:]][subscriberID] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeSubscriber(subscriberID, wallpaperID: wallpaper.id) }
            }

            if let entry = reusableEntry(for: wallpaper.id) {
                continuation.yield(.state(.ready))
                continuation.yield(.ready(cacheDirectory.appendingPathComponent(entry.fileName)))
            } else if let job = jobs[wallpaper.id] {
                continuation.yield(.state(job.state))
                if let directURL = job.directURL {
                    continuation.yield(.direct(directURL))
                }
            }
            startIfNeeded(wallpaper, priority: priority)
        }
    }

    func cancelPending(except protectedIDs: Set<String> = []) {
        for (id, job) in jobs where !protectedIDs.contains(id) && job.priority < .selected {
            job.task?.cancel()
            jobs[id] = nil
            metadataResolutionTasks[id]?.cancel()
            metadataResolutionTasks[id] = nil
        }
    }

    func cancelAll() {
        for job in jobs.values { job.task?.cancel() }
        jobs.removeAll()
        metadataResolutionTasks.values.forEach { $0.cancel() }
        metadataResolutionTasks.removeAll()
    }

    func clear() throws {
        cancelAll()
        manifestSaveTask?.cancel()
        manifestSaveTask = nil
        metadataManifestSaveTask?.cancel()
        metadataManifestSaveTask = nil
        failures.removeAll()
        metadataResolutionTasks.values.forEach { $0.cancel() }
        metadataResolutionTasks.removeAll()
        manifest = Manifest()
        metadataManifest = MetadataManifest()
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    func cachedURL(for wallpaperID: String) -> URL? {
        guard let entry = reusableEntry(for: wallpaperID) else { return nil }
        return cacheDirectory.appendingPathComponent(entry.fileName)
    }

    private func startIfNeeded(_ wallpaper: CatalogWallpaper, priority: CatalogPreviewPriority) {
        if reusableEntry(for: wallpaper.id) != nil { return }
        if let failedAt = failures[wallpaper.id],
           Date().timeIntervalSince(failedAt) < configuration.failureRetryInterval {
            emit(.failed, for: wallpaper.id)
            return
        }
        if var existing = jobs[wallpaper.id] {
            let previousPriority = existing.priority
            let promotedPriority = max(existing.priority, priority)
            existing.priority = promotedPriority
            jobs[wallpaper.id] = existing
            if promotedPriority > previousPriority {
                promoteQueuedWork(for: wallpaper.id, to: promotedPriority)
            }
            return
        }

        let token = UUID()
        jobs[wallpaper.id] = Job(
            token: token,
            priority: priority,
            state: .resolving,
            directURL: nil,
            task: nil
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(wallpaper, priority: priority, token: token)
        }
        jobs[wallpaper.id]?.task = task
    }

    private func run(
        _ wallpaper: CatalogWallpaper,
        priority: CatalogPreviewPriority,
        token: UUID
    ) async {
        let startedAt = Date()
        do {
            if currentPriority(for: wallpaper.id, fallback: priority) == .selected,
               let localCandidate = existingLocalCandidate(for: wallpaper) {
                try ensureCurrentJob(wallpaper.id, token: token)
                jobs[wallpaper.id]?.directURL = localCandidate.url
                emit(.direct(localCandidate.url), for: wallpaper.id)
                let cachedURL = try await prepare(
                    localCandidate,
                    wallpaperID: wallpaper.id,
                    referer: wallpaper.sourcePageURL,
                    priority: .selected,
                    token: token
                )
                try finishReady(cachedURL, wallpaperID: wallpaper.id, token: token)
                return
            }

            setState(.resolving, wallpaperID: wallpaper.id, token: token)
            let media = try await resolvedMedia(
                for: wallpaper,
                priority: currentPriority(for: wallpaper.id, fallback: priority)
            )
            try ensureCurrentJob(wallpaper.id, token: token)

            // Visible, lookahead, and hovered cards stop here. Scrolling now
            // warms only provider metadata and never consumes a media body.
            guard currentPriority(for: wallpaper.id, fallback: priority) == .selected else {
                jobs[wallpaper.id] = nil
                failures[wallpaper.id] = nil
                return
            }

            guard await transferCoordinator.permitsBackgroundMedia() else {
                jobs[wallpaper.id] = nil
                return
            }

            var seen = Set<String>()
            var cachedURL: URL?
            var lastCandidateError: Error?
            for candidate in media.previewSources where seen.insert(candidate.url.absoluteString).inserted {
                try ensureCurrentJob(wallpaper.id, token: token)
                guard await transferCoordinator.permitsBackgroundMedia() else {
                    throw CancellationError()
                }
                if !candidate.url.isFileURL {
                    jobs[wallpaper.id]?.directURL = candidate.url
                    emit(.direct(candidate.url), for: wallpaper.id)
                    // Give the direct stream a brief head start. If the user
                    // presses Download or leaves, this task is cancelled before
                    // it consumes the entire preview file.
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                do {
                    cachedURL = try await prepare(
                        candidate,
                        wallpaperID: wallpaper.id,
                        referer: wallpaper.sourcePageURL,
                        priority: .selected,
                        token: token
                    )
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastCandidateError = error
                    logger.debug("provider=\(wallpaper.attribution, privacy: .public) stage=retry reason=\(Self.errorCategory(error), privacy: .public)")
                }
            }
            guard let cachedURL else {
                throw lastCandidateError ?? URLError(.resourceUnavailable)
            }
            try finishReady(cachedURL, wallpaperID: wallpaper.id, token: token)
            let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            logger.info("provider=\(wallpaper.attribution, privacy: .public) stage=ready elapsed_ms=\(milliseconds)")
        } catch is CancellationError {
            if jobs[wallpaper.id]?.token == token {
                jobs[wallpaper.id] = nil
            }
        } catch {
            guard jobs[wallpaper.id]?.token == token else { return }
            jobs[wallpaper.id] = nil
            failures[wallpaper.id] = Date()
            emit(.state(.failed), for: wallpaper.id)
            emit(.failed, for: wallpaper.id)
            logger.notice("provider=\(wallpaper.attribution, privacy: .public) stage=fallback reason=\(Self.errorCategory(error), privacy: .public)")
        }
    }

    private func finishReady(_ url: URL, wallpaperID: String, token: UUID) throws {
        try ensureCurrentJob(wallpaperID, token: token)
        jobs[wallpaperID] = nil
        failures[wallpaperID] = nil
        emit(.state(.ready), for: wallpaperID)
        emit(.ready(url), for: wallpaperID)
    }

    private func resolvedMedia(
        for wallpaper: CatalogWallpaper,
        priority: CatalogPreviewPriority
    ) async throws -> CatalogResolvedMedia {
        if let cached = metadataManifest.entries[wallpaper.id], cached.validUntil > Date() {
            return cached
        }
        if let task = metadataResolutionTasks[wallpaper.id] {
            return try await task.value
        }

        let mediaResolver = mediaResolver
        let resolver = resolver
        let metadataPermits = metadataPermits
        let task = Task<CatalogResolvedMedia, Error> {
            try await metadataPermits.acquire(priority: priority, key: wallpaper.id)
            do {
                let resolved: CatalogResolvedMedia
                if let mediaResolver {
                    resolved = try await mediaResolver.resolveMedia(for: wallpaper)
                } else {
                    let previewSources: [CatalogVideoSource]
                    if let resolver {
                        previewSources = try await resolver.resolvePreviewSources(for: wallpaper)
                    } else {
                        previewSources = wallpaper.sources
                    }
                    resolved = CatalogResolvedMedia(
                        previewSources: previewSources,
                        originalSources: wallpaper.sources,
                        provider: wallpaper.attribution,
                        validUntil: Date().addingTimeInterval(24 * 60 * 60)
                    )
                }
                await metadataPermits.release()
                return resolved
            } catch {
                await metadataPermits.release()
                throw error
            }
        }
        metadataResolutionTasks[wallpaper.id] = task

        do {
            let resolved = try await task.value
            metadataResolutionTasks[wallpaper.id] = nil
            let maximumValidUntil = Date().addingTimeInterval(configuration.successfulResolutionLifetime)
            let cached = CatalogResolvedMedia(
                previewSources: resolved.previewSources,
                originalSources: resolved.originalSources,
                provider: resolved.provider,
                validUntil: min(resolved.validUntil, maximumValidUntil),
                fileSizeMB: resolved.fileSizeMB,
                framesPerSecond: resolved.framesPerSecond
            )
            metadataManifest.entries[wallpaper.id] = cached
            scheduleMetadataManifestPersistence()
            return cached
        } catch {
            task.cancel()
            metadataResolutionTasks[wallpaper.id] = nil
            throw error
        }
    }

    private func prepare(
        _ candidate: CatalogVideoSource,
        wallpaperID: String,
        referer: URL?,
        priority: CatalogPreviewPriority,
        token: UUID
    ) async throws -> URL {
        try ensureCurrentJob(wallpaperID, token: token)
        guard await transferCoordinator.permitsBackgroundMedia() else {
            throw CancellationError()
        }
        setState(.downloading, wallpaperID: wallpaperID, token: token)
        try await downloadPermits.acquire(priority: priority, key: wallpaperID)
        let downloadedURL: URL
        do {
            downloadedURL = try await download(candidate.url, referer: referer)
            await downloadPermits.release()
        } catch {
            await downloadPermits.release()
            throw error
        }
        defer {
            if !candidate.url.isFileURL {
                try? FileManager.default.removeItem(at: downloadedURL)
            }
        }
        try ensureCurrentJob(wallpaperID, token: token)

        var preparedURL = downloadedURL
        let sourceExtension = candidate.url.pathExtension.lowercased()
        if sourceExtension == "webm" || sourceExtension == "mkv" {
            guard await transferCoordinator.permitsBackgroundMedia() else {
                throw CancellationError()
            }
            setState(.preparing, wallpaperID: wallpaperID, token: token)
            try await conversionPermits.acquire(
                priority: currentPriority(for: wallpaperID, fallback: priority),
                key: wallpaperID
            )
            do {
                preparedURL = try await convertToMP4(downloadedURL)
                await conversionPermits.release()
            } catch {
                await conversionPermits.release()
                throw error
            }
        }

        try ensureCurrentJob(wallpaperID, token: token)
        guard await mediaPreparer.containsPlayableVideo(preparedURL) else {
            throw URLError(.cannotDecodeContentData)
        }
        return try storePreparedFile(
            preparedURL,
            wallpaperID: wallpaperID,
            sourceURL: candidate.url
        )
    }

    private func existingLocalCandidate(for wallpaper: CatalogWallpaper) -> CatalogVideoSource? {
        let catalogDirectory = cacheDirectory.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: catalogDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let prefix = wallpaper.id + "-"
        guard let url = files.first(where: {
            $0.lastPathComponent.hasPrefix(prefix) &&
                Self.videoExtensions.contains($0.pathExtension.lowercased())
        }) else { return nil }
        return CatalogVideoSource(url: url, width: 0, height: 0)
    }

    private func download(_ url: URL, referer: URL?) async throws -> URL {
        if url.isFileURL { return url }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let rawExtension = url.pathExtension.isEmpty ? "media" : url.pathExtension
        let destination = cacheDirectory.appendingPathComponent("raw-\(UUID().uuidString).\(rawExtension)")
        let (temporaryURL, response) = try await session.download(for: Self.request(url: url, referer: referer))
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              response.mimeType?.lowercased().hasPrefix("video/") == true else {
            throw URLError(.cannotDecodeContentData)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func convertToMP4(_ inputURL: URL) async throws -> URL {
        try await mediaPreparer.convertToMP4(inputURL)
    }

    private func storePreparedFile(_ source: URL, wallpaperID: String, sourceURL: URL) throws -> URL {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let fingerprint = Self.digest(sourceURL.absoluteString)
        let fileName = "\(Self.digest(wallpaperID))-\(fingerprint.prefix(12)).mp4"
        let destination = cacheDirectory.appendingPathComponent(fileName)
        let temporary = cacheDirectory.appendingPathComponent(".\(UUID().uuidString).tmp")
        try? FileManager.default.removeItem(at: temporary)
        try FileManager.default.copyItem(at: source, to: temporary)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        manifest.entries[wallpaperID] = Entry(
            fileName: fileName,
            sourceFingerprint: fingerprint,
            byteCount: byteCount,
            lastAccessedAt: Date(),
            validatedAt: Date()
        )
        var protectedFileNames = Set(
            subscribers.keys.compactMap { manifest.entries[$0]?.fileName }
        )
        protectedFileNames.insert(fileName)
        try enforceCacheLimit(protecting: protectedFileNames)
        try persistManifest()
        return destination
    }

    private func reusableEntry(for wallpaperID: String) -> Entry? {
        guard var entry = manifest.entries[wallpaperID],
              Date().timeIntervalSince(entry.validatedAt) <= configuration.successfulResolutionLifetime else {
            return nil
        }
        let url = cacheDirectory.appendingPathComponent(entry.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            manifest.entries[wallpaperID] = nil
            return nil
        }
        entry.lastAccessedAt = Date()
        manifest.entries[wallpaperID] = entry
        scheduleManifestPersistence()
        return entry
    }

    private func currentPriority(
        for wallpaperID: String,
        fallback: CatalogPreviewPriority
    ) -> CatalogPreviewPriority {
        jobs[wallpaperID]?.priority ?? fallback
    }

    private func promoteQueuedWork(for wallpaperID: String, to priority: CatalogPreviewPriority) {
        Task {
            await metadataPermits.promote(key: wallpaperID, to: priority)
            await downloadPermits.promote(key: wallpaperID, to: priority)
            await conversionPermits.promote(key: wallpaperID, to: priority)
        }
    }

    private func scheduleManifestPersistence() {
        guard manifestSaveTask == nil else { return }
        manifestSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.persistScheduledManifest()
        }
    }

    private func persistScheduledManifest() {
        manifestSaveTask = nil
        try? persistManifest()
    }

    private func scheduleMetadataManifestPersistence() {
        guard metadataManifestSaveTask == nil else { return }
        metadataManifestSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.persistScheduledMetadataManifest()
        }
    }

    private func persistScheduledMetadataManifest() {
        metadataManifestSaveTask = nil
        try? persistMetadataManifest()
    }

    private func enforceCacheLimit(protecting protectedFileNames: Set<String>) throws {
        var total = manifest.entries.values.reduce(Int64(0)) { $0 + $1.byteCount }
        let candidates = manifest.entries.sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
        for (id, entry) in candidates where total > configuration.maximumCacheBytes {
            guard !protectedFileNames.contains(entry.fileName) else { continue }
            try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(entry.fileName))
            manifest.entries[id] = nil
            total -= entry.byteCount
        }
    }

    private func persistManifest() throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func persistMetadataManifest() throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(metadataManifest)
        try data.write(to: metadataManifestURL, options: .atomic)
    }

    private func setState(_ state: CatalogPreviewState, wallpaperID: String, token: UUID) {
        guard jobs[wallpaperID]?.token == token else { return }
        jobs[wallpaperID]?.state = state
        emit(.state(state), for: wallpaperID)
    }

    private func ensureCurrentJob(_ wallpaperID: String, token: UUID) throws {
        try Task.checkCancellation()
        guard jobs[wallpaperID]?.token == token else { throw CancellationError() }
    }

    private func emit(_ event: CatalogPreviewEvent, for wallpaperID: String) {
        for continuation in subscribers[wallpaperID]?.values ?? [:].values {
            continuation.yield(event)
        }
    }

    private func removeSubscriber(_ id: UUID, wallpaperID: String) {
        subscribers[wallpaperID]?[id] = nil
        if subscribers[wallpaperID]?.isEmpty == true { subscribers[wallpaperID] = nil }
    }

    private static func request(url: URL, referer: URL?) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("video/webm,video/mp4,video/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            if let components = URLComponents(url: referer, resolvingAgainstBaseURL: false),
               let scheme = components.scheme, let host = components.host {
                request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
        }
        return request
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func errorCategory(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError { return "url_\(urlError.code.rawValue)" }
        return String(describing: type(of: error))
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv"]
}

protocol CatalogPreviewMediaPreparing: Sendable {
    func convertToMP4(_ inputURL: URL) async throws -> URL
    func containsPlayableVideo(_ url: URL) async -> Bool
}

struct DefaultCatalogPreviewMediaPreparer: CatalogPreviewMediaPreparing {
    func convertToMP4(_ inputURL: URL) async throws -> URL {
        let settings = VideoOptimizationSettings(
            enabled: true,
            allowAV1PassthroughOnHardwareDecode: true,
            transcodeH264ToHEVC: false,
            forceSoftwareAV1Encode: false,
            profile: .balanced
        )
        return try await Task { @MainActor in
            let result = try await VideoOptimizer().optimizeIfNeeded(
                inputURL: inputURL,
                settings: settings,
                progress: { _ in }
            )
            return result.outputURL
        }.value
    }

    func containsPlayableVideo(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let isPlayable = try await asset.load(.isPlayable)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            return isPlayable && !tracks.isEmpty
        } catch {
            return false
        }
    }
}
