import AVFoundation
import AppKit
import Foundation
import OSLog

private let catalogPersistenceLogger = Logger(
    subsystem: "com.andrijvergeles.auraflow",
    category: "CatalogPersistence"
)

enum CatalogPersistenceStatus: Equatable, Sendable {
    case notAttempted
    case persisted
    case recoveredAndPersisted
    case failed(operation: String, reason: String)
    case recoveredButNotPersisted(reason: String)

    var warningMessage: String? {
        switch self {
        case .notAttempted, .persisted, .recoveredAndPersisted:
            return nil
        case .failed(let operation, let reason):
            return "Catalog \(operation) failed: \(reason)"
        case .recoveredButNotPersisted(let reason):
            return "Catalog was recovered in memory, but could not be saved: \(reason)"
        }
    }

    var didPersist: Bool {
        switch self {
        case .persisted, .recoveredAndPersisted:
            return true
        case .notAttempted, .failed, .recoveredButNotPersisted:
            return false
        }
    }

    var didRecover: Bool {
        switch self {
        case .recoveredAndPersisted, .recoveredButNotPersisted:
            return true
        case .notAttempted, .persisted, .failed:
            return false
        }
    }
}

/// Owns the catalog's durable data and file-system policy.
///
/// `CatalogViewModel` owns presentation state and operation lifetimes. This
/// repository owns catalog cache access, the downloaded manifest, disk
/// inference/merge rules, preview image files, and importing user-selected
/// wallpapers into the managed catalog directory.
final class CatalogRepository: @unchecked Sendable {
    typealias AtomicDataWriter = @Sendable (Data, URL) throws -> Void

    struct PreviewGenerationRequest: Sendable {
        let videoURL: URL
        let legacyWallpaperID: String?
        let wallpaperID: String
    }

    struct CatalogCacheLoadResult: Sendable {
        let wallpapers: [CatalogWallpaper]?
        let persistenceStatus: CatalogPersistenceStatus
    }

    struct CatalogRefreshResult: Sendable {
        let wallpapers: [CatalogWallpaper]
        let persistenceStatus: CatalogPersistenceStatus
    }

    struct DownloadedWallpapersLoadResult: Sendable {
        let wallpapers: [DownloadedCatalogWallpaper]
        let persistenceStatus: CatalogPersistenceStatus
    }

    struct RegistrationResult: Sendable {
        let wallpapers: [DownloadedCatalogWallpaper]
        let previewRequest: PreviewGenerationRequest?
        let persistenceStatus: CatalogPersistenceStatus
    }

    struct UpdatedWallpapersResult: Sendable {
        let wallpapers: [DownloadedCatalogWallpaper]
        let persistenceStatus: CatalogPersistenceStatus
    }

    struct LocalImportResult: Sendable {
        let url: URL
        let created: Bool
    }

    private let provider: WallpaperCatalogProviding
    private let atomicDataWriter: AtomicDataWriter
    let catalogDirectoryURL: URL

    init(
        provider: WallpaperCatalogProviding,
        catalogDirectoryURL: URL,
        atomicDataWriter: @escaping AtomicDataWriter = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.provider = provider
        self.atomicDataWriter = atomicDataWriter
        self.catalogDirectoryURL = catalogDirectoryURL.standardizedFileURL
    }

    // MARK: Catalog cache

    func loadCatalogCache() async -> CatalogCacheLoadResult {
        var persistenceStatus = CatalogPersistenceStatus.notAttempted
        var cacheReadReason: String?
        if FileManager.default.fileExists(atPath: catalogCacheURL.path) {
            do {
                let cached = try loadUnifiedCatalogCache()
                if !cached.isEmpty {
                    return CatalogCacheLoadResult(
                        wallpapers: cached,
                        persistenceStatus: persistenceStatus
                    )
                }
            } catch {
                catalogPersistenceLogger.error(
                    "Unable to read unified catalog cache: \(error.localizedDescription, privacy: .public)"
                )
                cacheReadReason = error.localizedDescription
                persistenceStatus = .failed(
                    operation: "unified catalog cache read",
                    reason: error.localizedDescription
                )
            }
        }
        let providerCatalog = await provider.loadCachedCatalog()
        if let cacheReadReason, let providerCatalog, !providerCatalog.isEmpty {
            return CatalogCacheLoadResult(
                wallpapers: providerCatalog,
                persistenceStatus: recoveryPersistenceStatus(
                    persistUnifiedCatalogCache(providerCatalog),
                    reason: "The unified catalog cache was unreadable: \(cacheReadReason)"
                )
            )
        }
        return CatalogCacheLoadResult(
            wallpapers: providerCatalog,
            persistenceStatus: persistenceStatus
        )
    }

    func refreshCatalog(
        progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void
    ) async throws -> CatalogRefreshResult {
        let wallpapers = try await provider.fetchCatalog(progress: progress)
        let persistenceStatus = wallpapers.isEmpty
            ? .notAttempted
            : persistUnifiedCatalogCache(wallpapers)
        return CatalogRefreshResult(
            wallpapers: wallpapers,
            persistenceStatus: persistenceStatus
        )
    }

    // MARK: Downloaded manifest

    func loadDownloadedWallpapers(
        preserving inMemory: [DownloadedCatalogWallpaper]
    ) -> DownloadedWallpapersLoadResult {
        let loaded: [DownloadedCatalogWallpaper]
        guard FileManager.default.fileExists(atPath: downloadedManifestURL.path) else {
            let inferred: [DownloadedCatalogWallpaper]
            do {
                inferred = try inferredDownloadedWallpapersFromDisk()
            } catch {
                catalogPersistenceLogger.error(
                    "Unable to inspect catalog directory: \(error.localizedDescription, privacy: .public)"
                )
                return DownloadedWallpapersLoadResult(
                    wallpapers: inMemory,
                    persistenceStatus: .failed(
                        operation: "downloaded catalog directory read",
                        reason: error.localizedDescription
                    )
                )
            }
            let merged = mergeDownloadedWallpapers(inferred, preserving: inMemory)
            let persistenceStatus = merged.isEmpty
                ? .notAttempted
                : persistDownloadedWallpapers(merged)
            return DownloadedWallpapersLoadResult(
                wallpapers: merged,
                persistenceStatus: persistenceStatus
            )
        }

        do {
            let data = try Data(contentsOf: downloadedManifestURL)
            do {
                loaded = try JSONDecoder().decode([DownloadedCatalogWallpaper].self, from: data)
            } catch {
                catalogPersistenceLogger.error(
                    "Downloaded catalog manifest is corrupt; rebuilding it: \(error.localizedDescription, privacy: .public)"
                )
                let recoveryReason = "The downloaded manifest was corrupt: \(error.localizedDescription)"
                let repaired: [DownloadedCatalogWallpaper]
                do {
                    repaired = mergeDownloadedWallpapers(
                        try inferredDownloadedWallpapersFromDisk(),
                        preserving: inMemory
                    )
                } catch {
                    catalogPersistenceLogger.error(
                        "Unable to rebuild downloaded catalog from disk: \(error.localizedDescription, privacy: .public)"
                    )
                    return DownloadedWallpapersLoadResult(
                        wallpapers: inMemory,
                        persistenceStatus: .recoveredButNotPersisted(
                            reason: "\(recoveryReason) Recovery scan failed: \(error.localizedDescription)"
                        )
                    )
                }
                return DownloadedWallpapersLoadResult(
                    wallpapers: repaired,
                    persistenceStatus: recoveryPersistenceStatus(
                        persistDownloadedWallpapers(repaired),
                        reason: recoveryReason
                    )
                )
            }
        } catch {
            catalogPersistenceLogger.error(
                "Unable to read downloaded catalog manifest: \(error.localizedDescription, privacy: .public)"
            )
            let fallback: [DownloadedCatalogWallpaper]
            do {
                fallback = mergeDownloadedWallpapers(
                    try inferredDownloadedWallpapersFromDisk(),
                    preserving: inMemory
                )
            } catch {
                catalogPersistenceLogger.error(
                    "Unable to inspect catalog directory after manifest read failure: \(error.localizedDescription, privacy: .public)"
                )
                return DownloadedWallpapersLoadResult(
                    wallpapers: inMemory,
                    persistenceStatus: .failed(
                        operation: "downloaded catalog recovery",
                        reason: error.localizedDescription
                    )
                )
            }
            return DownloadedWallpapersLoadResult(
                wallpapers: fallback,
                persistenceStatus: .failed(
                    operation: "downloaded wallpaper manifest read",
                    reason: error.localizedDescription
                )
            )
        }

        let existing = loaded.compactMap { item -> DownloadedCatalogWallpaper? in
            guard FileManager.default.fileExists(atPath: item.localURL.path) else {
                return nil
            }

            let repairedPreviewPath = item.localPreviewPath.flatMap { path in
                FileManager.default.fileExists(atPath: path) ? path : nil
            }

            return DownloadedCatalogWallpaper(
                id: item.id,
                wallpaperID: item.wallpaperID,
                title: item.title,
                category: item.category,
                attribution: item.attribution,
                previewImageURL: item.previewImageURL,
                localPreviewPath: repairedPreviewPath,
                sourcePageURL: item.sourcePageURL,
                localPath: item.localPath,
                downloadedAt: item.downloadedAt
            )
        }

        var sorted = existing.sorted(by: newerFirst)
        if sorted.isEmpty {
            do {
                sorted = try inferredDownloadedWallpapersFromDisk()
            } catch {
                catalogPersistenceLogger.error(
                    "Unable to inspect catalog directory while repairing manifest: \(error.localizedDescription, privacy: .public)"
                )
                return DownloadedWallpapersLoadResult(
                    wallpapers: inMemory,
                    persistenceStatus: .failed(
                        operation: "downloaded catalog repair",
                        reason: error.localizedDescription
                    )
                )
            }
        }
        sorted = mergeDownloadedWallpapers(sorted, preserving: inMemory)

        let persistenceStatus: CatalogPersistenceStatus
        if sorted != loaded {
            persistenceStatus = persistDownloadedWallpapers(sorted)
        } else {
            persistenceStatus = .notAttempted
        }
        return DownloadedWallpapersLoadResult(
            wallpapers: sorted,
            persistenceStatus: persistenceStatus
        )
    }

    func persistDownloadedWallpapers(
        _ wallpapers: [DownloadedCatalogWallpaper]
    ) -> CatalogPersistenceStatus {
        do {
            try ensureCatalogDirectory()
            let data = try JSONEncoder().encode(wallpapers)
            try atomicDataWriter(data, downloadedManifestURL)
            return .persisted
        } catch {
            catalogPersistenceLogger.error(
                "Unable to persist downloaded wallpaper manifest: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(
                operation: "downloaded wallpaper manifest",
                reason: error.localizedDescription
            )
        }
    }

    func registerDownloadedWallpaper(
        _ wallpaper: CatalogWallpaper,
        localURL: URL,
        existing: [DownloadedCatalogWallpaper]
    ) -> RegistrationResult {
        let normalizedPath = localURL.standardizedFileURL.path
        let localPreviewPath = existingLocalPreviewImageURL(
            for: previewImageKey(for: localURL)
        )?.path
        let entry = DownloadedCatalogWallpaper(
            id: wallpaper.id,
            wallpaperID: wallpaper.id,
            title: wallpaper.title,
            category: wallpaper.category,
            attribution: wallpaper.attribution,
            previewImageURL: wallpaper.previewImageURL,
            localPreviewPath: localPreviewPath,
            sourcePageURL: wallpaper.sourcePageURL,
            localPath: normalizedPath,
            downloadedAt: Date()
        )

        var updated = existing
        if let index = updated.firstIndex(where: {
            $0.id == entry.id || $0.localPath == entry.localPath
        }) {
            updated[index] = entry
        } else {
            updated.append(entry)
        }
        updated.sort(by: newerFirst)
        let persistenceStatus = persistDownloadedWallpapers(updated)

        let request = localPreviewPath == nil
            ? PreviewGenerationRequest(
                videoURL: localURL,
                legacyWallpaperID: wallpaper.id,
                wallpaperID: wallpaper.id
            )
            : nil
        return RegistrationResult(
            wallpapers: updated,
            previewRequest: request,
            persistenceStatus: persistenceStatus
        )
    }

    func updateGeneratedPreview(
        _ previewURL: URL,
        wallpaperID: String,
        in wallpapers: [DownloadedCatalogWallpaper]
    ) -> UpdatedWallpapersResult {
        guard let index = wallpapers.firstIndex(where: { $0.wallpaperID == wallpaperID }) else {
            return UpdatedWallpapersResult(
                wallpapers: wallpapers,
                persistenceStatus: .notAttempted
            )
        }
        let current = wallpapers[index]
        guard current.localPreviewPath != previewURL.path else {
            return UpdatedWallpapersResult(
                wallpapers: wallpapers,
                persistenceStatus: .notAttempted
            )
        }

        var updated = wallpapers
        updated[index] = DownloadedCatalogWallpaper(
            id: current.id,
            wallpaperID: current.wallpaperID,
            title: current.title,
            category: current.category,
            attribution: current.attribution,
            previewImageURL: current.previewImageURL,
            localPreviewPath: previewURL.path,
            sourcePageURL: current.sourcePageURL,
            localPath: current.localPath,
            downloadedAt: current.downloadedAt
        )
        return UpdatedWallpapersResult(
            wallpapers: updated,
            persistenceStatus: persistDownloadedWallpapers(updated)
        )
    }

    // MARK: Local import

    func copyLocalWallpaper(
        from sourceURL: URL,
        existing: [DownloadedCatalogWallpaper]
    ) async throws -> LocalImportResult {
        let normalizedSourceURL = sourceURL.standardizedFileURL
        guard normalizedSourceURL.isFileURL,
              FileManager.default.fileExists(atPath: normalizedSourceURL.path)
        else {
            throw CatalogRepositoryError.invalidLocalImport
        }

        let resourceValues = try normalizedSourceURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard resourceValues.isDirectory != true,
              resourceValues.isSymbolicLink != true
        else {
            throw CatalogRepositoryError.invalidLocalImport
        }
        guard !isManagedCacheURL(normalizedSourceURL) else {
            return LocalImportResult(url: normalizedSourceURL, created: false)
        }

        if let existingItem = existing.first(where: {
            isImportedLocalWallpaper($0, from: normalizedSourceURL)
                && FileManager.default.fileExists(atPath: $0.localURL.path)
        }) {
            return LocalImportResult(
                url: existingItem.localURL.standardizedFileURL,
                created: false
            )
        }

        try ensureCatalogDirectory()
        let extensionName = normalizedSourceURL.pathExtension.isEmpty
            ? "mp4"
            : normalizedSourceURL.pathExtension.lowercased()
        let destinationURL = catalogDirectoryURL.appendingPathComponent(
            "local-\(UUID().uuidString.lowercased()).\(extensionName)"
        )
        let accessedSecurityScopedResource = normalizedSourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScopedResource {
                normalizedSourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            try Task.checkCancellation()
            try await Task.detached(priority: .utility) {
                try FileManager.default.copyItem(
                    at: normalizedSourceURL,
                    to: destinationURL
                )
            }.value
            try Task.checkCancellation()
            return LocalImportResult(
                url: destinationURL.standardizedFileURL,
                created: true
            )
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    func registerLocalWallpaperCopy(
        originalURL: URL,
        copiedURL: URL,
        existing: [DownloadedCatalogWallpaper]
    ) -> RegistrationResult {
        let normalizedOriginalURL = originalURL.standardizedFileURL
        let normalizedCopiedURL = copiedURL.standardizedFileURL
        let localPreviewPath = existingLocalPreviewImageURL(
            for: previewImageKey(for: normalizedCopiedURL)
        )?.path
        let existingIndex = existing.firstIndex {
            isImportedLocalWallpaper($0, from: normalizedOriginalURL)
        }
        let existingItem = existingIndex.map { existing[$0] }
        let localID = existingItem?.id ?? "local-\(UUID().uuidString.lowercased())"
        let entry = DownloadedCatalogWallpaper(
            id: localID,
            wallpaperID: existingItem?.wallpaperID ?? localID,
            title: inferredTitleFromDownloadedFileName(
                normalizedOriginalURL.deletingPathExtension().lastPathComponent
            ),
            category: "Local",
            attribution: "This Mac",
            previewImageURL: nil,
            localPreviewPath: localPreviewPath,
            sourcePageURL: normalizedOriginalURL,
            localPath: normalizedCopiedURL.path,
            downloadedAt: existingItem?.downloadedAt ?? Date()
        )

        var updated = existing
        if let existingIndex {
            updated[existingIndex] = entry
        } else {
            updated.append(entry)
        }
        updated.sort(by: newerFirst)
        let persistenceStatus = persistDownloadedWallpapers(updated)

        let request = localPreviewPath == nil
            ? PreviewGenerationRequest(
                videoURL: normalizedCopiedURL,
                legacyWallpaperID: nil,
                wallpaperID: entry.wallpaperID
            )
            : nil
        return RegistrationResult(
            wallpapers: updated,
            previewRequest: request,
            persistenceStatus: persistenceStatus
        )
    }

    // MARK: Managed files

    func resolveDownloadedWallpaperURL(
        _ wallpaper: DownloadedCatalogWallpaper
    ) throws -> URL {
        let url = wallpaper.localURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CatalogRepositoryError.downloadedFileMissing
        }
        return url
    }

    func reusableDownloadedWallpaperURL(
        for wallpaperID: String,
        in wallpapers: [DownloadedCatalogWallpaper]
    ) -> URL? {
        guard let existing = wallpapers.first(where: { $0.wallpaperID == wallpaperID }) else {
            return nil
        }
        if hasUsableCatalogFile(at: existing.localURL) {
            return existing.localURL.standardizedFileURL
        }
        try? FileManager.default.removeItem(at: existing.localURL)
        return nil
    }

    func hasUsableCatalogFile(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0 > 0
    }

    func removeFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func isManagedCacheURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let directoryPath = catalogDirectoryURL.path
        return path == directoryPath || path.hasPrefix(directoryPath + "/")
    }

    func clearCache() async throws {
        if let cacheClearingProvider = provider as? CatalogCacheClearing {
            await cacheClearingProvider.clearCache()
        }
        try ensureCatalogDirectory()
        let entries = try FileManager.default.contentsOfDirectory(
            at: catalogDirectoryURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        for entry in entries {
            try FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: Preview images

    func generatePreviewIfNeeded(
        for request: PreviewGenerationRequest
    ) async throws -> URL? {
        try Task.checkCancellation()
        try ensurePreviewDirectory()
        let previewKey = previewImageKey(for: request.videoURL)
        let destinationURL = try previewImageURL(for: previewKey)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }
        let legacyURL = request.legacyWallpaperID.flatMap {
            existingLocalPreviewImageURL(for: $0)
        }
        let generatedURL = await Task.detached(priority: .utility) {
            Self.generatePreviewImage(
                for: request.videoURL,
                destinationURL: destinationURL,
                legacyURL: legacyURL
            )
        }.value
        try Task.checkCancellation()
        return generatedURL
    }

    // MARK: Private persistence/inference helpers

    private var catalogCacheURL: URL {
        catalogDirectoryURL.appendingPathComponent("catalog-cache.json")
    }

    private var downloadedManifestURL: URL {
        catalogDirectoryURL.appendingPathComponent("downloaded-catalog.json")
    }

    private func ensureCatalogDirectory() throws {
        try FileManager.default.createDirectory(
            at: catalogDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func ensurePreviewDirectory() throws {
        try FileManager.default.createDirectory(
            at: catalogDirectoryURL.appendingPathComponent("PreviewImages", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func loadUnifiedCatalogCache() throws -> [CatalogWallpaper] {
        let data = try Data(contentsOf: catalogCacheURL)
        return try JSONDecoder().decode([CatalogWallpaper].self, from: data)
    }

    private func persistUnifiedCatalogCache(
        _ wallpapers: [CatalogWallpaper]
    ) -> CatalogPersistenceStatus {
        do {
            try ensureCatalogDirectory()
            let data = try JSONEncoder().encode(wallpapers)
            try atomicDataWriter(data, catalogCacheURL)
            return .persisted
        } catch {
            catalogPersistenceLogger.error(
                "Unable to persist unified catalog cache: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(
                operation: "unified catalog cache",
                reason: error.localizedDescription
            )
        }
    }

    private func recoveryPersistenceStatus(
        _ status: CatalogPersistenceStatus,
        reason recoveryReason: String
    ) -> CatalogPersistenceStatus {
        switch status {
        case .persisted:
            return .recoveredAndPersisted
        case .failed(_, let writeReason):
            return .recoveredButNotPersisted(
                reason: "\(recoveryReason) Recovery write failed: \(writeReason)"
            )
        case .notAttempted:
            return .recoveredButNotPersisted(
                reason: "\(recoveryReason) No persistence attempt was made."
            )
        case .recoveredAndPersisted, .recoveredButNotPersisted:
            return status
        }
    }

    private func mergeDownloadedWallpapers(
        _ loaded: [DownloadedCatalogWallpaper],
        preserving inMemory: [DownloadedCatalogWallpaper]
    ) -> [DownloadedCatalogWallpaper] {
        var merged = loaded
        let loadedIDs = Set(loaded.map(\.id))
        merged.append(contentsOf: inMemory.filter { item in
            !loadedIDs.contains(item.id)
                && FileManager.default.fileExists(atPath: item.localURL.path)
        })
        return merged.sorted(by: newerFirst)
    }

    private func inferredDownloadedWallpapersFromDisk() throws -> [DownloadedCatalogWallpaper] {
        guard FileManager.default.fileExists(atPath: catalogDirectoryURL.path) else {
            return []
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: catalogDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let validExtensions = Set([
            "mp4", "mov", "m4v", "webm", "mkv", "avi", "flv", "ts", "m2ts", "gif",
            "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "webp"
        ])
        let ignoredNames: Set<String> = [
            "catalog-cache.json",
            "waifu-anime-cache.json",
            "waifu-download-links.json",
            "downloaded-catalog.json",
        ]

        return files.compactMap { fileURL in
            let name = fileURL.lastPathComponent
            guard !ignoredNames.contains(name),
                  validExtensions.contains(fileURL.pathExtension.lowercased())
            else { return nil }

            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            let downloadedAt = values?.contentModificationDate ?? Date()
            let fileName = fileURL.deletingPathExtension().lastPathComponent
            return DownloadedCatalogWallpaper(
                id: "local-\(fileName)",
                wallpaperID: "local-\(fileName)",
                title: inferredTitleFromDownloadedFileName(fileName),
                category: "Downloaded",
                attribution: "Catalog Cache",
                previewImageURL: nil,
                localPreviewPath: existingLocalPreviewImageURL(
                    for: previewImageKey(for: fileURL)
                )?.path,
                sourcePageURL: nil,
                localPath: fileURL.standardizedFileURL.path,
                downloadedAt: downloadedAt
            )
        }.sorted(by: newerFirst)
    }

    private func previewImageURL(for previewKey: String) throws -> URL {
        try ensurePreviewDirectory()
        return catalogDirectoryURL
            .appendingPathComponent("PreviewImages", isDirectory: true)
            .appendingPathComponent("\(previewKey).jpg")
    }

    private func existingLocalPreviewImageURL(for previewKey: String) -> URL? {
        let url = catalogDirectoryURL
            .appendingPathComponent("PreviewImages", isDirectory: true)
            .appendingPathComponent("\(previewKey).jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func previewImageKey(for videoURL: URL) -> String {
        videoURL.standardizedFileURL.deletingPathExtension().lastPathComponent
    }

    private func isImportedLocalWallpaper(
        _ wallpaper: DownloadedCatalogWallpaper,
        from sourceURL: URL
    ) -> Bool {
        guard wallpaper.attribution == "This Mac",
              let originalURL = wallpaper.sourcePageURL,
              originalURL.isFileURL else {
            return false
        }
        return originalURL.standardizedFileURL.path == sourceURL.standardizedFileURL.path
    }

    private func inferredTitleFromDownloadedFileName(_ fileName: String) -> String {
        fileName
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map { part in
                let word = String(part)
                guard let first = word.first else { return word }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private func newerFirst(
        _ lhs: DownloadedCatalogWallpaper,
        _ rhs: DownloadedCatalogWallpaper
    ) -> Bool {
        lhs.downloadedAt > rhs.downloadedAt
    }

    private static func generatePreviewImage(
        for videoURL: URL,
        destinationURL: URL,
        legacyURL: URL?
    ) -> URL? {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }
        if let legacyURL {
            do {
                try FileManager.default.copyItem(at: legacyURL, to: destinationURL)
                return destinationURL
            } catch {
                return legacyURL
            }
        }

        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = NSSize(width: 960, height: 540)
        let time = CMTime(seconds: 0.0, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.82]
        ) else {
            return nil
        }

        do {
            try jpegData.write(to: destinationURL, options: .atomic)
            return destinationURL
        } catch {
            return nil
        }
    }
}

enum CatalogRepositoryError: LocalizedError, Equatable {
    case downloadedFileMissing
    case invalidLocalImport

    var errorDescription: String? {
        switch self {
        case .downloadedFileMissing:
            return "Downloaded wallpaper file is missing."
        case .invalidLocalImport:
            return "The selected wallpaper is not a regular local file."
        }
    }
}
