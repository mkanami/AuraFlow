import AVFoundation
import AppKit
import Foundation

/// Owns the catalog's durable data and file-system policy.
///
/// `CatalogViewModel` owns presentation state and operation lifetimes. This
/// repository owns catalog cache access, the downloaded manifest, disk
/// inference/merge rules, preview image files, and importing user-selected
/// wallpapers into the managed catalog directory.
final class CatalogRepository {
    struct PreviewGenerationRequest {
        let videoURL: URL
        let legacyWallpaperID: String?
        let wallpaperID: String
    }

    struct RegistrationResult {
        let wallpapers: [DownloadedCatalogWallpaper]
        let previewRequest: PreviewGenerationRequest?
    }

    struct LocalImportResult {
        let url: URL
        let created: Bool
    }

    private let provider: WallpaperCatalogProviding
    let catalogDirectoryURL: URL

    init(
        provider: WallpaperCatalogProviding,
        catalogDirectoryURL: URL
    ) {
        self.provider = provider
        self.catalogDirectoryURL = catalogDirectoryURL.standardizedFileURL
    }

    // MARK: Catalog cache

    func loadCatalogCache() async -> [CatalogWallpaper]? {
        if let cached = loadUnifiedCatalogCache(), !cached.isEmpty {
            return cached
        }
        return await provider.loadCachedCatalog()
    }

    func refreshCatalog(
        progress: @escaping @Sendable ([CatalogWallpaper]) async -> Void
    ) async throws -> [CatalogWallpaper] {
        let wallpapers = try await provider.fetchCatalog(progress: progress)
        if !wallpapers.isEmpty {
            persistUnifiedCatalogCache(wallpapers)
        }
        return wallpapers
    }

    // MARK: Downloaded manifest

    func loadDownloadedWallpapers(
        preserving inMemory: [DownloadedCatalogWallpaper]
    ) -> [DownloadedCatalogWallpaper] {
        let loaded: [DownloadedCatalogWallpaper]
        do {
            guard let data = try? Data(contentsOf: downloadedManifestURL) else {
                let inferred = inferredDownloadedWallpapersFromDisk()
                let merged = mergeDownloadedWallpapers(inferred, preserving: inMemory)
                if !merged.isEmpty {
                    persistDownloadedWallpapers(merged)
                }
                return merged
            }
            loaded = try JSONDecoder().decode([DownloadedCatalogWallpaper].self, from: data)
        } catch {
            return mergeDownloadedWallpapers(
                inferredDownloadedWallpapersFromDisk(),
                preserving: inMemory
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
            sorted = inferredDownloadedWallpapersFromDisk()
        }
        sorted = mergeDownloadedWallpapers(sorted, preserving: inMemory)

        if existing.count != loaded.count {
            persistDownloadedWallpapers(sorted)
        }
        return sorted
    }

    func persistDownloadedWallpapers(_ wallpapers: [DownloadedCatalogWallpaper]) {
        do {
            try ensureCatalogDirectory()
            let data = try JSONEncoder().encode(wallpapers)
            try data.write(to: downloadedManifestURL, options: .atomic)
        } catch {
            // The old UI treated manifest persistence as best effort. Keep the
            // in-memory catalog usable when a removable/read-only volume fails.
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
        persistDownloadedWallpapers(updated)

        let request = localPreviewPath == nil
            ? PreviewGenerationRequest(
                videoURL: localURL,
                legacyWallpaperID: wallpaper.id,
                wallpaperID: wallpaper.id
            )
            : nil
        return RegistrationResult(wallpapers: updated, previewRequest: request)
    }

    func updateGeneratedPreview(
        _ previewURL: URL,
        wallpaperID: String,
        in wallpapers: [DownloadedCatalogWallpaper]
    ) -> [DownloadedCatalogWallpaper] {
        guard let index = wallpapers.firstIndex(where: { $0.wallpaperID == wallpaperID }) else {
            return wallpapers
        }
        let current = wallpapers[index]
        guard current.localPreviewPath != previewURL.path else {
            return wallpapers
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
        persistDownloadedWallpapers(updated)
        return updated
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
        persistDownloadedWallpapers(updated)

        let request = localPreviewPath == nil
            ? PreviewGenerationRequest(
                videoURL: normalizedCopiedURL,
                legacyWallpaperID: nil,
                wallpaperID: entry.wallpaperID
            )
            : nil
        return RegistrationResult(wallpapers: updated, previewRequest: request)
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

    private func loadUnifiedCatalogCache() -> [CatalogWallpaper]? {
        guard let data = try? Data(contentsOf: catalogCacheURL) else { return nil }
        return try? JSONDecoder().decode([CatalogWallpaper].self, from: data)
    }

    private func persistUnifiedCatalogCache(_ wallpapers: [CatalogWallpaper]) {
        do {
            try ensureCatalogDirectory()
            let data = try JSONEncoder().encode(wallpapers)
            try data.write(to: catalogCacheURL, options: .atomic)
        } catch {
            // A provider-specific cache remains available when this optional
            // merged cache cannot be written.
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

    private func inferredDownloadedWallpapersFromDisk() -> [DownloadedCatalogWallpaper] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: catalogDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

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
