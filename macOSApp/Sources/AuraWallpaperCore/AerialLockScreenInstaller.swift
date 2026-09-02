import Darwin
import AppKit
import AVFoundation
import CoreFoundation
import Foundation
import OSLog

private let auraFlowAerialProvider = "com.apple.wallpaper.choice.aerials"
private let auraFlowImageProvider = "com.apple.wallpaper.choice.image"
private let auraFlowScreenSaverProvider =
    "com.apple.wallpaper.choice.screen-saver"
private let wallpaperPreferencesApplicationID =
    "com.apple.wallpaper" as CFString
private let systemWallpaperURLPreferenceKey =
    "SystemWallpaperURL" as CFString
private let screenSaverPreferencesApplicationID =
    "com.apple.screensaver" as CFString
private let lockScreenRemovalLogger = Logger(
    subsystem: "com.andrijvergeles.auraflow",
    category: "LockScreenRemoval"
)
private let lockScreenLifecycleLogger = Logger(
    subsystem: "com.andrijvergeles.auraflow",
    category: "LockScreenLifecycle"
)

private enum AerialLockScreenOperationAbort: Error {
    case sessionChanged
    case storeChanged
}

private enum AerialWallpaperStoreScope: Equatable {
    case sharedWallpaper
    case lockScreenOnly

    var includesDesktop: Bool {
        self == .sharedWallpaper
    }
}

private enum LockOnlySystemWallpaperURLUpdate {
    case preserve
    case set(String)
    case clear
}

private struct LockOnlyRemovalStorePlan {
    var storeData: Data
    var desktopRoutes: [String: Data]
    var routeCount: Int
    var spaceRouteCount: Int
    var displayRouteCount: Int
    var systemWallpaperURLUpdate: LockOnlySystemWallpaperURLUpdate
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
    var mediaKind: String?
    var generation: UInt64?
    var desiredMode: String?
    var lastValidatedStoreHash: String?
    var lastProviderRefreshGeneration: UInt64?
    var fallbackFramePath: String?
    var lastOperationID: UInt64?
    var state: String?
}

private struct AerialSlotState: Codable {
    var lastAssetID: String?
    var generation: UInt64
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
            return "No free macOS Aerial slot is available. AuraFlow did not change the wallpaper."
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
    var lockOnlyRemovalCommitHook: (() -> Void)?
    var lockOnlyRepairCommitHook: (() -> Void)?
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

    private var latestUserWallpaperStoreURL: URL {
        stateDirectoryURL.appendingPathComponent("Index.latest-user.plist")
    }

    private var assetBackupURL: URL {
        stateDirectoryURL.appendingPathComponent("aerial.before-auraflow.mov")
    }

    private var thumbnailBackupURL: URL {
        stateDirectoryURL.appendingPathComponent("thumbnail.before-auraflow.png")
    }

    private var preparedCacheDirectoryURL: URL {
        stateDirectoryURL.deletingLastPathComponent()
            .appendingPathComponent("LockScreenMediaCache", isDirectory: true)
    }

    private var slotStateURL: URL {
        stateDirectoryURL.deletingLastPathComponent()
            .appendingPathComponent("lock_screen_slot_state.json")
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
        // Dedicated Lock Screen installs stay in Idle for their complete
        // lifetime. Promoting them to Linked/Desktop is what allowed the
        // provider's cached Aerial to spill onto the unlocked Desktop.
        return false
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
        if marker.lockScreenOnly == true
            || marker.desktopIncluded == false {
            return wallpaperStoreFullySelectsAerial(
                assetID: marker.assetID,
                scope: .lockScreenOnly
            ) && (!usesCanonicalWallpaperStore || lockScreenSaverIsSelected())
        }
        guard !usesCanonicalWallpaperStore
            || systemWallpaperURLMatchesInstalledState(
                assetID: marker.assetID,
                marker: marker
            )
        else { return false }
        return wallpaperStoreFullySelectsAerial(
            assetID: marker.assetID,
            scope: .sharedWallpaper
        )
    }

    /// Reads the complete lock-only contract without changing any system
    /// state. A marker and a provider catalog entry are not enough: macOS can
    /// replace the selected Idle route or screen-saver module later.
    public func lockScreenOnlyStatus(
        videoURL: URL?
    ) -> LockScreenOnlyGenerationStatus {
        guard let marker = loadMarker(),
              marker.completed == true,
              (marker.lockScreenOnly == true
                || marker.desktopIncluded == false)
        else {
            return LockScreenOnlyGenerationStatus()
        }

        let resolvedVideoURL = videoURL
            ?? URL(fileURLWithPath: marker.videoPath)
        let sourceMatches: Bool
        if let sourceSignature = try? fileSignature(at: resolvedVideoURL) {
            sourceMatches = URL(fileURLWithPath: marker.videoPath)
                .standardizedFileURL == resolvedVideoURL.standardizedFileURL
                && marker.videoSignature == sourceSignature
        } else {
            sourceMatches = false
        }

        let assetURL = URL(fileURLWithPath: marker.assetPath)
        let currentAssetSignature = try? fileSignature(at: assetURL)
        let assetValid = fileManager.fileExists(atPath: assetURL.path)
            && aerialAssetIsCompatible(at: assetURL)
            && (marker.assetSignature == nil
                || marker.assetSignature == currentAssetSignature)
        let providerAvailable = providerSupportsAsset(marker.assetID)
        let providerRunning = usesCanonicalWallpaperStore
            && !Self.processIdentifiers(named: "WallpaperAerialsExtension")
                .isEmpty
        let storeData = try? Data(contentsOf: wallpaperStoreURL)
        let storeHash = storeData.map(signature(of:))
        let storeValid = storeData.map { data in
            guard let root = try? propertyListDictionary(from: data) else {
                return false
            }
            return wallpaperStoreFullySelectsAerial(
                in: root,
                assetID: marker.assetID,
                scope: .lockScreenOnly
            )
            && !wallpaperStoreContainsAuraInDesktop(
                root,
                assetID: marker.assetID
            )
        } ?? false

        return LockScreenOnlyGenerationStatus(
            installed: true,
            sourceMatches: sourceMatches,
            assetValid: assetValid,
            providerAvailable: providerAvailable,
            providerRunning: providerRunning,
            wallpaperStoreValid: storeValid,
            screenSaverSelected: usesCanonicalWallpaperStore
                ? lockScreenSaverIsSelected()
                : true,
            sourceSignature: marker.videoSignature,
            generation: marker.generation,
            assetID: marker.assetID,
            storeHash: storeHash
        )
    }

    /// Repairs only the lock-only generation. The current store is the sole
    /// source of the user's Desktop routes; snapshots are deliberately not
    /// consulted here. A healthy generation is a complete no-op.
    @discardableResult
    public func repairLockScreenOnlyGeneration(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool = { true }
    ) throws -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try withCrossProcessLock {
            try repairLockScreenOnlyGenerationLocked(
                videoURL: videoURL,
                shouldProceed: shouldProceed
            )
        }
    }

    public var isAvailable: Bool {
        fileManager.fileExists(atPath: wallpaperStoreURL.path)
            && !supportedProviderAssetIDs.isEmpty
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
                // Start owns both surfaces. The wallpaper store and asset can
                // be correct while the already-running provider still holds
                // the previous Lock Screen configuration. Refresh it once so
                // Desktop and Lock Screen commit the same generation before
                // Start reports success.
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
                // A failed Lock-only attempt must not restart Dock. Doing so
                // can bring existing Finder and Wallpaper Settings windows
                // forward even though AuraFlow never asked to open them.
                rollbackAction: Self.prewarmLockScreenProvider,
                shouldProceed: { true }
            )
        }
    }

    /// Warms the persistent Aerial media cache without touching the wallpaper
    /// store or provider. Installation still performs its normal validation
    /// and atomic commit checks; this only moves HEVC conversion off the
    /// button action.
    public func prepareLockScreenMedia(videoURL: URL) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try withCrossProcessLock {
            guard fileManager.fileExists(atPath: wallpaperStoreURL.path) else {
                throw AerialLockScreenInstallerError.wallpaperStoreUnavailable
            }
            guard fileManager.fileExists(atPath: videoURL.path) else {
                throw AerialLockScreenInstallerError.videoMissing(videoURL.path)
            }
            _ = try prepareAerialVideo(from: videoURL)
            lockScreenLifecycleLogger.notice("Prepared Lock Screen media cache")
        }
    }

    private func repairLockScreenOnlyGenerationLocked(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: wallpaperStoreURL.path) else {
            throw AerialLockScreenInstallerError.wallpaperStoreUnavailable
        }
        guard let marker = loadMarker(),
              marker.completed == true,
              (marker.lockScreenOnly == true
                || marker.desktopIncluded == false)
        else {
            return false
        }
        guard URL(fileURLWithPath: marker.videoPath).standardizedFileURL
                == videoURL.standardizedFileURL,
              let sourceSignature = try? fileSignature(at: videoURL),
              marker.videoSignature == sourceSignature,
              shouldProceed()
        else {
            return false
        }

        let currentStoreData = try Data(contentsOf: wallpaperStoreURL)
        guard let currentRoot = try propertyListDictionary(
            from: currentStoreData
        ) else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }
        let currentDesktopRoutes = normalizedDesktopRoutesForComparison(
            try currentDesktopRouteData(
                in: currentRoot,
                managedAssetID: marker.assetID
            )
        )
        guard !currentDesktopRoutes.isEmpty else {
            // There is no safe current user Desktop to preserve. Never guess
            // from Index.before-auraflow.plist or another old snapshot.
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }

        let updatedStoreData = try aerialWallpaperStoreData(
            from: currentStoreData,
            assetID: marker.assetID,
            scope: .lockScreenOnly
        )
        guard let updatedRoot = try propertyListDictionary(
            from: updatedStoreData
        ) else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }
        let updatedDesktopRoutes = normalizedDesktopRoutesForComparison(
            try currentDesktopRouteData(
                in: updatedRoot,
                managedAssetID: marker.assetID
            )
        )
        guard updatedDesktopRoutes == currentDesktopRoutes else {
            throw AerialLockScreenInstallerError.wallpaperStoreUpdateFailed
        }

        let assetURL = URL(fileURLWithPath: marker.assetPath)
        let assetBefore = try? Data(contentsOf: assetURL)
        let assetWasValid = fileManager.fileExists(atPath: assetURL.path)
            && aerialAssetIsCompatible(at: assetURL)
            && (marker.assetSignature == nil
                || marker.assetSignature == (try? fileSignature(at: assetURL)))
        let storeChanged = updatedStoreData != currentStoreData
        let usesCanonicalStore = usesCanonicalWallpaperStore
        let saverWasSelected = usesCanonicalStore
            ? lockScreenSaverIsSelected()
            : true
        let providerWasRunning = usesCanonicalWallpaperStore
            && !Self.processIdentifiers(named: "WallpaperAerialsExtension")
                .isEmpty
        var assetChanged = false
        var selectionChanged = false
        var providerRefreshed = false

        do {
            if !assetWasValid {
                let preparedVideoURL = try prepareAerialVideo(from: videoURL)
                guard shouldProceed() else {
                    throw AerialLockScreenOperationAbort.sessionChanged
                }
                try replaceFile(
                    at: assetURL,
                    withContentsOf: preparedVideoURL,
                    shouldProceed: shouldProceed
                )
                assetChanged = true
            }

            if !saverWasSelected {
                guard selectAuraFlowScreenSaver() else {
                    throw AerialLockScreenInstallerError
                        .wallpaperStoreUpdateFailed
                }
                selectionChanged = true
            }

            if storeChanged {
                guard shouldProceed() else {
                    throw AerialLockScreenOperationAbort.sessionChanged
                }
                lockOnlyRepairCommitHook?()
                // System Settings may have written a newer Desktop route
                // while this repair was preparing media. Never overwrite it.
                guard (try? Data(contentsOf: wallpaperStoreURL)) == currentStoreData
                else {
                    throw AerialLockScreenOperationAbort.storeChanged
                }
                try updatedStoreData.write(
                    to: wallpaperStoreURL,
                    options: .atomic
                )
            }

            guard shouldProceed() else {
                throw AerialLockScreenOperationAbort.sessionChanged
            }

            // A stale WallpaperAgent needs one controlled refresh only after
            // an actual generation repair. A healthy lock/unlock cycle never
            // enters this branch.
            var updatedMarker = marker
            let canRefreshProvider =
                assetChanged || storeChanged
            if canRefreshProvider,
               marker.lastProviderRefreshGeneration != marker.generation {
                try rearmSystem({ shouldProceed() })
                providerRefreshed = true
                updatedMarker.lastProviderRefreshGeneration = marker.generation
            } else if usesCanonicalWallpaperStore, !providerWasRunning {
                try desktopRestoreSystem({ shouldProceed() })
            }

            let observedStoreData = try Data(contentsOf: wallpaperStoreURL)
            guard let observedRoot = try propertyListDictionary(
                from: observedStoreData
            ),
            normalizedDesktopRoutesForComparison(
                try currentDesktopRouteData(
                    in: observedRoot,
                    managedAssetID: marker.assetID
                )
            ) == currentDesktopRoutes,
            wallpaperStoreFullySelectsAerial(
                in: observedRoot,
                assetID: marker.assetID,
                scope: .lockScreenOnly
            ) else {
                throw AerialLockScreenInstallerError
                    .wallpaperStoreUpdateFailed
            }

            updatedMarker.desiredMode = "lockOnly"
            updatedMarker.lastValidatedStoreHash = signature(
                of: observedStoreData
            )
            updatedMarker.fallbackFramePath = currentStillFrameURL()?.path
            updatedMarker.lastOperationID = nil
            updatedMarker.state = "healthy"
            try saveMarker(updatedMarker)

            lockScreenLifecycleLogger.notice(
                "Validated Lock Screen generation repair"
            )
            return assetChanged || storeChanged || selectionChanged
                || providerRefreshed
        } catch {
            if storeChanged,
               (try? Data(contentsOf: wallpaperStoreURL)) == updatedStoreData {
                try? currentStoreData.write(
                    to: wallpaperStoreURL,
                    options: .atomic
                )
            }
            if assetChanged {
                if let assetBefore {
                    try? assetBefore.write(to: assetURL, options: .atomic)
                } else {
                    try? fileManager.removeItem(at: assetURL)
                }
            }
            if error is AerialLockScreenOperationAbort {
                return false
            }
            throw error
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
        guard let assetID = resolveAssetIDForInstallation() else {
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

        // A Desktop-only user change leaves Aura's Idle mode valid, so the
        // installation can still pass installationIsCurrent below. Capture
        // that Desktop before the fast path returns or a later lock repair can
        // erase the newest user choice.
        if lockScreenOnlyRoute,
           fileManager.fileExists(atPath: wallpaperStoreBackupURL.path) {
            _ = try captureLatestUserWallpaperStoreData(
                from: Data(contentsOf: wallpaperStoreURL),
                fallbackData: Data(contentsOf: wallpaperStoreBackupURL),
                managedAssetID: assetID
            )
        }

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

        let updateBaseStoreData: Data
        if lockScreenOnlyRoute {
            // A user can change wallpaper while lock-only mode is active.
            // Journal every user-owned route before Aura mutates the store.
            // This survives a later lock/unlock repair that can replace the
            // public Index before Remove gets a chance to inspect it.
            updateBaseStoreData = try captureLatestUserWallpaperStoreData(
                from: Data(contentsOf: wallpaperStoreURL),
                fallbackData: originalStoreData,
                managedAssetID: assetID
            )
        } else {
            updateBaseStoreData = originalStoreData
        }
        let updatedStoreData = try aerialWallpaperStoreData(
            from: updateBaseStoreData,
            assetID: assetID,
            scope: scope
        )
        let desktopRoutesBeforeAttempt: [String: Data]
        if lockScreenOnlyRoute,
           let updateBaseRoot = try propertyListDictionary(
               from: updateBaseStoreData
           ) {
            desktopRoutesBeforeAttempt = normalizedDesktopRoutesForComparison(
                try currentDesktopRouteData(
                    in: updateBaseRoot,
                    managedAssetID: assetID
                )
            )
        } else {
            desktopRoutesBeforeAttempt = [:]
        }
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
            if usesCanonicalWallpaperStore, !lockScreenOnlyRoute {
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
            // WallpaperAgent may flush its old in-memory Index immediately
            // after being restarted. Reassert the exact desired store before
            // reporting success, but never perform a second provider refresh.
            var configurationConfirmed = false
            for attempt in 0..<3 {
                if wallpaperStoreFullySelectsAerial(
                    assetID: assetID,
                    scope: scope
                ) {
                    configurationConfirmed = true
                    break
                }
                guard shouldProceed() else {
                    throw AerialLockScreenOperationAbort.sessionChanged
                }
                try updatedStoreData.write(
                    to: wallpaperStoreURL,
                    options: .atomic
                )
                if usesCanonicalWallpaperStore, !lockScreenOnlyRoute {
                    guard setSystemWallpaperURL(
                        desiredSystemWallpaperURL(assetID: assetID)
                    ) else {
                        throw AerialLockScreenInstallerError
                            .wallpaperStoreUpdateFailed
                    }
                }
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
            guard configurationConfirmed
                || wallpaperStoreFullySelectsAerial(
                    assetID: assetID,
                    scope: scope
                ) else {
                throw AerialLockScreenInstallerError
                    .wallpaperStoreUpdateFailed
            }
            if lockScreenOnlyRoute {
                guard let observedRoot = try propertyListDictionary(
                    from: Data(contentsOf: wallpaperStoreURL)
                ),
                normalizedDesktopRoutesForComparison(
                    try currentDesktopRouteData(
                        in: observedRoot,
                        managedAssetID: assetID
                    )
                ) == desktopRoutesBeforeAttempt
                else {
                    throw AerialLockScreenInstallerError
                        .wallpaperStoreUpdateFailed
                }
            }
            var completedMarker = marker
            completedMarker.completed = true
            completedMarker.desiredMode = lockScreenOnlyRoute
                ? "lockOnly"
                : "shared"
            completedMarker.lastValidatedStoreHash = signature(
                of: try Data(contentsOf: wallpaperStoreURL)
            )
            completedMarker.fallbackFramePath = currentStillFrameURL()?.path
            completedMarker.state = "healthy"
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

    public func uninstallLockScreenOnlyPreservingCurrentDesktop() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try withCrossProcessLock {
            guard let marker = loadMarker() else {
                if fileManager.fileExists(atPath: markerURL.path) {
                    // A corrupt lock-only marker must never route Remove into
                    // the old full-store recovery path: that could overwrite
                    // the live Desktop with the startup snapshot.
                    throw AerialLockScreenInstallerError
                        .malformedWallpaperStore
                }
                removeIncompleteBackupsIfSafe()
                return
            }
            guard marker.completed == true else {
                throw AerialLockScreenInstallerError
                    .malformedWallpaperStore
            }
            guard marker.lockScreenOnly == true
                    || marker.desktopIncluded == false
            else {
                try uninstallLocked()
                return
            }
            try uninstallLockScreenOnlyPreservingCurrentDesktopLocked(
                marker: marker
            )
        }
    }

    private func uninstallLockScreenOnlyPreservingCurrentDesktopLocked(
        marker: AerialLockScreenMarker
    ) throws {
        guard fileManager.fileExists(atPath: wallpaperStoreURL.path) else {
            throw AerialLockScreenInstallerError.wallpaperStoreUnavailable
        }

        let maximumAttempts = 6
        var committedPlan: LockOnlyRemovalStorePlan?
        for attempt in 1...maximumAttempts {
            let currentStoreData = try Data(contentsOf: wallpaperStoreURL)
            let plan = try lockOnlyRemovalStorePlan(
                from: currentStoreData,
                managedAssetID: marker.assetID
            )
            lockOnlyRemovalCommitHook?()

            // System Settings writes the same store without Aura's lock. Do
            // not overwrite a newer Desktop choice made after our read.
            guard try Data(contentsOf: wallpaperStoreURL)
                    == currentStoreData
            else {
                lockScreenRemovalLogger.debug(
                    "Desktop changed before Remove commit; retry \(attempt, privacy: .public)"
                )
                continue
            }

            try plan.storeData.write(
                to: wallpaperStoreURL,
                options: .atomic
            )
            guard applyLockOnlySystemWallpaperURLUpdate(
                plan.systemWallpaperURLUpdate
            ) else {
                throw AerialLockScreenInstallerError
                    .wallpaperStoreUpdateFailed
            }

            Thread.sleep(forTimeInterval: 0.12)
            let observedStoreData = try Data(contentsOf: wallpaperStoreURL)
            if lockOnlyRemovalStoreIsValid(
                observedStoreData,
                preserving: plan.desktopRoutes,
                managedAssetID: marker.assetID
            ) {
                committedPlan = plan
                break
            }
            lockScreenRemovalLogger.debug(
                "Desktop or Lock Screen changed after Remove commit; retry \(attempt, privacy: .public)"
            )
        }

        guard let committedPlan else {
            lockScreenRemovalLogger.error(
                "Remove could not stabilize the current Desktop routes"
            )
            throw AerialLockScreenInstallerError.wallpaperStoreUpdateFailed
        }

        // The live store is now free of Aura. Only after that is true may the
        // reserved provider slot and recovery files be removed.
        let assetURL = URL(fileURLWithPath: marker.assetPath)
        if fileManager.fileExists(atPath: assetBackupURL.path) {
            try replaceFile(
                at: assetURL,
                withContentsOf: assetBackupURL
            )
        } else if marker.originalAssetExisted == false {
            try? fileManager.removeItem(at: assetURL)
        }
        if let thumbnailPath = marker.thumbnailPath {
            let thumbnailURL = URL(fileURLWithPath: thumbnailPath)
            if fileManager.fileExists(atPath: thumbnailBackupURL.path) {
                try replaceFile(
                    at: thumbnailURL,
                    withContentsOf: thumbnailBackupURL
                )
            } else if marker.originalThumbnailExisted == false {
                try? fileManager.removeItem(at: thumbnailURL)
            }
        }

        try fileManager.removeItem(at: markerURL)
        try? fileManager.removeItem(at: wallpaperStoreBackupURL)
        try? fileManager.removeItem(at: latestUserWallpaperStoreURL)
        try? fileManager.removeItem(at: lockSessionStoreBackupURL)
        try? fileManager.removeItem(at: assetBackupURL)
        try? fileManager.removeItem(at: thumbnailBackupURL)
        try? fileManager.removeItem(at: stateDirectoryURL)

        lockScreenRemovalLogger.info(
            "Removed Aura Lock Screen; Desktop preserved=true routes=\(committedPlan.routeCount, privacy: .public) spaces=\(committedPlan.spaceRouteCount, privacy: .public) displays=\(committedPlan.displayRouteCount, privacy: .public) Aura cleared=true"
        )
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
            if marker.lockScreenOnly == true
                || marker.desktopIncluded == false {
                // Desktop never belongs to AuraFlow in lock-only mode. Start
                // with the complete current store so every display and Space
                // survives unchanged, then restore only Aura-managed modes.
                // If Remove races the shared-Aerial lock handoff, its session
                // snapshot is the complete user store to use instead.
                // A real macOS store can contain the user's newly selected
                // Desktop in one Space and a transient Aura Aerial Desktop in
                // another. Preserve the current store whenever it contains
                // any user Desktop; the merge below replaces only managed
                // modes and keeps every latest user route in place.
                if let storeBeforeAttempt {
                    restorationStoreData = try
                        captureLatestUserWallpaperStoreData(
                            from: storeBeforeAttempt,
                            fallbackData: originalStoreData,
                            managedAssetID: marker.assetID
                        )
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
            if marker.systemWallpaperURLWasCaptured == true {
                let restoredSystemWallpaperURL =
                    latestUserSystemWallpaperURL(
                        from: restorationStoreData,
                        managedAssetID: marker.assetID
                    ) ?? marker.originalSystemWallpaperURL
                guard setSystemWallpaperURL(
                    restoredSystemWallpaperURL
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
            // WallpaperAgent can flush the split lock-only route and its old
            // fallback URL while it is terminating. Reassert both values
            // after the final process refresh so Remove leaves the newest
            // user wallpaper on Desktop and Lock Screen atomically.
            try restorationStoreData.write(
                to: wallpaperStoreURL,
                options: .atomic
            )
            if marker.systemWallpaperURLWasCaptured == true {
                let restoredSystemWallpaperURL =
                    latestUserSystemWallpaperURL(
                        from: restorationStoreData,
                        managedAssetID: marker.assetID
                    ) ?? marker.originalSystemWallpaperURL
                guard setSystemWallpaperURL(
                    restoredSystemWallpaperURL
                ) else {
                    throw AerialLockScreenInstallerError
                        .wallpaperStoreUpdateFailed
                }
            }
            try fileManager.removeItem(at: markerURL)
            try? fileManager.removeItem(at: wallpaperStoreBackupURL)
            try? fileManager.removeItem(at: latestUserWallpaperStoreURL)
            try? fileManager.removeItem(at: lockSessionStoreBackupURL)
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
        if let marker = loadMarker(), marker.completed == true {
            return marker.assetID
        }
        return orderedFreeProviderAssetIDs().first
            ?? supportedProviderAssetIDs.sorted().first
    }

    private func resolveAssetIDForInstallation() -> String? {
        if let configuredAssetID {
            return configuredAssetID
        }
        if let marker = loadMarker(), marker.completed == true {
            return marker.assetID
        }
        guard let assetID = orderedFreeProviderAssetIDs().first else {
            return nil
        }
        var state = loadSlotState()
            ?? AerialSlotState(lastAssetID: nil, generation: 0)
        state.lastAssetID = assetID
        state.generation &+= 1
        do {
            try saveSlotState(state)
        } catch {
            lockScreenLifecycleLogger.error(
                "Failed to persist Aerial slot rotation"
            )
            return nil
        }
        lockScreenLifecycleLogger.notice(
            "Selected free Aerial slot generation=\(state.generation, privacy: .public)"
        )
        return assetID
    }

    private func orderedFreeProviderAssetIDs() -> [String] {
        let free = supportedProviderAssetIDs.filter { assetID in
            let videoURL = aerialVideosURL
                .appendingPathComponent(assetID)
                .appendingPathExtension("mov")
            // Current macOS pre-populates catalog thumbnails even when an
            // Aerial movie was never downloaded or selected by the user.
            // The movie file is the ownership boundary: never replace one.
            // A catalog thumbnail is backed up/restored with the marker.
            return !fileManager.fileExists(atPath: videoURL.path)
        }.sorted()
        guard free.count > 1,
              let lastAssetID = loadSlotState()?.lastAssetID,
              let index = free.firstIndex(of: lastAssetID)
        else {
            return free
        }
        let next = free.index(after: index)
        return Array(free[next...]) + Array(free[..<next])
    }

    private func loadSlotState() -> AerialSlotState? {
        guard let data = try? Data(contentsOf: slotStateURL) else {
            return nil
        }
        return try? JSONDecoder().decode(AerialSlotState.self, from: data)
    }

    private func saveSlotState(_ state: AerialSlotState) throws {
        try fileManager.createDirectory(
            at: slotStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(state).write(
            to: slotStateURL,
            options: .atomic
        )
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
            if let linked = result["Linked"] as? [String: Any] {
                if scope.includesDesktop {
                    result["Linked"] = aerialMode
                    result["Type"] = "linked"
                } else {
                    // Split macOS's shared Linked route without changing the
                    // visible Desktop choice. WallpaperAgent can then prewarm
                    // Aura in Idle before loginwindow raises the lock shield.
                    result.removeValue(forKey: "Linked")
                    result["Desktop"] = linked
                    result["Idle"] = aerialMode
                    result["Type"] = "individual"
                }
                return result
            }
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

    private func normalizedDesktopRoutesForComparison(
        _ routes: [String: Data]
    ) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: routes.map { key, data in
            let normalizedKey: String
            if key.hasSuffix(".Linked") {
                normalizedKey = String(key.dropLast(".Linked".count))
            } else if key.hasSuffix(".Desktop") {
                normalizedKey = String(key.dropLast(".Desktop".count))
            } else {
                normalizedKey = key
            }
            return (normalizedKey, data)
        })
    }

    private func lockOnlyRemovalStorePlan(
        from currentStoreData: Data,
        managedAssetID: String
    ) throws -> LockOnlyRemovalStorePlan {
        guard let root = try propertyListDictionary(
            from: currentStoreData
        ) else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }

        let desktopRoutes = try currentDesktopRouteData(
            in: root,
            managedAssetID: managedAssetID
        )
        guard !desktopRoutes.isEmpty else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }

        var invalidRoute = false
        var selectedModes: [[String: Any]] = []
        var routeCount = 0
        let updatedRoot = mapWallpaperContainers(in: root) { container in
            guard let route = currentUserDesktopRoute(
                in: container,
                managedAssetID: managedAssetID
            ) else {
                if containerContainsManagedWallpaper(
                    container,
                    managedAssetID: managedAssetID
                ) {
                    invalidRoute = true
                }
                return container
            }

            var updated = container
            selectedModes.append(route.mode)
            routeCount += 1
            switch route.key {
            case "Linked":
                // A user-selected Linked route already means Desktop and Lock
                // Screen are identical. Keep that descriptor byte-for-byte.
                if let idle = updated["Idle"] as? [String: Any],
                   modeIsManaged(idle, assetID: managedAssetID) {
                    updated.removeValue(forKey: "Idle")
                }
                if let desktop = updated["Desktop"] as? [String: Any],
                   modeIsManaged(desktop, assetID: managedAssetID) {
                    updated.removeValue(forKey: "Desktop")
                }
                updated["Type"] = "linked"
            default:
                // Desktop is the source of truth. Do not normalize, replace,
                // or timestamp it; copy it only into the ordinary Idle route.
                updated["Idle"] = route.mode
                if let linked = updated["Linked"] as? [String: Any],
                   modeIsManaged(linked, assetID: managedAssetID) {
                    updated.removeValue(forKey: "Linked")
                }
                updated["Type"] = "individual"
            }
            return updated
        }

        guard !invalidRoute, routeCount == desktopRoutes.count else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }
        let updatedData = try PropertyListSerialization.data(
            fromPropertyList: updatedRoot,
            format: .binary,
            options: 0
        )
        let updatedDesktopRoutes = try currentDesktopRouteData(
            in: updatedRoot,
            managedAssetID: managedAssetID
        )
        guard updatedDesktopRoutes == desktopRoutes else {
            throw AerialLockScreenInstallerError.wallpaperStoreUpdateFailed
        }

        return LockOnlyRemovalStorePlan(
            storeData: updatedData,
            desktopRoutes: desktopRoutes,
            routeCount: routeCount,
            spaceRouteCount: desktopRoutes.keys.filter {
                $0.hasPrefix("Spaces.")
            }.count,
            displayRouteCount: desktopRoutes.keys.filter {
                $0.hasPrefix("Displays.") || $0.contains(".Displays.")
            }.count,
            systemWallpaperURLUpdate:
                lockOnlySystemWallpaperURLUpdate(
                    for: selectedModes.first
                )
        )
    }

    private func lockOnlyRemovalStoreIsValid(
        _ storeData: Data,
        preserving expectedDesktopRoutes: [String: Data],
        managedAssetID: String
    ) -> Bool {
        guard let root = try? propertyListDictionary(from: storeData),
              let desktopRoutes = try? currentDesktopRouteData(
                in: root,
                managedAssetID: managedAssetID
              ),
              desktopRoutes == expectedDesktopRoutes
        else {
            return false
        }

        for (_, container) in wallpaperContainersWithPaths(in: root) {
            guard let route = currentUserDesktopRoute(
                in: container,
                managedAssetID: managedAssetID
            ) else {
                if containerContainsManagedWallpaper(
                    container,
                    managedAssetID: managedAssetID
                ) {
                    return false
                }
                continue
            }
            if route.key == "Linked" {
                if containerContainsManagedWallpaper(
                    container,
                    managedAssetID: managedAssetID
                ) {
                    return false
                }
                continue
            }
            guard let idle = container["Idle"] as? [String: Any],
                  !modeIsManaged(idle, assetID: managedAssetID),
                  propertyListData(idle) == propertyListData(route.mode)
            else {
                return false
            }
        }
        return true
    }

    private func currentDesktopRouteData(
        in root: [String: Any],
        managedAssetID: String
    ) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for (path, container) in wallpaperContainersWithPaths(in: root) {
            guard let route = currentUserDesktopRoute(
                in: container,
                managedAssetID: managedAssetID
            ) else {
                continue
            }
            guard let data = propertyListData(route.mode) else {
                throw AerialLockScreenInstallerError.malformedWallpaperStore
            }
            result[path + "." + route.key] = data
        }
        return result
    }

    private func currentUserDesktopRoute(
        in container: [String: Any],
        managedAssetID: String
    ) -> (key: String, mode: [String: Any])? {
        func userMode(_ key: String) -> [String: Any]? {
            guard let mode = container[key] as? [String: Any],
                  !modeIsManaged(mode, assetID: managedAssetID)
            else {
                return nil
            }
            return mode
        }

        if (container["Type"] as? String) == "linked",
           let linked = userMode("Linked") {
            return ("Linked", linked)
        }
        if let desktop = userMode("Desktop") {
            return ("Desktop", desktop)
        }
        if let linked = userMode("Linked") {
            return ("Linked", linked)
        }
        return nil
    }

    private func containerContainsManagedWallpaper(
        _ container: [String: Any],
        managedAssetID: String
    ) -> Bool {
        for key in ["Linked", "Desktop", "Idle"] {
            if let mode = container[key] as? [String: Any],
               modeIsManaged(mode, assetID: managedAssetID) {
                return true
            }
        }
        return false
    }

    private func modeIsManaged(
        _ mode: [String: Any],
        assetID: String
    ) -> Bool {
        // Modern lock-only installation owns exactly the reserved Aerial
        // route recorded in its marker. A user's ordinary image can legally
        // live under AuraFlow/Restored Wallpapers; treating the directory
        // name itself as ownership makes a successful Remove look malformed.
        modeFullySelectsAerial(mode, assetID: assetID)
    }

    private func wallpaperContainersWithPaths(
        in root: [String: Any]
    ) -> [(String, [String: Any])] {
        var result: [(String, [String: Any])] = []
        func append(_ path: String, _ value: Any?) {
            if let container = value as? [String: Any] {
                result.append((path, container))
            }
        }

        append("AllSpacesAndDisplays", root["AllSpacesAndDisplays"])
        append("SystemDefault", root["SystemDefault"])
        if let displays = root["Displays"] as? [String: Any] {
            for displayID in displays.keys.sorted() {
                append("Displays.\(displayID)", displays[displayID])
            }
        }
        if let spaces = root["Spaces"] as? [String: Any] {
            for spaceID in spaces.keys.sorted() {
                guard let space = spaces[spaceID] as? [String: Any] else {
                    continue
                }
                append("Spaces.\(spaceID).Default", space["Default"])
                if let displays = space["Displays"] as? [String: Any] {
                    for displayID in displays.keys.sorted() {
                        append(
                            "Spaces.\(spaceID).Displays.\(displayID)",
                            displays[displayID]
                        )
                    }
                }
            }
        }
        return result
    }

    private func propertyListData(_ value: Any) -> Data? {
        try? PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
    }

    private func lockOnlySystemWallpaperURLUpdate(
        for mode: [String: Any]?
    ) -> LockOnlySystemWallpaperURLUpdate {
        guard let mode,
              let content = mode["Content"] as? [String: Any],
              let choice = (content["Choices"] as? [[String: Any]])?.first
        else {
            return .clear
        }
        if choice["Provider"] as? String == "default" {
            return .preserve
        }
        if let url = systemWallpaperURL(from: mode) {
            return .set(url)
        }
        // Explicit Apple providers such as Sequoia own their descriptor.
        // Keeping a stale file URL here can resurrect a previous Desktop.
        return .clear
    }

    private func applyLockOnlySystemWallpaperURLUpdate(
        _ update: LockOnlySystemWallpaperURLUpdate
    ) -> Bool {
        switch update {
        case .preserve:
            return true
        case .set(let value):
            return setSystemWallpaperURL(
                value,
                clearConflictingCurrentHostOverride: true
            )
        case .clear:
            return setSystemWallpaperURL(
                nil,
                clearConflictingCurrentHostOverride: true
            )
        }
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

        func newestMode(
            _ candidates: [[String: Any]]
        ) -> [String: Any]? {
            guard var newest = candidates.first else { return nil }
            func timestamp(_ mode: [String: Any]) -> Date {
                [mode["LastSet"], mode["LastUse"]]
                    .compactMap { $0 as? Date }
                    .max() ?? .distantPast
            }
            for candidate in candidates.dropFirst()
                where timestamp(candidate) > timestamp(newest) {
                newest = candidate
            }
            return newest
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
            let originalWasLinked = originalContainer["Linked"] != nil
                || (originalContainer["Type"] as? String) == "linked"

            // Lock-only installation splits a user's Linked route into
            // Desktop=user and Idle=Aura so WallpaperAgent can prewarm Aura.
            // On Remove, collapse that synthetic split back to Linked using
            // the latest user Desktop (not the stale pre-install choice).
            if originalWasLinked,
               let idle = result["Idle"] as? [String: Any],
               isManaged(idle) {
                let latestUserMode = newestMode([
                    result["Desktop"] as? [String: Any],
                    result["Linked"] as? [String: Any],
                    originalContainer["Linked"] as? [String: Any],
                ].compactMap { mode in
                    guard let mode, !isManaged(mode) else { return nil }
                    return mode
                })
                if let latestUserMode {
                    result.removeValue(forKey: "Desktop")
                    result.removeValue(forKey: "Idle")
                    result["Linked"] = normalizeImageModeFiles(latestUserMode)
                    result["Type"] = "linked"
                    return result
                }
            }
            if let desktop = result["Desktop"] as? [String: Any] {
                if isManaged(desktop),
                   let originalDesktop = originalContainer["Desktop"] {
                    result["Desktop"] = originalDesktop
                } else {
                    result["Desktop"] = normalizeImageModeFiles(desktop)
                }
            }
            if let linked = result["Linked"] as? [String: Any] {
                if isManaged(linked),
                   let originalLinked = originalContainer["Linked"] {
                    result["Linked"] = originalLinked
                } else {
                    result["Linked"] = normalizeImageModeFiles(linked)
                }
            }
            if let idle = result["Idle"] as? [String: Any],
               isManaged(idle) {
                if let originalIdle = originalContainer["Idle"] {
                    result["Idle"] = originalIdle
                } else {
                    result.removeValue(forKey: "Idle")
                }
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

    /// Captures the newest user-owned wallpaper topology independently from
    /// Aura's temporary Desktop/Idle routes. Every later lock repair, unlock,
    /// Stop, and Remove can therefore restore the latest user choice instead
    /// of falling back to the wallpaper present when Aura first started.
    private func captureLatestUserWallpaperStoreData(
        from currentData: Data,
        fallbackData: Data,
        managedAssetID: String
    ) throws -> Data {
        let previousData = (try? Data(
            contentsOf: latestUserWallpaperStoreURL
        )) ?? fallbackData
        // Older journal revisions could retain Aura's temporary Idle route.
        // Sanitize the journal against the real pre-Aura store before using
        // it as a fallback, otherwise that managed Idle route survives every
        // later capture and Remove restores Aura instead of the user's latest
        // wallpaper on the Lock Screen.
        let sanitizedPreviousData = try
            wallpaperStoreDataByPreservingUserDesktops(
                from: previousData,
                restoringManagedModesFrom: fallbackData,
                managedAssetID: managedAssetID
            )
        let latestData = try wallpaperStoreDataByPreservingUserDesktops(
            from: currentData,
            restoringManagedModesFrom: sanitizedPreviousData,
            managedAssetID: managedAssetID
        )
        try latestData.write(
            to: latestUserWallpaperStoreURL,
            options: .atomic
        )
        return latestData
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
            if let linked = container["Linked"] as? [String: Any],
               !modeReferencesAuraFlow(linked),
               !modeFullySelectsAerial(
                    linked,
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
            if let linked = container["Linked"] as? [String: Any],
               modeReferencesAuraFlow(linked)
                || modeFullySelectsAerial(
                    linked,
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
                  var marker = loadMarker(),
                  marker.completed == true
            else {
                return false
            }
            let currentStoreData = try Data(contentsOf: wallpaperStoreURL)
            let originalStoreData = try Data(
                contentsOf: wallpaperStoreBackupURL
            )
            let latestUserStoreData = try
                captureLatestUserWallpaperStoreData(
                    from: currentStoreData,
                    fallbackData: originalStoreData,
                    managedAssetID: marker.assetID
                )
            if markerStoreIncludesDesktop(marker),
               wallpaperStoreFullySelectsAerial(
                   assetID: marker.assetID,
                   scope: .sharedWallpaper
               ),
               systemWallpaperURLMatches(assetID: marker.assetID) {
                return false
            }
            if marker.systemWallpaperURLWasCaptured == true {
                // The user may change Desktop while lock-only mode is active.
                // Index is authoritative here: SystemWallpaperURL can remain
                // stale while macOS visibly switches a split Desktop route.
                marker.originalSystemWallpaperURL =
                    latestUserSystemWallpaperURL(
                        from: latestUserStoreData,
                        managedAssetID: marker.assetID
                    ) ?? currentSystemWallpaperURL()
                try saveMarker(marker)
            }
            if !wallpaperStoreFullySelectsAerial(
                assetID: marker.assetID,
                scope: .sharedWallpaper
            ) {
                try latestUserStoreData.write(
                    to: lockSessionStoreBackupURL,
                    options: .atomic
                )
            }
            let activeStoreData = try aerialWallpaperStoreData(
                from: latestUserStoreData,
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
            let currentStoreData = try Data(contentsOf: wallpaperStoreURL)
            let hasSessionBackup = fileManager.fileExists(
                atPath: lockSessionStoreBackupURL.path
            )
            let hasManagedDesktop = wallpaperStoreHasManagedDesktop(
                currentStoreData,
                managedAssetID: marker.assetID
            )
            let hasManagedSystemURL = systemWallpaperURLMatches(
                assetID: marker.assetID
            )
            guard hasManagedDesktop || hasManagedSystemURL else {
                // No lock promotion is active. A leftover session snapshot is
                // stale and must never overwrite a Desktop changed by the
                // user while AuraFlow keeps running.
                if hasSessionBackup {
                    try? fileManager.removeItem(
                        at: lockSessionStoreBackupURL
                    )
                }
                return false
            }
            let originalStoreData = try Data(
                contentsOf: wallpaperStoreBackupURL
            )
            let desktopStoreData = try captureLatestUserWallpaperStoreData(
                from: currentStoreData,
                fallbackData: originalStoreData,
                managedAssetID: marker.assetID
            )
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
                let restoredSystemWallpaperURL =
                    latestUserSystemWallpaperURL(
                        from: desktopStoreData,
                        managedAssetID: marker.assetID
                    ) ?? marker.originalSystemWallpaperURL
                guard setSystemWallpaperURL(
                    restoredSystemWallpaperURL
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
            if hasSessionBackup {
                try? fileManager.removeItem(at: lockSessionStoreBackupURL)
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

    /// Resolves the fallback URL that WallpaperAgent uses in addition to
    /// Index.plist. On current macOS, changing a split Desktop route can update
    /// Index without updating SystemWallpaperURL; restarting WallpaperAgent
    /// would then visually resurrect the previous wallpaper.
    func latestUserSystemWallpaperURL(
        from storeData: Data,
        managedAssetID: String
    ) -> String? {
        guard let root = try? propertyListDictionary(from: storeData) else {
            return nil
        }
        var candidates: [(date: Date, url: String)] = []
        _ = mapWallpaperContainers(in: root) { container in
            for key in ["Linked", "Desktop"] {
                guard let mode = container[key] as? [String: Any],
                      !modeReferencesAuraFlow(mode),
                      !modeFullySelectsAerial(
                          mode,
                          assetID: managedAssetID
                      ),
                      let url = systemWallpaperURL(from: mode)
                else {
                    continue
                }
                let date = [mode["LastSet"], mode["LastUse"]]
                    .compactMap { $0 as? Date }
                    .max() ?? .distantPast
                candidates.append((date, url))
            }
            return container
        }
        return candidates.max { $0.date < $1.date }?.url
    }

    private func systemWallpaperURL(
        from mode: [String: Any]
    ) -> String? {
        guard let content = mode["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]]
        else {
            return nil
        }
        for choice in choices {
            let provider = choice["Provider"] as? String
            let configuration: [String: Any]? = {
                guard let data = choice["Configuration"] as? Data else {
                    return nil
                }
                return try? propertyListDictionary(from: data)
            }()
            if provider == auraFlowAerialProvider,
               let assetID = configuration?["assetID"] as? String {
                return aerialVideosURL
                    .appendingPathComponent(assetID)
                    .appendingPathExtension("mov")
                    .standardizedFileURL.absoluteString
            }
            if let url = configuration?["url"] as? [String: Any],
               let relative = url["relative"] as? String,
               let normalized = normalizedWallpaperURLString(relative) {
                return normalized
            }
            if let files = choice["Files"] as? [[String: Any]] {
                for file in files {
                    if let relative = file["relative"] as? String,
                       let normalized = normalizedWallpaperURLString(relative) {
                        return normalized
                    }
                }
            }
        }
        return nil
    }

    private func normalizedWallpaperURLString(
        _ value: String
    ) -> String? {
        if let url = URL(string: value), url.isFileURL {
            return url.standardizedFileURL.absoluteString
        }
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.absoluteString
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

    private func lockScreenSaverURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Screen Savers/AuraFlowLockScreen.saver",
                isDirectory: true
            )
    }

    private func lockScreenSaverIsSelected() -> Bool {
        guard fileManager.fileExists(atPath: lockScreenSaverURL().path) else {
            return false
        }
        guard let module = CFPreferencesCopyValue(
            "moduleDict" as CFString,
            screenSaverPreferencesApplicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? [String: Any],
        let path = module["path"] as? String
        else {
            return false
        }
        return URL(fileURLWithPath: path).standardizedFileURL
            == lockScreenSaverURL().standardizedFileURL
    }

    @discardableResult
    private func selectAuraFlowScreenSaver() -> Bool {
        guard fileManager.fileExists(atPath: lockScreenSaverURL().path) else {
            return false
        }
        let module: [String: Any] = [
            "moduleName": "AuraFlowLockScreen",
            "path": lockScreenSaverURL().standardizedFileURL.path,
            "type": 0,
        ]
        CFPreferencesSetValue(
            "moduleDict" as CFString,
            module as CFPropertyList,
            screenSaverPreferencesApplicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        return CFPreferencesSynchronize(
            screenSaverPreferencesApplicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) && lockScreenSaverIsSelected()
    }

    @discardableResult
    private func setSystemWallpaperURL(
        _ value: String?,
        clearConflictingCurrentHostOverride: Bool = false
    ) -> Bool {
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
        if clearConflictingCurrentHostOverride {
            return synchronized
                && clearCurrentHostOverride(preserving: value)
        }
        return synchronized
            && clearManagedCurrentHostOverride(preserving: value)
    }

    private func clearCurrentHostOverride(
        preserving desiredValue: String?
    ) -> Bool {
        guard let currentHostValue = CFPreferencesCopyValue(
            systemWallpaperURLPreferenceKey,
            wallpaperPreferencesApplicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        ) as? String
        else {
            return true
        }

        if let desiredValue,
           let currentHostURL = URL(string: currentHostValue),
           currentHostURL.isFileURL,
           let desiredURL = URL(string: desiredValue),
           desiredURL.isFileURL,
           currentHostURL.standardizedFileURL
                == desiredURL.standardizedFileURL {
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

    private func clearManagedCurrentHostOverride(
        preserving desiredValue: String?
    ) -> Bool {
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

        if let desiredValue,
           let desiredURL = URL(string: desiredValue),
           desiredURL.isFileURL,
           currentHostURL.standardizedFileURL
                == desiredURL.standardizedFileURL {
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
        if !lockScreenOnlyRoute {
            guard !usesCanonicalWallpaperStore
                || systemWallpaperURLMatchesInstalledState(
                    assetID: assetID,
                    marker: marker
                )
            else {
                return false
            }
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
            at: preparedCacheDirectoryURL,
            withIntermediateDirectories: true
        )
        // The Lock Screen provider only accepts HEVC in a QuickTime movie.
        // Keep the prepared result keyed by the source signature so opening
        // Settings, restarting the agent, or switching back to a wallpaper
        // does not transcode the same file again.
        let sourceSignature = try fileSignature(at: sourceURL)
        let cacheURL = preparedCacheDirectoryURL.appendingPathComponent(
            "prepared-v2-\(sourceSignature).mov"
        )
        if fileManager.fileExists(atPath: cacheURL.path),
           aerialAssetIsCompatible(at: cacheURL) {
            lockScreenLifecycleLogger.notice(
                "Prepared media cache hit"
            )
            return cacheURL
        }

        lockScreenLifecycleLogger.notice("Prepared media cache miss")
        let outputURL = preparedCacheDirectoryURL.appendingPathComponent(
            ".prepared-\(UUID().uuidString).mov"
        )
        defer { try? fileManager.removeItem(at: outputURL) }
        if let image = NSImage(contentsOf: sourceURL) {
            try writeStillImageAerialVideo(
                image,
                to: outputURL
            )
            guard aerialAssetIsCompatible(at: outputURL) else {
                throw AerialLockScreenInstallerError
                    .aerialVideoPreparationFailed(
                        "The prepared image video is not HEVC compatible."
                    )
            }
            if fileManager.fileExists(atPath: cacheURL.path) {
                try fileManager.removeItem(at: cacheURL)
            }
            try fileManager.moveItem(at: outputURL, to: cacheURL)
            return cacheURL
        }
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

    private func writeStillImageAerialVideo(
        _ image: NSImage,
        to outputURL: URL
    ) throws {
        guard let sourceImage = image.cgImage(
            forProposedRect: nil,
            context: nil,
            hints: nil
        ) else {
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed("The image could not be decoded.")
        }

        let maximumWidth = 3840.0
        let maximumHeight = 2160.0
        let scale = min(
            1.0,
            maximumWidth / Double(sourceImage.width),
            maximumHeight / Double(sourceImage.height)
        )
        func evenDimension(_ value: Int) -> Int {
            max(2, value - value % 2)
        }
        let width = evenDimension(
            Int((Double(sourceImage.width) * scale).rounded())
        )
        let height = evenDimension(
            Int((Double(sourceImage.height) * scale).rounded())
        )

        try? fileManager.removeItem(at: outputURL)
        let writer = try AVAssetWriter(
            outputURL: outputURL,
            fileType: .mov
        )
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoAverageBitRateKey: max(
                        2_000_000,
                        min(20_000_000, width * height * 2)
                    ),
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else {
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(
                    "The HEVC image writer could not be initialized."
                )
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(
                    writer.error?.localizedDescription
                        ?? "The HEVC image writer could not start."
                )
        }
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        let bufferStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary,
            &pixelBuffer
        )
        guard bufferStatus == kCVReturnSuccess,
              let pixelBuffer
        else {
            writer.cancelWriting()
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(
                    "The image video pixel buffer could not be created."
                )
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            writer.cancelWriting()
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(
                    "The image video frame could not be rendered."
                )
        }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(
            sourceImage,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )

        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData,
                  writer.status == .writing {
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard writer.status == .writing,
                  adaptor.append(
                    pixelBuffer,
                    withPresentationTime: CMTime(
                        value: Int64(frame),
                        timescale: 30
                    )
                  )
            else {
                writer.cancelWriting()
                throw AerialLockScreenInstallerError
                    .aerialVideoPreparationFailed(
                        writer.error?.localizedDescription
                            ?? "The image video frame could not be encoded."
                    )
            }
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        guard finished.wait(timeout: .now() + 30) == .success,
              writer.status == .completed
        else {
            writer.cancelWriting()
            throw AerialLockScreenInstallerError
                .aerialVideoPreparationFailed(
                    writer.error?.localizedDescription
                        ?? "The image video could not be finalized."
                )
        }
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
        return wallpaperStoreFullySelectsAerial(
            in: root,
            assetID: assetID,
            scope: scope
        )
    }

    private func wallpaperStoreFullySelectsAerial(
        in root: [String: Any],
        assetID: String,
        scope: AerialWallpaperStoreScope
    ) -> Bool {

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

        var inspectedContainers = 0
        for container in containers {
            guard container["Linked"] != nil
                || container["Desktop"] != nil
                || container["Idle"] != nil
            else {
                continue
            }
            inspectedContainers += 1

            if scope.includesDesktop {
                if let linked = container["Linked"] as? [String: Any] {
                    guard modeFullySelectsAerial(
                        linked,
                        assetID: assetID
                    ) else { return false }
                } else {
                    guard let desktop = container["Desktop"] as? [String: Any],
                          let idle = container["Idle"] as? [String: Any],
                          modeFullySelectsAerial(
                              desktop,
                              assetID: assetID
                          ),
                          modeFullySelectsAerial(idle, assetID: assetID)
                    else { return false }
                }
            } else {
                // A lock-only installation must have an Aura Idle route and
                // must never leave Aura in Desktop or Linked.
                guard let idle = container["Idle"] as? [String: Any],
                      modeFullySelectsAerial(idle, assetID: assetID),
                      container["Linked"] == nil
                else { return false }
                if let desktop = container["Desktop"] as? [String: Any] {
                    guard !modeFullySelectsAerial(
                        desktop,
                        assetID: assetID
                    ) else { return false }
                }
            }
        }
        return inspectedContainers > 0
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

    private func wallpaperStoreContainsAuraInDesktop(
        _ root: [String: Any],
        assetID: String
    ) -> Bool {
        wallpaperContainersWithPaths(in: root).contains { _, container in
            if let linked = container["Linked"] as? [String: Any],
               modeFullySelectsAerial(linked, assetID: assetID) {
                return true
            }
            if let desktop = container["Desktop"] as? [String: Any],
               modeFullySelectsAerial(desktop, assetID: assetID) {
                return true
            }
            return false
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

    private func signature(of data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
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
            completed: false,
            mediaKind: WallpaperMediaKind.forURL(videoURL).isStaticImage
                ? "image"
                : "video",
            generation: loadSlotState()?.generation,
            desiredMode: lockScreenOnlyRoute ? "lockOnly" : "shared",
            lastValidatedStoreHash: nil,
            lastProviderRefreshGeneration: nil,
            fallbackFramePath: currentStillFrameURL()?.path,
            lastOperationID: nil,
            state: "preparing"
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
            completed: false,
            mediaKind: nil,
            generation: nil,
            desiredMode: nil,
            lastValidatedStoreHash: nil,
            lastProviderRefreshGeneration: nil,
            fallbackFramePath: nil,
            lastOperationID: nil,
            state: "recovering"
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
        try? fileManager.removeItem(at: latestUserWallpaperStoreURL)
        try? fileManager.removeItem(at: lockSessionStoreBackupURL)
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
        let previousOwnerPIDs = processIdentifiers(named: "WallpaperAgent")
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
        if waitForFreshWallpaperRuntime(
            excludingProviders: previousProviderPIDs,
            excludingOwners: previousOwnerPIDs
        ) {
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
        guard waitForFreshWallpaperRuntime(
            excludingProviders: previousProviderPIDs,
            excludingOwners: previousOwnerPIDs
        ) else {
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
        if !currentProviderPIDs.isEmpty
            || !processIdentifiers(named: "WallpaperAgent").isEmpty {
            return
        }

        runProcess(
            "/usr/bin/open",
            [
                "-gja",
                "/System/Library/CoreServices/WallpaperAgent.app",
            ]
        )
        guard waitForWallpaperRuntime() else {
            throw AerialLockScreenInstallerError
                .aerialProviderRestartFailed
        }
    }

    private static func waitForFreshWallpaperRuntime(
        excludingProviders previousProviderPIDs: Set<Int32>,
        excludingOwners previousOwnerPIDs: Set<Int32>
    ) -> Bool {
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            let currentProviderPIDs = processIdentifiers(
                named: "WallpaperAerialsExtension"
            )
            if !currentProviderPIDs.isEmpty,
               currentProviderPIDs.isDisjoint(with: previousProviderPIDs) {
                return true
            }
            let currentOwnerPIDs = processIdentifiers(named: "WallpaperAgent")
            if !currentOwnerPIDs.isEmpty,
               currentOwnerPIDs.isDisjoint(with: previousOwnerPIDs) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func waitForWallpaperRuntime() -> Bool {
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if !processIdentifiers(named: "WallpaperAerialsExtension").isEmpty
                || !processIdentifiers(named: "WallpaperAgent").isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
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
