import Foundation

/// The on-disk recovery record for an Aerial Lock Screen installation.
///
/// Keep these properties in sync with the JSON written by the installer. The
/// optional properties are intentionally optional: they were added over time
/// as the recovery journal learned about lock-screen-only installs, provider
/// refreshes, and media validation.
internal struct AerialLockScreenMarker: Codable {
    var assetID: String
    var assetPath: String
    var thumbnailPath: String?
    var videoPath: String
    var videoSize: UInt64
    var videoModifiedAt: TimeInterval
    var videoSignature: String?
    var assetSignature: String?
    var originalAssetExisted: Bool?
    var originalThumbnailExisted: Bool?
    var originalSystemWallpaperURL: String?
    var systemWallpaperURLWasCaptured: Bool?
    var systemWallpaperURLCaptureVersion: Int?
    var lockScreenOnly: Bool?
    var desktopIncluded: Bool?
    var completed: Bool?
    var mediaKind: String?
    var generation: UInt64?
    var desiredMode: String?
    var lastValidatedStoreHash: String?
    var lastProviderRefreshGeneration: UInt64?
    var lastAssetRepairGeneration: UInt64?
    var fallbackFramePath: String?
    var lastOperationID: UInt64?
    var state: String?
}

/// Persistent state used to rotate through free Aerial cache slots.
internal struct AerialSlotState: Codable {
    var lastAssetID: String?
    var generation: UInt64
}

/// Owns the small recovery journal used by the native Aerial installer.
///
/// The journal deliberately keeps its paths centralized. A partially written
/// install can therefore be recovered using the same paths that were used to
/// create its backups, even if the process that started the install exited.
internal final class LockScreenJournal {
    internal let stateDirectoryURL: URL
    internal let fileManager: FileManager

    internal var markerURL: URL {
        stateDirectoryURL.appendingPathComponent("installation.json")
    }

    internal var wallpaperStoreBackupURL: URL {
        stateDirectoryURL
            .appendingPathComponent("Index.before-auraflow.plist")
    }

    internal var lockSessionStoreBackupURL: URL {
        stateDirectoryURL
            .appendingPathComponent("Index.before-lock-session.plist")
    }

    internal var latestUserWallpaperStoreURL: URL {
        stateDirectoryURL
            .appendingPathComponent("Index.latest-user.plist")
    }

    internal var assetBackupURL: URL {
        stateDirectoryURL
            .appendingPathComponent("aerial.before-auraflow.mov")
    }

    internal var thumbnailBackupURL: URL {
        stateDirectoryURL
            .appendingPathComponent("thumbnail.before-auraflow.png")
    }

    internal var slotStateURL: URL {
        stateDirectoryURL.deletingLastPathComponent()
            .appendingPathComponent("lock_screen_slot_state.json")
    }

    internal init(
        fileManager: FileManager = .default,
        stateDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.stateDirectoryURL = stateDirectoryURL
            ?? WallpaperRuntimeStore.defaultAppSupportURL()
                .appendingPathComponent("ModernLockScreen", isDirectory: true)
    }

    internal convenience init(
        stateDirectoryURL: URL,
        fileManager: FileManager
    ) {
        self.init(
            fileManager: fileManager,
            stateDirectoryURL: stateDirectoryURL
        )
    }

    /// Loads a marker, returning nil for a missing or corrupt journal entry.
    ///
    /// A corrupt marker is intentionally not treated as a valid installation;
    /// the installer can then decide whether its backup set is sufficient for
    /// recovery.
    internal func loadMarker() -> AerialLockScreenMarker? {
        guard let data = try? Data(contentsOf: markerURL) else {
            return nil
        }
        return try? JSONDecoder().decode(
            AerialLockScreenMarker.self,
            from: data
        )
    }

    /// Saves the marker using the existing pretty, sorted JSON representation
    /// and an atomic replacement of the destination file.
    internal func saveMarker(_ marker: AerialLockScreenMarker) throws {
        do {
            try ensureStateDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(marker)
            try data.write(to: markerURL, options: .atomic)
        } catch let error as AerialLockScreenInstallerError {
            throw error
        } catch {
            throw AerialLockScreenInstallerError.wallpaperStoreUpdateFailed
        }
    }

    /// Removes the marker. Missing files are already in the desired state.
    internal func removeMarker() throws {
        try removeIfPresent(at: markerURL)
    }

    /// Loads slot state, returning nil for a missing or corrupt state file.
    internal func loadSlotState() -> AerialSlotState? {
        guard let data = try? Data(contentsOf: slotStateURL) else {
            return nil
        }
        return try? JSONDecoder().decode(AerialSlotState.self, from: data)
    }

    /// Saves slot state using the same compact JSON encoding and atomic write
    /// behavior as the existing installer.
    internal func saveSlotState(_ state: AerialSlotState) throws {
        do {
            try fileManager.createDirectory(
                at: slotStateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: slotStateURL, options: .atomic)
        } catch let error as AerialLockScreenInstallerError {
            throw error
        } catch {
            throw AerialLockScreenInstallerError.wallpaperStoreUpdateFailed
        }
    }

    /// Removes slot state. Missing files are already in the desired state.
    internal func removeSlotState() throws {
        try removeIfPresent(at: slotStateURL)
    }

    /// Builds the conservative marker used when the marker itself is missing
    /// or unreadable but the original wallpaper-store backup remains.
    internal func makeRecoveryMarker(
        assetID: String,
        assetURL: URL,
        thumbnailURL: URL
    ) -> AerialLockScreenMarker? {
        guard fileManager.fileExists(atPath: wallpaperStoreBackupURL.path)
        else {
            return nil
        }

        return AerialLockScreenMarker(
            assetID: assetID,
            assetPath: assetURL.path,
            thumbnailPath: thumbnailURL.path,
            videoPath: "",
            videoSize: 0,
            videoModifiedAt: 0,
            videoSignature: nil,
            assetSignature: nil,
            originalAssetExisted: fileManager.fileExists(
                atPath: assetBackupURL.path
            ),
            originalThumbnailExisted: fileManager.fileExists(
                atPath: thumbnailBackupURL.path
            ),
            originalSystemWallpaperURL: nil,
            systemWallpaperURLWasCaptured: false,
            systemWallpaperURLCaptureVersion: nil,
            lockScreenOnly: nil,
            desktopIncluded: nil,
            completed: false,
            mediaKind: nil,
            generation: nil,
            desiredMode: nil,
            lastValidatedStoreHash: nil,
            lastProviderRefreshGeneration: nil,
            lastAssetRepairGeneration: nil,
            fallbackFramePath: nil,
            lastOperationID: nil,
            state: "recovering"
        )
    }

    /// Removes an orphaned backup set only when no marker exists to authorize
    /// recovery. The operation is best effort, matching installer cleanup
    /// behavior; a failed cleanup must not turn a safe no-op into a mutation.
    internal func removeIncompleteBackupsIfSafe() {
        guard !fileManager.fileExists(atPath: markerURL.path) else {
            return
        }

        try? fileManager.removeItem(at: wallpaperStoreBackupURL)
        try? fileManager.removeItem(at: latestUserWallpaperStoreURL)
        try? fileManager.removeItem(at: lockSessionStoreBackupURL)
        try? fileManager.removeItem(at: assetBackupURL)
        try? fileManager.removeItem(at: thumbnailBackupURL)
        try? fileManager.removeItem(at: stateDirectoryURL)
    }

    private func ensureStateDirectory() throws {
        try fileManager.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func removeIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: url)
        } catch let error as AerialLockScreenInstallerError {
            throw error
        } catch {
            throw AerialLockScreenInstallerError.wallpaperStoreUpdateFailed
        }
    }
}
