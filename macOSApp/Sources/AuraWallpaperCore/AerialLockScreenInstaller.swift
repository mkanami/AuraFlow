import Darwin
import AVFoundation
import CoreFoundation
import Foundation

private let auraFlowAerialProvider = "com.apple.wallpaper.choice.aerials"
private let auraFlowImageProvider = "com.apple.wallpaper.choice.image"
private let auraFlowScreenSaverProvider =
    "com.apple.wallpaper.choice.screen-saver"
private let wallpaperPreferencesApplicationID =
    "com.apple.wallpaper" as CFString
private let systemWallpaperURLPreferenceKey =
    "SystemWallpaperURL" as CFString

private enum AerialLockScreenOperationAbort: Error {
    case sessionChanged
}

private enum AerialWallpaperStoreScope: Equatable {
    case sharedWallpaper
    case lockScreenOnly

    var includesDesktop: Bool {
        self == .sharedWallpaper
    }
}

private struct AerialLockScreenMarker: Codable {
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
}

public enum AerialLockScreenInstallerError: LocalizedError {
    case wallpaperStoreUnavailable
    case aerialAssetUnavailable
    case malformedWallpaperStore
    case wallpaperStoreUpdateFailed
    case aerialProviderRestartFailed
    case aerialVideoPreparationFailed(String)
    case videoMissing(String)

    public var errorDescription: String? {
        switch self {
        case .wallpaperStoreUnavailable:
            return "The macOS wallpaper store is not available."
        case .aerialAssetUnavailable:
            return "Download one Apple Aerial wallpaper before enabling Lock Screen."
        case .malformedWallpaperStore:
            return "The macOS wallpaper store could not be read safely."
        case .wallpaperStoreUpdateFailed:
            return "macOS did not keep the new Lock Screen wallpaper configuration."
        case .aerialProviderRestartFailed:
            return "macOS did not restart the Lock Screen wallpaper provider."
        case .aerialVideoPreparationFailed(let detail):
            return "AuraFlow could not prepare the Lock Screen video: \(detail)"
        case .videoMissing(let path):
            return "Lock Screen video was not found: \(path)"
        }
    }
}

/// Uses macOS's own signed Aerial wallpaper extension for the secure lock
/// screen. Apple does not publish a third-party wallpaper extension API, so
/// AuraFlow reserves one already-downloaded Aerial cache slot and restores
/// every touched file when the feature is disabled.
public final class AerialLockScreenInstaller: LockScreenSaverInstalling {
    private typealias ConditionalSystemAction =
        (_ shouldProceed: () -> Bool) throws -> Void

    public static let preferredAssetID =
        "7C643A39-C0B2-4BA0-8BC2-2EAA47CC580E"

    private let fileManager: FileManager
    private let wallpaperStoreURL: URL
    private let spacesPreferencesURL: URL
    private let aerialVideosURL: URL
    private let aerialThumbnailsURL: URL
    private let aerialProviderURL: URL
    private let stateDirectoryURL: URL
    private let configuredAssetID: String?
    private let refreshSystem: ConditionalSystemAction
    private let rearmSystem: ConditionalSystemAction
    private let desktopRestoreSystem: ConditionalSystemAction
    private let lockSessionHandoffSystem: ConditionalSystemAction
    private let operationLock = NSLock()
    private lazy var supportedProviderAssetIDs =
        loadSupportedProviderAssetIDs()

    private var usesCanonicalWallpaperStore: Bool {
        wallpaperStoreURL.standardizedFileURL
            == Self.defaultWallpaperStoreURL().standardizedFileURL
    }

    private var markerURL: URL {
        stateDirectoryURL.appendingPathComponent("installation.json")
    }

    private var wallpaperStoreBackupURL: URL {
        stateDirectoryURL.appendingPathComponent("Index.before-auraflow.plist")
    }

    private var lockSessionStoreBackupURL: URL {
        stateDirectoryURL.appendingPathComponent("Index.before-lock-session.plist")
    }

    private var assetBackupURL: URL {
        stateDirectoryURL.appendingPathComponent("aerial.before-auraflow.mov")
    }

    private var thumbnailBackupURL: URL {
        stateDirectoryURL.appendingPathComponent("thumbnail.before-auraflow.png")
    }

    public init(
        fileManager: FileManager = .default,
        wallpaperStoreURL: URL? = nil,
        spacesPreferencesURL: URL? = nil,
        aerialVideosURL: URL? = nil,
        aerialThumbnailsURL: URL? = nil,
        aerialProviderURL: URL? = nil,
        stateDirectoryURL: URL? = nil,
        assetID: String? = nil,
        refreshSystem: (() -> Void)? = nil,
        rearmSystem: (() -> Void)? = nil
    ) {
        self.fileManager = fileManager
        let home = fileManager.homeDirectoryForCurrentUser
        let wallpaperSupport = home
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper",
                isDirectory: true
            )
        self.wallpaperStoreURL = wallpaperStoreURL
            ?? wallpaperSupport
                .appendingPathComponent("Store", isDirectory: true)
                .appendingPathComponent("Index.plist")
        self.spacesPreferencesURL = spacesPreferencesURL
            ?? home
                .appendingPathComponent(
                    "Library/Preferences/com.apple.spaces.plist"
                )
        self.aerialVideosURL = aerialVideosURL
            ?? wallpaperSupport
                .appendingPathComponent("aerials/videos", isDirectory: true)
        self.aerialThumbnailsURL = aerialThumbnailsURL
            ?? wallpaperSupport
                .appendingPathComponent(
                    "aerials/thumbnails",
                    isDirectory: true
                )
        self.aerialProviderURL = aerialProviderURL
            ?? URL(
                fileURLWithPath:
                    "/System/Library/ExtensionKit/Extensions/"
                    + "WallpaperAerialsExtension.appex",
                isDirectory: true
            )
        self.stateDirectoryURL = stateDirectoryURL
            ?? WallpaperRuntimeStore.defaultAppSupportURL()
                .appendingPathComponent(
                    "ModernLockScreen",
                    isDirectory: true
                )
        self.configuredAssetID = assetID
        if let refreshSystem {
            self.refreshSystem = { _ in refreshSystem() }
        } else {
            self.refreshSystem = Self.refreshWallpaperProcesses
        }
        if let rearmSystem {
            self.rearmSystem = { _ in rearmSystem() }
            self.desktopRestoreSystem = { _ in rearmSystem() }
            self.lockSessionHandoffSystem = { _ in rearmSystem() }
        } else {
            self.rearmSystem = Self.refreshLockScreenProvider
            // Unlock only needs the provider to remain available while
            // WallpaperAgent rereads the restored Desktop route. Restarting
            // the owner here causes a visible black Desktop during unlock.
            self.desktopRestoreSystem = Self.prewarmLockScreenProvider
            // The provider is already warmed on the dedicated Idle route while
            // the user is unlocked. Do not kill WallpaperAgent after the
            // shield is raised: that leaves loginwindow with a blank surface
            // while the replacement provider is still starting. If the
            // provider is missing, prewarmLockScreenProvider launches it.
            self.lockSessionHandoffSystem = Self.prewarmLockScreenProvider
        }
    }

    public var isInstalled: Bool {
        fileManager.fileExists(atPath: markerURL.path)
    }

    /// True for the dedicated Lock Screen route. Its Aerial asset is kept in
    /// the Idle slot while unlocked and during the secure lock transition,
    /// leaving the user's Desktop configuration intact.
    public var isLockScreenOnlyInstallation: Bool {
        guard let marker = loadMarker() else { return false }
        return marker.completed == true
            && (marker.lockScreenOnly == true || marker.desktopIncluded == false)
    }

    /// macOS resolves the active Aerial choice when loginwindow starts the
    /// real Lock Screen. Dedicated installations promote the Aerial route
    /// only for that transition and restore the user's Desktop route after
    /// unlock.
    public var requiresLockScreenSessionPromotion: Bool {
        guard let marker = loadMarker(), marker.completed == true else {
            return false
        }
        return marker.lockScreenOnly == true
            || (marker.lockScreenOnly != true
                && marker.desktopIncluded == false)
    }

    /// Confirms the system configuration, rather than only checking that our
    /// recovery marker exists. A marker can survive a provider restart or an
    /// incomplete hand-off to loginwindow, so the wallpaper store must still
    /// select AuraFlow's Aerial asset for the installed scope.
    public var installationConfirmed: Bool {
        guard let marker = loadMarker(),
              marker.completed == true,
              fileManager.fileExists(atPath: marker.assetPath),
              providerSupportsAsset(marker.assetID)
        else {
            return false
        }
        let scope: AerialWallpaperStoreScope =
            markerStoreIncludesDesktop(marker)
            ? .sharedWallpaper
            : .lockScreenOnly
        guard !usesCanonicalWallpaperStore
            || systemWallpaperURLMatchesInstalledState(
                assetID: marker.assetID,
                marker: marker
            )
        else {
            return false
        }
        return wallpaperStoreFullySelectsAerial(
            assetID: marker.assetID,
            scope: scope
        )
    }

    public var isAvailable: Bool {
        guard fileManager.fileExists(atPath: wallpaperStoreURL.path),
              let assetID = resolveAssetID()
        else {
            return false
        }
        return providerSupportsAsset(assetID)
    }

    /// Re-applies the managed still frame immediately before a real lock.
    ///
    /// macOS can restore the user's ordinary Desktop picture while the
    /// previous Lock Screen session is being dismissed. The wallpaper store
    /// still points at AuraFlow in that case, but loginwindow can briefly use
    /// the restored Desktop surface for the next lock. Refreshing the current
    /// Desktop surfaces for every session keeps repeated locks consistent.
    @discardableResult
    public func applyCurrentDesktopFallback() -> Bool {
        guard let stillFrameURL = currentStillFrameURL() else {
            return false
        }
        return WallpaperDesktopSupport.applyToAllDesktops(
            imagePath: stillFrameURL.path
        )
    }

    public func install(videoURL: URL) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try withCrossProcessLock {
            _ = try installLocked(
                videoURL: videoURL,
                forceRefresh: false,
                refreshAction: rearmSystem,
                scope: .sharedWallpaper,
                rollbackAction: refreshSystem,
                shouldProceed: { true }
            )
        }
    }

    public func installLockScreenOnly(videoURL: URL) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try withCrossProcessLock {
            _ = try installLocked(
                videoURL: videoURL,
                forceRefresh: false,
                refreshAction: rearmSystem,
                // Keep the user's Desktop route intact while unlocked. The
                // agent promotes this installation to the shared route from
                // the early shield callback immediately before loginwindow
                // resolves the real Lock Screen.
                scope: .lockScreenOnly,
                lockScreenOnlyRoute: true,
                rollbackAction: refreshSystem,
                shouldProceed: { true }
            )
        }
    }

    @discardableResult
    public func repair(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) throws -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try withCrossProcessLock {
            try installLocked(
                videoURL: videoURL,
                forceRefresh: false,
                refreshAction: rearmSystem,
                scope: isLockScreenOnlyInstallation
                    ? .lockScreenOnly
                    : currentWallpaperStoreScope(),
                lockScreenOnlyRoute: isLockScreenOnlyInstallation,
                rollbackAction: refreshSystem,
                shouldProceed: shouldProceed
            )
        }
    }

    @discardableResult
    public func rearmForNextLock(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool = { true }
    ) throws -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try withCrossProcessLock {
            try installLocked(
                videoURL: videoURL,
                forceRefresh: true,
                refreshAction: rearmSystem,
                scope: isLockScreenOnlyInstallation
                    ? .lockScreenOnly
                    : currentWallpaperStoreScope(),
                currentInstallationRefreshAction: usesCanonicalWallpaperStore
                    ? Self.prewarmLockScreenProvider
                    : rearmSystem,
                lockScreenOnlyRoute: isLockScreenOnlyInstallation,
                rollbackAction: refreshSystem,
                shouldProceed: shouldProceed
            )
        }
    }

    private func installLocked(
        videoURL: URL,
        forceRefresh: Bool,
        refreshAction: ConditionalSystemAction,
        scope: AerialWallpaperStoreScope,
        currentInstallationRefreshAction: ConditionalSystemAction? = nil,
        lockScreenOnlyRoute: Bool = false,
        rollbackAction: ConditionalSystemAction,
        shouldProceed: @escaping () -> Bool
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: wallpaperStoreURL.path) else {
            throw AerialLockScreenInstallerError.wallpaperStoreUnavailable
        }
        guard fileManager.fileExists(atPath: videoURL.path) else {
            throw AerialLockScreenInstallerError.videoMissing(videoURL.path)
        }
        guard let assetID = resolveAssetID() else {
            throw AerialLockScreenInstallerError.aerialAssetUnavailable
        }
        guard providerSupportsAsset(assetID) else {
            throw AerialLockScreenInstallerError.aerialAssetUnavailable
        }

        let assetURL = aerialVideosURL
            .appendingPathComponent(assetID)
            .appendingPathExtension("mov")
        let thumbnailURL = aerialThumbnailsURL
            .appendingPathComponent(assetID)
            .appendingPathExtension("png")
        let systemWallpaperURLBeforeAttempt = currentSystemWallpaperURL()

        if installationIsCurrent(
            videoURL: videoURL,
            assetID: assetID,
            scope: scope,
            lockScreenOnlyRoute: lockScreenOnlyRoute
        ) {
            guard forceRefresh, shouldProceed() else {
                return false
            }
            // A lock-only provider can remain alive after unlock while its
            // video reader has already failed. Recreate Apple's owner for the
            // dedicated route so the next lock starts with a fresh reader.
            do {
                if let currentInstallationRefreshAction {
                    try currentInstallationRefreshAction({ shouldProceed() })
                } else {
                    try refreshAction({ shouldProceed() })
                }
            } catch is AerialLockScreenOperationAbort {
                return false
            }
            return true
        }

        let preparedVideoURL = try prepareAerialVideo(from: videoURL)

        guard shouldProceed() else {
            return false
        }

        try fileManager.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true
        )

        let existingMarker = loadMarker()
        let originalSystemWallpaperURL: String?
        let systemWallpaperURLWasCaptured: Bool
        if usesCanonicalWallpaperStore {
            systemWallpaperURLWasCaptured = true
            if existingMarker?.systemWallpaperURLCaptureVersion == 1 {
                originalSystemWallpaperURL =
                    existingMarker?.originalSystemWallpaperURL
            } else {
                originalSystemWallpaperURL = systemWallpaperURLBeforeAttempt
            }
        } else {
            systemWallpaperURLWasCaptured = false
            originalSystemWallpaperURL = nil
        }
        let originalAssetExisted =
            existingMarker?.originalAssetExisted
            ?? (
                fileManager.fileExists(atPath: assetBackupURL.path)
                    || fileManager.fileExists(atPath: assetURL.path)
            )
        let originalThumbnailExisted =
            existingMarker?.originalThumbnailExisted
            ?? (
                fileManager.fileExists(atPath: thumbnailBackupURL.path)
                    || fileManager.fileExists(atPath: thumbnailURL.path)
            )

        let originalStoreData: Data
        if fileManager.fileExists(atPath: wallpaperStoreBackupURL.path) {
            originalStoreData = try Data(contentsOf: wallpaperStoreBackupURL)
        } else {
            let currentStoreData = try Data(contentsOf: wallpaperStoreURL)
            originalStoreData = try cleanedWallpaperStoreData(
                from: currentStoreData
            )
            try originalStoreData.write(
                to: wallpaperStoreBackupURL,
                options: .atomic
            )
        }

        if originalAssetExisted,
           fileManager.fileExists(atPath: assetURL.path),
           !fileManager.fileExists(atPath: assetBackupURL.path) {
            try fileManager.copyItem(at: assetURL, to: assetBackupURL)
        }
        if originalThumbnailExisted,
           fileManager.fileExists(atPath: thumbnailURL.path),
           !fileManager.fileExists(atPath: thumbnailBackupURL.path) {
            try fileManager.copyItem(
                at: thumbnailURL,
                to: thumbnailBackupURL
            )
        }

        let updatedStoreData = try aerialWallpaperStoreData(
            from: originalStoreData,
            assetID: assetID,
            scope: scope
        )
        let storeBeforeAttempt = try Data(contentsOf: wallpaperStoreURL)
        let assetBeforeAttempt = try? Data(contentsOf: assetURL)
        let thumbnailBeforeAttempt = try? Data(contentsOf: thumbnailURL)
        let markerBeforeAttempt = try? Data(contentsOf: markerURL)
        let marker = try marker(
            assetID: assetID,
            assetURL: assetURL,
            thumbnailURL: thumbnailURL,
            videoURL: videoURL,
            installedAssetURL: preparedVideoURL,
            originalAssetExisted: originalAssetExisted,
            originalThumbnailExisted: originalThumbnailExisted,
            originalSystemWallpaperURL: originalSystemWallpaperURL,
            systemWallpaperURLWasCaptured: systemWallpaperURLWasCaptured,
            scope: scope,
            lockScreenOnlyRoute: lockScreenOnlyRoute
        )
        let markerEncoder = JSONEncoder()
        markerEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let markerData = try markerEncoder.encode(marker)

        guard shouldProceed() else {
            return false
        }
        var markerMutated = false
        var assetMutated = false
        var thumbnailMutated = false
        var storeMutated = false
        var systemWallpaperURLMutated = false
        do {
            // The marker is a recovery journal: it must exist before the first
            // system mutation so an interrupted install can always be undone.
            try markerData.write(to: markerURL, options: .atomic)
            markerMutated = true
            guard shouldProceed() else {
                throw AerialLockScreenOperationAbort.sessionChanged
            }
            try replaceFile(
                at: assetURL,
                withContentsOf: preparedVideoURL,
                shouldProceed: shouldProceed
            )
            assetMutated = true
            guard shouldProceed() else {
                throw AerialLockScreenOperationAbort.sessionChanged
            }
            if let currentStillURL = currentStillFrameURL(),
               fileManager.fileExists(atPath: currentStillURL.path) {
                try replaceFile(
                    at: thumbnailURL,
                    withContentsOf: currentStillURL,
                    shouldProceed: shouldProceed
                )
                thumbnailMutated = true
            }
            guard shouldProceed() else {
                throw AerialLockScreenOperationAbort.sessionChanged
            }
            try updatedStoreData.write(
                to: wallpaperStoreURL,
                options: .atomic
            )
            storeMutated = true
            guard shouldProceed() else {
                throw AerialLockScreenOperationAbort.sessionChanged
            }
            if usesCanonicalWallpaperStore {
                guard setSystemWallpaperURL(
                    desiredSystemWallpaperURL(assetID: assetID)
                ) else {
                    throw AerialLockScreenInstallerError
                        .wallpaperStoreUpdateFailed
                }
                systemWallpaperURLMutated = true
            }
            let didRefresh: Bool
            if shouldProceed() {
                try refreshAction({ shouldProceed() })
                didRefresh = true
            } else {
                didRefresh = false
            }
            guard wallpaperStoreFullySelectsAerial(
                assetID: assetID,
                scope: scope
            ) else {
                throw AerialLockScreenInstallerError
                    .wallpaperStoreUpdateFailed
            }
            var completedMarker = marker
            completedMarker.completed = true
            let completedMarkerData = try markerEncoder.encode(completedMarker)
            try completedMarkerData.write(to: markerURL, options: .atomic)
            return didRefresh
        } catch {
            if storeMutated {
                try? storeBeforeAttempt.write(
                    to: wallpaperStoreURL,
                    options: .atomic
                )
            }
            if assetMutated {
                if let assetBeforeAttempt {
                    try? assetBeforeAttempt.write(
                        to: assetURL,
                        options: .atomic
                    )
                } else {
                    try? fileManager.removeItem(at: assetURL)
                }
            }
            if thumbnailMutated {
                if let thumbnailBeforeAttempt {
                    try? thumbnailBeforeAttempt.write(
                        to: thumbnailURL,
                        options: .atomic
                    )
                } else {
                    try? fileManager.removeItem(at: thumbnailURL)
                }
            }
            if systemWallpaperURLMutated {
                _ = setSystemWallpaperURL(systemWallpaperURLBeforeAttempt)
            }
            if markerMutated {
                if let markerBeforeAttempt {
                    try? markerBeforeAttempt.write(
                        to: markerURL,
                        options: .atomic
                    )
                } else {
                    try? fileManager.removeItem(at: markerURL)
                }
            }
            if error is AerialLockScreenOperationAbort {
                return false
            }
            if shouldProceed() {
                try? rollbackAction({ shouldProceed() })
            }
            throw error
        }
    }

    public func uninstall() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try withCrossProcessLock {
            try uninstallLocked()
        }
    }

    private func uninstallLocked() throws {
        let marker: AerialLockScreenMarker
        if let installedMarker = loadMarker() {
            marker = installedMarker
        } else if fileManager.fileExists(atPath: markerURL.path),
                  let recoveryMarker = makeRecoveryMarker() {
            marker = recoveryMarker
        } else if fileManager.fileExists(atPath: markerURL.path) {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        } else {
            removeIncompleteBackupsIfSafe()
            return
        }
        guard fileManager.fileExists(
            atPath: wallpaperStoreBackupURL.path
        ) else {
            throw AerialLockScreenInstallerError.wallpaperStoreUnavailable
        }

        let assetURL = URL(fileURLWithPath: marker.assetPath)
        let thumbnailURL = marker.thumbnailPath.map(URL.init(fileURLWithPath:))
        let storeBeforeAttempt = try? Data(contentsOf: wallpaperStoreURL)
        let assetBeforeAttempt = try? Data(contentsOf: assetURL)
        let thumbnailBeforeAttempt = thumbnailURL.flatMap {
            try? Data(contentsOf: $0)
        }
        let systemWallpaperURLBeforeAttempt = currentSystemWallpaperURL()
        var systemWallpaperURLMutated = false

        do {
            let originalStoreData = try Data(
                contentsOf: wallpaperStoreBackupURL
            )
            var restorationStoreData = originalStoreData
            var preserveCurrentSystemWallpaperURL = false
            if marker.lockScreenOnly == true
                || marker.desktopIncluded == false {
                // Desktop never belongs to AuraFlow in lock-only mode. Start
                // with the complete current store so every display and Space
                // survives unchanged, then restore only Aura-managed modes.
                // If Remove races the shared-Aerial lock handoff, its session
                // snapshot is the complete user store to use instead.
                let sessionData = try? Data(
                    contentsOf: lockSessionStoreBackupURL
                )
                let currentHasUserDesktop = storeBeforeAttempt.map {
                    wallpaperStoreHasUserDesktop(
                        $0,
                        managedAssetID: marker.assetID
                    )
                } ?? false
                let currentHasManagedDesktop = storeBeforeAttempt.map {
                    wallpaperStoreHasManagedDesktop(
                        $0,
                        managedAssetID: marker.assetID
                    )
                } ?? false
                let latestUserStoreData = currentHasUserDesktop
                    && !currentHasManagedDesktop
                    ? storeBeforeAttempt
                    : sessionData
                if let latestUserStoreData {
                    restorationStoreData = try
                        wallpaperStoreDataByPreservingUserDesktops(
                            from: latestUserStoreData,
                            restoringManagedModesFrom: originalStoreData,
                            managedAssetID: marker.assetID
                        )
                    preserveCurrentSystemWallpaperURL = true
                }
            }
            try restorationStoreData.write(
                to: wallpaperStoreURL,
                options: .atomic
            )
            if fileManager.fileExists(atPath: assetBackupURL.path) {
                try replaceFile(
                    at: assetURL,
                    withContentsOf: assetBackupURL
                )
            } else if marker.originalAssetExisted == false {
                try? fileManager.removeItem(at: assetURL)
            }
            if let thumbnailURL,
               fileManager.fileExists(atPath: thumbnailBackupURL.path) {
                try replaceFile(
                    at: thumbnailURL,
                    withContentsOf: thumbnailBackupURL
                )
            } else if let thumbnailURL,
                      marker.originalThumbnailExisted == false {
                try? fileManager.removeItem(at: thumbnailURL)
            }
            if marker.systemWallpaperURLWasCaptured == true,
               !preserveCurrentSystemWallpaperURL {
                guard setSystemWallpaperURL(
                    marker.originalSystemWallpaperURL
                ) else {
                    throw AerialLockScreenInstallerError
                        .wallpaperStoreUpdateFailed
                }
                systemWallpaperURLMutated = true
            }
            var restorationVerified = false
            for _ in 0..<3 {
                try restorationStoreData.write(
                    to: wallpaperStoreURL,
                    options: .atomic
                )
                try refreshSystem({ true })
                Thread.sleep(forTimeInterval: 0.4)
                if wallpaperStoreSemanticallyMatches(
                    expectedData: restorationStoreData
                ) {
                    restorationVerified = true
                    break
                }
            }
            guard restorationVerified else {
                throw AerialLockScreenInstallerError
                    .wallpaperStoreUpdateFailed
            }
            try fileManager.removeItem(at: markerURL)
            try? fileManager.removeItem(at: wallpaperStoreBackupURL)
            try? fileManager.removeItem(at: assetBackupURL)
            try? fileManager.removeItem(at: thumbnailBackupURL)
            try? fileManager.removeItem(at: stateDirectoryURL)
        } catch {
            if let storeBeforeAttempt {
                try? storeBeforeAttempt.write(
                    to: wallpaperStoreURL,
                    options: .atomic
                )
            }
            if let assetBeforeAttempt {
                try? assetBeforeAttempt.write(
                    to: assetURL,
                    options: .atomic
                )
            }
            if let thumbnailURL, let thumbnailBeforeAttempt {
                try? thumbnailBeforeAttempt.write(
                    to: thumbnailURL,
                    options: .atomic
                )
            }
            if systemWallpaperURLMutated {
                _ = setSystemWallpaperURL(systemWallpaperURLBeforeAttempt)
            }
            try? refreshSystem({ true })
            throw error
        }
    }

    private func withCrossProcessLock<T>(
        _ operation: () throws -> T
    ) throws -> T {
        let lockDirectoryURL =
            stateDirectoryURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: lockDirectoryURL,
            withIntermediateDirectories: true
        )
        let lockURL = lockDirectoryURL
            .appendingPathComponent(".modern-lockscreen.lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw AerialLockScreenInstallerError
                .wallpaperStoreUnavailable
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw AerialLockScreenInstallerError
                .wallpaperStoreUnavailable
        }
        return try operation()
    }

    private func resolveAssetID() -> String? {
        if let configuredAssetID {
            return configuredAssetID
        }

        let preferredURL = aerialVideosURL
            .appendingPathComponent(Self.preferredAssetID)
            .appendingPathExtension("mov")
        if fileManager.fileExists(atPath: preferredURL.path) {
            return Self.preferredAssetID
        }

        let candidates = (
            try? fileManager.contentsOfDirectory(
                at: aerialVideosURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        ) ?? []
        return candidates
            .filter { $0.pathExtension.lowercased() == "mov" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { UUID(uuidString: $0) != nil }
            .sorted()
            .first
            ?? Self.preferredAssetID
    }

    private func providerSupportsAsset(_ assetID: String) -> Bool {
        supportedProviderAssetIDs.contains(assetID)
    }

    private func loadSupportedProviderAssetIDs() -> Set<String> {
        let infoURL = aerialProviderURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")
        guard let infoData = try? Data(contentsOf: infoURL),
              let info = try? propertyListDictionary(from: infoData),
              info["CFBundleIdentifier"] as? String
                == "com.apple.wallpaper.extension.aerials",
              let attributes =
                info["EXAppExtensionAttributes"] as? [String: Any],
              attributes["EXExtensionPointIdentifier"] as? String
                == "com.apple.wallpaper"
        else {
            return []
        }

        let resourcesURL = aerialProviderURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        var assetIDs = Set<String>()
        for catalogName in ["entries.json", "entries_variants.json"] {
            let catalogURL = resourcesURL
                .appendingPathComponent(catalogName)
            guard let data = try? Data(contentsOf: catalogURL),
                  let root = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let assets = root["assets"] as? [[String: Any]]
            else {
                continue
            }
            for asset in assets {
                if let assetID = asset["id"] as? String {
                    assetIDs.insert(assetID)
                }
            }
        }
        return assetIDs
    }

    private func cleanedWallpaperStoreData(
        from data: Data
    ) throws -> Data {
        guard var root = try propertyListDictionary(from: data) else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }
        let validTopology = loadValidWallpaperTopology()
        if !validTopology.spaceIDs.isEmpty,
           var spaces = root["Spaces"] as? [String: Any] {
            spaces = spaces.filter {
                validTopology.spaceIDs.contains($0.key)
            }
            spaces = spaces.mapValues { value in
                guard var space = value as? [String: Any] else {
                    return value
                }
                if !validTopology.displayIDs.isEmpty,
                   var displays =
                    space["Displays"] as? [String: Any] {
                    displays = displays.filter {
                        validTopology.displayIDs.contains($0.key)
                    }
                    space["Displays"] = displays
                }
                return space
            }
            root["Spaces"] = spaces
        }
        if !validTopology.displayIDs.isEmpty,
           var displays = root["Displays"] as? [String: Any] {
            displays = displays.filter {
                validTopology.displayIDs.contains($0.key)
            }
            root["Displays"] = displays
        }

        let fallbackDesktop = safeDesktopMode(from: root)
        let fallbackIdle = safeIdleMode(from: root)
        root = mapWallpaperContainers(in: root) { container in
            var result = container
            if let desktop = result["Desktop"] as? [String: Any],
               modeReferencesAuraFlow(desktop) {
                result["Desktop"] = fallbackDesktop
            }
            if let desktop = result["Desktop"] as? [String: Any] {
                result["Desktop"] = normalizeImageModeFiles(desktop)
            }
            if let idle = result["Idle"] as? [String: Any],
               modeReferencesAuraFlow(idle) {
                result["Idle"] = fallbackIdle
            }
            if !validTopology.displayIDs.isEmpty,
               var displays = result["Displays"] as? [String: Any] {
                displays = displays.filter {
                    validTopology.displayIDs.contains($0.key)
                }
                result["Displays"] = displays
            }
            return result
        }
        return try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
    }

    private func aerialWallpaperStoreData(
        from data: Data,
        assetID: String,
        scope: AerialWallpaperStoreScope
    ) throws -> Data {
        guard var root = try propertyListDictionary(from: data) else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }
        let now = Date()
        let aerialMode = makeMode(
            provider: auraFlowAerialProvider,
            configuration: ["assetID": assetID],
            date: now
        )
        root = mapWallpaperContainers(in: root) { container in
            var result = container
            if scope.includesDesktop, result["Desktop"] != nil {
                result["Desktop"] = aerialMode
            }
            if result["Idle"] != nil {
                result["Idle"] = aerialMode
            }
            if result["Desktop"] != nil || result["Idle"] != nil {
                result["Type"] = "individual"
            }
            return result
        }
        return try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
    }

    private func mapWallpaperContainers(
        in root: [String: Any],
        transform: ([String: Any]) -> [String: Any]
    ) -> [String: Any] {
        var result = root
        if let allSpacesAndDisplays =
            result["AllSpacesAndDisplays"] as? [String: Any] {
            result["AllSpacesAndDisplays"] = transform(allSpacesAndDisplays)
        }
        if let systemDefault = result["SystemDefault"] as? [String: Any] {
            result["SystemDefault"] = transform(systemDefault)
        }
        if let displays = result["Displays"] as? [String: Any] {
            result["Displays"] = displays.mapValues { value in
                guard let container = value as? [String: Any] else {
                    return value
                }
                return transform(container)
            }
        }
        if let spaces = result["Spaces"] as? [String: Any] {
            result["Spaces"] = spaces.mapValues { value in
                guard var space = value as? [String: Any] else {
                    return value
                }
                if let defaultContainer =
                    space["Default"] as? [String: Any] {
                    space["Default"] = transform(defaultContainer)
                }
                if let displays =
                    space["Displays"] as? [String: Any] {
                    space["Displays"] = displays.mapValues { displayValue in
                        guard let container =
                            displayValue as? [String: Any] else {
                            return displayValue
                        }
                        return transform(container)
                    }
                }
                return space
            }
        }
        return result
    }

    private func wallpaperStoreDataByPreservingUserDesktops(
        from latestData: Data,
        restoringManagedModesFrom originalData: Data,
        managedAssetID: String
    ) throws -> Data {
        guard var latest = try propertyListDictionary(from: latestData),
              let original = try propertyListDictionary(from: originalData)
        else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }
        let fallbackOriginal =
            original["AllSpacesAndDisplays"] as? [String: Any]
            ?? original["SystemDefault"] as? [String: Any]
            ?? [:]

        func isManaged(_ mode: [String: Any]) -> Bool {
            modeReferencesAuraFlow(mode)
                || modeFullySelectsAerial(
                    mode,
                    assetID: managedAssetID
                )
        }

        func cleanContainer(
            _ latestValue: Any?,
            original originalValue: Any?
        ) -> Any? {
            guard var result = latestValue as? [String: Any] else {
                return latestValue
            }
            let originalContainer = originalValue as? [String: Any]
                ?? fallbackOriginal
            if let desktop = result["Desktop"] as? [String: Any] {
                if isManaged(desktop),
                   let originalDesktop = originalContainer["Desktop"] {
                    result["Desktop"] = originalDesktop
                } else {
                    result["Desktop"] = normalizeImageModeFiles(desktop)
                }
            }
            if let idle = result["Idle"] as? [String: Any],
               isManaged(idle),
               let originalIdle = originalContainer["Idle"] {
                result["Idle"] = originalIdle
            }
            return result
        }

        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            latest[key] = cleanContainer(latest[key], original: original[key])
        }

        if var latestDisplays = latest["Displays"] as? [String: Any] {
            let originalDisplays = original["Displays"] as? [String: Any]
                ?? [:]
            for (displayID, latestContainer) in latestDisplays {
                latestDisplays[displayID] = cleanContainer(
                    latestContainer,
                    original: originalDisplays[displayID]
                )
            }
            latest["Displays"] = latestDisplays
        }

        if var latestSpaces = latest["Spaces"] as? [String: Any] {
            let originalSpaces = original["Spaces"] as? [String: Any] ?? [:]
            for (spaceID, latestSpaceValue) in latestSpaces {
                guard var latestSpace = latestSpaceValue as? [String: Any]
                else { continue }
                let originalSpace = originalSpaces[spaceID]
                    as? [String: Any] ?? [:]
                latestSpace["Default"] = cleanContainer(
                    latestSpace["Default"],
                    original: originalSpace["Default"]
                )
                if var latestDisplays =
                    latestSpace["Displays"] as? [String: Any] {
                    let originalDisplays =
                        originalSpace["Displays"] as? [String: Any] ?? [:]
                    for (displayID, latestContainer) in latestDisplays {
                        latestDisplays[displayID] = cleanContainer(
                            latestContainer,
                            original: originalDisplays[displayID]
                        )
                    }
                    latestSpace["Displays"] = latestDisplays
                }
                latestSpaces[spaceID] = latestSpace
            }
            latest["Spaces"] = latestSpaces
        }

        return try PropertyListSerialization.data(
            fromPropertyList: latest,
            format: .binary,
            options: 0
        )
    }

    private func wallpaperStoreHasUserDesktop(
        _ data: Data,
        managedAssetID: String
    ) -> Bool {
        guard let root = try? propertyListDictionary(from: data) else {
            return false
        }
        var foundUserDesktop = false
        _ = mapWallpaperContainers(in: root) { container in
            if let desktop = container["Desktop"] as? [String: Any],
               !modeReferencesAuraFlow(desktop),
               !modeFullySelectsAerial(
                    desktop,
                    assetID: managedAssetID
               ) {
                foundUserDesktop = true
            }
            return container
        }
        return foundUserDesktop
    }

    private func wallpaperStoreHasManagedDesktop(
        _ data: Data,
        managedAssetID: String
    ) -> Bool {
        guard let root = try? propertyListDictionary(from: data) else {
            return false
        }
        var foundManagedDesktop = false
        _ = mapWallpaperContainers(in: root) { container in
            if let desktop = container["Desktop"] as? [String: Any],
               modeReferencesAuraFlow(desktop)
                || modeFullySelectsAerial(
                    desktop,
                    assetID: managedAssetID
                ) {
                foundManagedDesktop = true
            }
            return container
        }
        return foundManagedDesktop
    }

    private func safeDesktopMode(
        from root: [String: Any]
    ) -> [String: Any] {
        if let mode = (root["SystemDefault"] as? [String: Any])?["Desktop"]
            as? [String: Any],
           !modeReferencesAuraFlow(mode) {
            return mode
        }
        let wallpaperPath = loadOriginalWallpaperPath()
            ?? "/System/Library/Desktop Pictures/Solid Colors/Stone.png"
        return makeMode(
            provider: auraFlowImageProvider,
            configuration: [
                "type": "imageFile",
                "url": ["relative": URL(fileURLWithPath: wallpaperPath).absoluteString],
            ],
            date: Date()
        )
    }

    private func safeIdleMode(
        from root: [String: Any]
    ) -> [String: Any] {
        if let mode = (root["SystemDefault"] as? [String: Any])?["Idle"]
            as? [String: Any],
           !modeReferencesAuraFlow(mode) {
            return mode
        }
        return makeMode(
            provider: auraFlowScreenSaverProvider,
            configuration: [
                "module": [
                    "relative":
                        "file:///System/Library/ExtensionKit/Extensions/Ventura.appex",
                ],
            ],
            date: Date()
        )
    }

    private func makeMode(
        provider: String,
        configuration: [String: Any],
        date: Date
    ) -> [String: Any] {
        let configurationData = try? PropertyListSerialization.data(
            fromPropertyList: configuration,
            format: .binary,
            options: 0
        )
        let files: [Any]
        if provider == auraFlowImageProvider,
           let url = configuration["url"] as? [String: Any],
           let relative = url["relative"] as? String {
            files = [["relative": relative]]
        } else {
            files = []
        }
        return [
            "LastSet": date,
            "LastUse": date,
            "Content": [
                "Choices": [[
                    "Provider": provider,
                    "Files": files,
                    "Configuration": configurationData ?? Data(),
                ]],
                "Shuffle": "$null",
                "EncodedOptionValues": "$null",
            ],
        ]
    }

    private func normalizeImageModeFiles(
        _ mode: [String: Any]
    ) -> [String: Any] {
        guard var content = mode["Content"] as? [String: Any],
              var choices = content["Choices"] as? [[String: Any]]
        else {
            return mode
        }
        var changed = false
        choices = choices.map { choice in
            guard choice["Provider"] as? String == auraFlowImageProvider,
                  let data = choice["Configuration"] as? Data,
                  let configuration =
                    try? propertyListDictionary(from: data),
                  let url = configuration["url"] as? [String: Any],
                  let relative = url["relative"] as? String
            else {
                return choice
            }
            var normalized = choice
            normalized["Files"] = [["relative": relative]]
            changed = true
            return normalized
        }
        guard changed else { return mode }
        content["Choices"] = choices
        var result = mode
        result["Content"] = content
        return result
    }

    private func modeReferencesAuraFlow(_ mode: [String: Any]) -> Bool {
        containsManagedReference(mode)
    }

    private func containsManagedReference(_ value: Any) -> Bool {
        if let string = value as? String {
            let lowered = string.lowercased()
            return lowered.contains("auraflow")
                || lowered.contains("last_frame")
        }
        if let data = value as? Data,
           let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
           ) {
            return containsManagedReference(propertyList)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.contains {
                containsManagedReference($0.key)
                    || containsManagedReference($0.value)
            }
        }
        if let array = value as? [Any] {
            return array.contains(where: containsManagedReference)
        }
        return false
    }

    private func loadValidWallpaperTopology() -> (
        spaceIDs: Set<String>,
        displayIDs: Set<String>
    ) {
        guard let data = try? Data(contentsOf: spacesPreferencesURL),
              let root = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              )
        else {
            return ([], [])
        }
        var spaceIDs = Set<String>()
        var displayIDs = Set<String>()
        collectTopology(
            from: root,
            parentKey: nil,
            spaceIDs: &spaceIDs,
            displayIDs: &displayIDs
        )
        return (spaceIDs, displayIDs)
    }

    private func collectTopology(
        from value: Any,
        parentKey: String?,
        spaceIDs: inout Set<String>,
        displayIDs: inout Set<String>
    ) {
        if let dictionary = value as? [String: Any] {
            for (key, nestedValue) in dictionary {
                if key == "uuid",
                   let uuid = nestedValue as? String,
                   UUID(uuidString: uuid) != nil {
                    spaceIDs.insert(uuid)
                }
                if (key == "ManagedDisplayID"
                    || key == "Display Identifier"),
                   let displayID = nestedValue as? String,
                   displayID != "Main",
                   UUID(uuidString: displayID) != nil {
                    displayIDs.insert(displayID)
                }
                collectTopology(
                    from: nestedValue,
                    parentKey: key,
                    spaceIDs: &spaceIDs,
                    displayIDs: &displayIDs
                )
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectTopology(
                    from: item,
                    parentKey: parentKey,
                    spaceIDs: &spaceIDs,
                    displayIDs: &displayIDs
                )
            }
        }
    }

    /// Promotes the dedicated Lock Screen choice immediately before
    /// loginwindow resolves the secure Lock Screen. The original Desktop
    /// route is restored after unlock.
    @discardableResult
    public func activateLockScreenForCurrentSession() throws -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try withCrossProcessLock {
            guard requiresLockScreenSessionPromotion,
                  let marker = loadMarker(),
                  marker.completed == true
            else {
                return false
            }
            let currentStoreData = try Data(contentsOf: wallpaperStoreURL)
            if markerStoreIncludesDesktop(marker),
               wallpaperStoreFullySelectsAerial(
                   assetID: marker.assetID,
                   scope: .sharedWallpaper
               ),
               systemWallpaperURLMatches(assetID: marker.assetID) {
                return false
            }
            if !wallpaperStoreFullySelectsAerial(
                assetID: marker.assetID,
                scope: .sharedWallpaper
            ) {
                try currentStoreData.write(
                    to: lockSessionStoreBackupURL,
                    options: .atomic
                )
            }
            let activeStoreData = try aerialWallpaperStoreData(
                from: currentStoreData,
                assetID: marker.assetID,
                scope: .sharedWallpaper
            )
            let storeChanged =
                (try? Data(contentsOf: wallpaperStoreURL)) != activeStoreData
            let systemWallpaperURLChanged =
                !systemWallpaperURLMatches(assetID: marker.assetID)
            if storeChanged {
                try activeStoreData.write(
                    to: wallpaperStoreURL,
                    options: .atomic
                )
            }
            guard setSystemWallpaperURL(
                desiredSystemWallpaperURL(assetID: marker.assetID)
            ) else {
                throw AerialLockScreenInstallerError
                    .wallpaperStoreUpdateFailed
            }
            if storeChanged || systemWallpaperURLChanged {
                // The Aerial provider may already have a decoded first frame
                // when loginwindow raises the shield. Killing WallpaperAgent
                // here races that frame and leaves a forced lock on a blank
                // surface while the replacement provider starts. Keep the
                // current provider alive; only launch one when it is absent.
                try lockSessionHandoffSystem({ true })
            }
            return storeChanged || systemWallpaperURLChanged
        }
    }

    /// Restores the user's Desktop/Idle wallpaper route after a temporary
    /// shared Aerial promotion used for the secure Lock Screen.
    @discardableResult
    public func restoreDesktopAfterLockScreenSession() throws -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try withCrossProcessLock {
            guard requiresLockScreenSessionPromotion,
                  let marker = loadMarker(),
                  marker.completed == true
            else {
                return false
            }
            let desktopStoreURL = fileManager.fileExists(
                atPath: lockSessionStoreBackupURL.path
            ) ? lockSessionStoreBackupURL : wallpaperStoreBackupURL
            let desktopStoreData = try Data(contentsOf: desktopStoreURL)
            let lockOnlyStoreData = try aerialWallpaperStoreData(
                from: desktopStoreData,
                assetID: marker.assetID,
                scope: .lockScreenOnly
            )
            let storeChanged =
                (try? Data(contentsOf: wallpaperStoreURL)) != lockOnlyStoreData
            if storeChanged {
                try lockOnlyStoreData.write(
                    to: wallpaperStoreURL,
                    options: .atomic
                )
            }
            if marker.systemWallpaperURLWasCaptured == true {
                guard setSystemWallpaperURL(
                    marker.originalSystemWallpaperURL
                ) else {
                    throw AerialLockScreenInstallerError
                        .wallpaperStoreUpdateFailed
                }
            }
            if storeChanged, usesCanonicalWallpaperStore {
                // WallpaperAgent can keep the temporary Aerial route in
                // memory across unlock. Keep its provider warm only after
                // the user's Desktop/Idle data is written so it rereads the
                // original Desktop choice without a destructive restart.
                try desktopRestoreSystem { true }
            }
            if markerStoreIncludesDesktop(marker) {
                var migratedMarker = marker
                migratedMarker.desktopIncluded = false
                try saveMarker(migratedMarker)
            }
            return storeChanged
        }
    }

    private func loadOriginalWallpaperPath() -> String? {
        let appSupport = WallpaperRuntimeStore.defaultAppSupportURL()
        for fileName in [
            "wallpaper_backup.json",
            "wallpaper_backup_original.json",
        ] {
            let url = appSupport.appendingPathComponent(fileName)
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: String]
            else {
                continue
            }
            if let path = dictionary.values.first(where: {
                !$0.isEmpty
                    && !$0.lowercased().contains("last_frame")
                    && fileManager.fileExists(atPath: $0)
            }) {
                return path
            }
        }
        return nil
    }

    private func propertyListDictionary(
        from data: Data
    ) throws -> [String: Any]? {
        try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
    }

    private func currentSystemWallpaperURL() -> String? {
        guard usesCanonicalWallpaperStore else { return nil }
        return CFPreferencesCopyValue(
            systemWallpaperURLPreferenceKey,
            wallpaperPreferencesApplicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? String
    }

    @discardableResult
    private func setSystemWallpaperURL(_ value: String?) -> Bool {
        guard usesCanonicalWallpaperStore else { return true }
        CFPreferencesSetValue(
            systemWallpaperURLPreferenceKey,
            value as CFPropertyList?,
            wallpaperPreferencesApplicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        let synchronized = CFPreferencesSynchronize(
            wallpaperPreferencesApplicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return synchronized && clearManagedCurrentHostOverride()
    }

    private func clearManagedCurrentHostOverride() -> Bool {
        guard let currentHostValue = CFPreferencesCopyValue(
            systemWallpaperURLPreferenceKey,
            wallpaperPreferencesApplicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? String,
        let currentHostURL = URL(string: currentHostValue),
        currentHostURL.isFileURL
        else {
            return true
        }

        let managedRoot = aerialVideosURL.standardizedFileURL.path
        guard currentHostURL.standardizedFileURL.path
            .hasPrefix(managedRoot + "/")
        else {
            return true
        }

        CFPreferencesSetValue(
            systemWallpaperURLPreferenceKey,
            nil,
            wallpaperPreferencesApplicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        return CFPreferencesSynchronize(
            wallpaperPreferencesApplicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
    }

    private func desiredSystemWallpaperURL(assetID: String) -> String {
        let assetURL = aerialVideosURL
            .appendingPathComponent(assetID)
            .appendingPathExtension("mov")
        return assetURL.standardizedFileURL.absoluteString
    }

    private func systemWallpaperURLMatches(assetID: String) -> Bool {
        guard let currentURLString = currentSystemWallpaperURL(),
              let currentURL = URL(string: currentURLString),
              currentURL.isFileURL,
              let expectedURL = URL(
                  string: desiredSystemWallpaperURL(assetID: assetID)
              )
        else {
            return false
        }
        return currentURL.standardizedFileURL == expectedURL.standardizedFileURL
    }

    private func systemWallpaperURLMatchesInstalledState(
        assetID: String,
        marker: AerialLockScreenMarker
    ) -> Bool {
        if systemWallpaperURLMatches(assetID: assetID) {
            return true
        }
        guard marker.lockScreenOnly == true || marker.desktopIncluded == false
        else {
            return false
        }
        return currentSystemWallpaperURL() == marker.originalSystemWallpaperURL
    }

    private func installationIsCurrent(
        videoURL: URL,
        assetID: String,
        scope: AerialWallpaperStoreScope,
        lockScreenOnlyRoute: Bool
    ) -> Bool {
        guard let marker = loadMarker(),
              marker.completed == true,
              marker.assetID == assetID,
              (marker.lockScreenOnly ?? false) == lockScreenOnlyRoute,
              markerStoreIncludesDesktop(marker) == scope.includesDesktop,
              URL(fileURLWithPath: marker.videoPath).standardizedFileURL
                == videoURL.standardizedFileURL
        else {
            return false
        }

        let assetURL = aerialVideosURL
            .appendingPathComponent(assetID)
            .appendingPathExtension("mov")
        guard URL(fileURLWithPath: marker.assetPath).standardizedFileURL
                == assetURL.standardizedFileURL,
              fileManager.fileExists(atPath: assetURL.path),
              let sourceAttributes = try? fileManager.attributesOfItem(
                atPath: videoURL.path
              )
        else {
            return false
        }

        let sourceSize =
            (sourceAttributes[.size] as? NSNumber)?.uint64Value ?? 0
        let sourceModifiedAt =
            (sourceAttributes[.modificationDate] as? Date)?
                .timeIntervalSince1970
            ?? 0
        guard marker.videoSize == sourceSize,
              abs(marker.videoModifiedAt - sourceModifiedAt) < 0.001
        else {
            return false
        }

        guard let sourceSignature = try? fileSignature(at: videoURL),
              let assetSignature = try? fileSignature(at: assetURL),
              usesCanonicalWallpaperStore
                ? marker.assetSignature == assetSignature
                    && aerialAssetIsCompatible(at: assetURL)
                : sourceSignature == assetSignature
        else {
            return false
        }
        if let markerSignature = marker.videoSignature,
           markerSignature != sourceSignature {
            return false
        }
        guard !usesCanonicalWallpaperStore
            || systemWallpaperURLMatchesInstalledState(
                assetID: assetID,
                marker: marker
            )
        else {
            return false
        }
        return wallpaperStoreFullySelectsAerial(assetID: assetID, scope: scope)
    }

    private func prepareAerialVideo(from sourceURL: URL) throws -> URL {
        guard usesCanonicalWallpaperStore,
              !aerialAssetIsCompatible(at: sourceURL)
        else {
            return sourceURL
        }

        try fileManager.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true
        )
        // The Lock Screen provider only accepts HEVC in a QuickTime movie.
        // Keep the prepared result keyed by the source signature so opening
        // Settings, restarting the agent, or switching back to a wallpaper
        // does not transcode the same file again.
        let sourceSignature = try fileSignature(at: sourceURL)
        let cacheURL = stateDirectoryURL.appendingPathComponent(
            "prepared-\(sourceSignature).mov"
        )
        if fileManager.fileExists(atPath: cacheURL.path),
           aerialAssetIsCompatible(at: cacheURL) {
            return cacheURL
        }

        let outputURL = stateDirectoryURL.appendingPathComponent(
            ".prepared-\(UUID().uuidString).mov"
        )
        defer { try? fileManager.removeItem(at: outputURL) }
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/avconvert")
        process.arguments = [
            "--source", sourceURL.path,
            "--preset", "PresetHEVCHighestQuality",
            "--output", outputURL.path,
            "--replace",
        ]
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            try? fileManager.removeItem(at: outputURL)
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0,
              fileManager.fileExists(atPath: outputURL.path),
              aerialAssetIsCompatible(at: outputURL)
        else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            try? fileManager.removeItem(at: outputURL)
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(
                    detail?.isEmpty == false
                        ? detail!
                        : "HEVC QuickTime conversion failed."
                )
        }
        if fileManager.fileExists(atPath: cacheURL.path) {
            try fileManager.removeItem(at: cacheURL)
        }
        try fileManager.moveItem(at: outputURL, to: cacheURL)
        return cacheURL
    }

    private func aerialAssetIsCompatible(at url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let formatDescription = track.formatDescriptions.first
        else {
            return false
        }
        return CMFormatDescriptionGetMediaSubType(
            formatDescription as! CMFormatDescription
        )
            == kCMVideoCodecType_HEVC
    }

    private func wallpaperStoreFullySelectsAerial(
        assetID: String,
        scope: AerialWallpaperStoreScope
    ) -> Bool {
        guard let data = try? Data(contentsOf: wallpaperStoreURL),
              let root = try? propertyListDictionary(from: data)
        else {
            return false
        }

        var containers: [[String: Any]] = []
        if let allSpacesAndDisplays =
            root["AllSpacesAndDisplays"] as? [String: Any] {
            containers.append(allSpacesAndDisplays)
        }
        if let systemDefault = root["SystemDefault"] as? [String: Any] {
            containers.append(systemDefault)
        }
        if let displays = root["Displays"] as? [String: Any] {
            containers.append(contentsOf: displays.values.compactMap {
                $0 as? [String: Any]
            })
        }
        if let spaces = root["Spaces"] as? [String: Any] {
            for case let space as [String: Any] in spaces.values {
                if let defaultContainer =
                    space["Default"] as? [String: Any] {
                    containers.append(defaultContainer)
                }
                if let displays =
                    space["Displays"] as? [String: Any] {
                    containers.append(contentsOf: displays.values.compactMap {
                        $0 as? [String: Any]
                    })
                }
            }
        }

        var inspectedModes = 0
        for container in containers {
            let modes = scope.includesDesktop ? ["Desktop", "Idle"] : ["Idle"]
            for key in modes {
                guard let mode = container[key] as? [String: Any] else {
                    continue
                }
                inspectedModes += 1
                guard modeFullySelectsAerial(mode, assetID: assetID) else {
                    return false
                }
            }
        }
        return inspectedModes > 0
    }

    private func modeFullySelectsAerial(
        _ mode: [String: Any],
        assetID: String
    ) -> Bool {
        guard let content = mode["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              !choices.isEmpty
        else {
            return false
        }
        return choices.allSatisfy { choice in
            guard choice["Provider"] as? String
                    == auraFlowAerialProvider,
                  let data = choice["Configuration"] as? Data,
                  let configuration =
                    try? propertyListDictionary(from: data)
            else {
                return false
            }
            return configuration["assetID"] as? String == assetID
        }
    }

    private static func defaultWallpaperStoreURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/Store",
                isDirectory: true
            )
            .appendingPathComponent("Index.plist")
    }

    private func fileSignature(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let sampleSize = 64 * 1_024
        let prefix = try handle.read(upToCount: sampleSize) ?? Data()
        let suffixOffset =
            size > UInt64(sampleSize) ? size - UInt64(sampleSize) : 0
        try handle.seek(toOffset: suffixOffset)
        let suffix = try handle.read(upToCount: sampleSize) ?? Data()

        var hash: UInt64 = 14_695_981_039_346_656_037
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        withUnsafeBytes(of: size.littleEndian) { bytes in
            for byte in bytes {
                mix(byte)
            }
        }
        for byte in prefix {
            mix(byte)
        }
        for byte in suffix {
            mix(byte)
        }
        return String(format: "%016llx", hash)
    }

    private func replaceFile(
        at destinationURL: URL,
        withContentsOf sourceURL: URL,
        shouldProceed: (() -> Bool)? = nil
    ) throws {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
            )
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        if let shouldProceed, !shouldProceed() {
            throw AerialLockScreenOperationAbort.sessionChanged
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryURL
            )
        } else {
            try fileManager.moveItem(
                at: temporaryURL,
                to: destinationURL
            )
        }
    }

    private func marker(
        assetID: String,
        assetURL: URL,
        thumbnailURL: URL,
        videoURL: URL,
        installedAssetURL: URL,
        originalAssetExisted: Bool,
        originalThumbnailExisted: Bool,
        originalSystemWallpaperURL: String?,
        systemWallpaperURLWasCaptured: Bool,
        scope: AerialWallpaperStoreScope,
        lockScreenOnlyRoute: Bool
    ) throws -> AerialLockScreenMarker {
        let attributes = try fileManager.attributesOfItem(
            atPath: videoURL.path
        )
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt =
            (attributes[.modificationDate] as? Date)?
                .timeIntervalSince1970
            ?? 0
        return AerialLockScreenMarker(
            assetID: assetID,
            assetPath: assetURL.path,
            thumbnailPath: thumbnailURL.path,
            videoPath: videoURL.path,
            videoSize: size,
            videoModifiedAt: modifiedAt,
            videoSignature: try fileSignature(at: videoURL),
            assetSignature: try fileSignature(at: installedAssetURL),
            originalAssetExisted: originalAssetExisted,
            originalThumbnailExisted: originalThumbnailExisted,
            originalSystemWallpaperURL: originalSystemWallpaperURL,
            systemWallpaperURLWasCaptured: systemWallpaperURLWasCaptured,
            systemWallpaperURLCaptureVersion: systemWallpaperURLWasCaptured
                ? 1
                : nil,
            lockScreenOnly: lockScreenOnlyRoute,
            desktopIncluded: scope.includesDesktop,
            completed: false
        )
    }

    private func currentWallpaperStoreScope() -> AerialWallpaperStoreScope {
        guard let marker = loadMarker() else { return .sharedWallpaper }
        return markerStoreIncludesDesktop(marker)
            ? .sharedWallpaper
            : .lockScreenOnly
    }

    private func markerStoreIncludesDesktop(
        _ marker: AerialLockScreenMarker
    ) -> Bool {
        marker.desktopIncluded ?? (marker.lockScreenOnly != true)
    }

    private func loadMarker() -> AerialLockScreenMarker? {
        guard let data = try? Data(contentsOf: markerURL) else {
            return nil
        }
        return try? JSONDecoder().decode(
            AerialLockScreenMarker.self,
            from: data
        )
    }

    private func saveMarker(_ marker: AerialLockScreenMarker) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: markerURL, options: .atomic)
    }

    private func makeRecoveryMarker() -> AerialLockScreenMarker? {
        guard fileManager.fileExists(
            atPath: wallpaperStoreBackupURL.path
        ) else {
            return nil
        }
        let assetID =
            configuredAssetID
            ?? resolveAssetID()
            ?? Self.preferredAssetID
        let assetURL = aerialVideosURL
            .appendingPathComponent(assetID)
            .appendingPathExtension("mov")
        let thumbnailURL = aerialThumbnailsURL
            .appendingPathComponent(assetID)
            .appendingPathExtension("png")
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
            completed: false
        )
    }

    private func wallpaperStoreSemanticallyMatches(
        expectedData: Data
    ) -> Bool {
        guard let currentData = try? Data(contentsOf: wallpaperStoreURL),
              let currentRoot =
                try? PropertyListSerialization.propertyList(
                    from: currentData,
                    options: [],
                    format: nil
                ),
              let expectedRoot =
                try? PropertyListSerialization.propertyList(
                    from: expectedData,
                    options: [],
                    format: nil
                ),
              let currentComparable = try? PropertyListSerialization.data(
                    fromPropertyList:
                        wallpaperStoreComparableValue(currentRoot),
                    format: .xml,
                    options: 0
              ),
              let expectedComparable = try? PropertyListSerialization.data(
                    fromPropertyList:
                        wallpaperStoreComparableValue(expectedRoot),
                    format: .xml,
                    options: 0
              )
        else {
            return false
        }
        return currentComparable == expectedComparable
    }

    private func wallpaperStoreComparableValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) {
                result,
                entry in
                guard entry.key != "LastSet",
                      entry.key != "LastUse"
                else {
                    return
                }
                result[entry.key] =
                    wallpaperStoreComparableValue(entry.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(wallpaperStoreComparableValue)
        }
        return value
    }

    private func currentStillFrameURL() -> URL? {
        guard usesCanonicalWallpaperStore else {
            return nil
        }
        let url = WallpaperRuntimeStore.defaultAppSupportURL()
            .appendingPathComponent("last_frame.png")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private func removeIncompleteBackupsIfSafe() {
        guard !fileManager.fileExists(atPath: markerURL.path) else {
            return
        }
        try? fileManager.removeItem(at: wallpaperStoreBackupURL)
        try? fileManager.removeItem(at: assetBackupURL)
        try? fileManager.removeItem(at: thumbnailBackupURL)
        try? fileManager.removeItem(at: stateDirectoryURL)
    }

    private static func refreshWallpaperProcesses(
        shouldProceed: () -> Bool
    ) throws {
        for (executable, arguments) in [
            (
                "/usr/bin/pkill",
                ["-x", "WallpaperAerialsExtension"]
            ),
            ("/usr/bin/pkill", ["-x", "legacyScreenSaver"]),
            ("/usr/bin/killall", ["WallpaperAgent"]),
            ("/usr/bin/killall", ["Dock"]),
        ] {
            guard shouldProceed() else {
                throw AerialLockScreenOperationAbort.sessionChanged
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                continue
            }
        }
    }

    private static func refreshLockScreenProvider(
        shouldProceed: () -> Bool
    ) throws {
        guard shouldProceed() else {
            throw AerialLockScreenOperationAbort.sessionChanged
        }
        let previousProviderPIDs = processIdentifiers(
            named: "WallpaperAerialsExtension"
        )
        guard shouldProceed() else {
            throw AerialLockScreenOperationAbort.sessionChanged
        }

        // Restart the owner, not the extension by itself. ExtensionKit does
        // not reliably relaunch an orphaned provider on the next lock, which
        // produces a black screen. WallpaperAgent immediately creates a fresh
        // provider with a new state machine.
        runProcess("/usr/bin/killall", ["WallpaperAgent"])
        // Once the owner has been stopped, waiting is passive and must finish
        // even if a new lock begins. Cancelling here could strand that lock
        // without any provider.
        if waitForFreshProvider(excluding: previousProviderPIDs) {
            return
        }

        // A new lock forbids another destructive kill, but explicitly opening
        // the missing owner is safe and gives the current lock a provider.
        if shouldProceed() {
            runProcess(
                "/usr/bin/pkill",
                ["-x", "WallpaperAerialsExtension"]
            )
        }
        runProcess(
            "/usr/bin/open",
            [
                "-gja",
                "/System/Library/CoreServices/WallpaperAgent.app",
            ]
        )
        guard waitForFreshProvider(excluding: previousProviderPIDs) else {
            throw AerialLockScreenInstallerError
                .aerialProviderRestartFailed
        }
    }

    /// Keeps an already-installed provider warm without killing it. This is
    /// used while the user is unlocked, when the Desktop route must remain
    /// untouched. The lock handoff also keeps the existing provider alive;
    /// the route promotion is written directly to the store before loginwindow
    /// resolves the secure Lock Screen.
    private static func prewarmLockScreenProvider(
        shouldProceed: () -> Bool
    ) throws {
        guard shouldProceed() else {
            throw AerialLockScreenOperationAbort.sessionChanged
        }

        let currentProviderPIDs = processIdentifiers(
            named: "WallpaperAerialsExtension"
        )
        if !currentProviderPIDs.isEmpty {
            return
        }

        runProcess(
            "/usr/bin/open",
            [
                "-gja",
                "/System/Library/CoreServices/WallpaperAgent.app",
            ]
        )
        guard waitForFreshProvider(excluding: currentProviderPIDs) else {
            throw AerialLockScreenInstallerError
                .aerialProviderRestartFailed
        }
    }

    private static func waitForFreshProvider(
        excluding previousPIDs: Set<Int32>
    ) -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let currentPIDs = processIdentifiers(
                named: "WallpaperAerialsExtension"
            )
            if !currentPIDs.isEmpty,
               currentPIDs.isDisjoint(with: previousPIDs) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private static func waitForProcessExit(
        _ process: Process,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.isRunning else { return true }
        process.terminate()
        return false
    }

    private static func processIdentifiers(named name: String) -> Set<Int32> {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            guard waitForProcessExit(process, timeout: 0.25) else {
                return []
            }
        } catch {
            return []
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return Set(
            text.split(whereSeparator: \.isWhitespace)
                .compactMap { Int32($0) }
        )
    }

    private static func runProcess(
        _ executable: String,
        _ arguments: [String]
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            _ = waitForProcessExit(process, timeout: 1.0)
        } catch {
            return
        }
    }
}
