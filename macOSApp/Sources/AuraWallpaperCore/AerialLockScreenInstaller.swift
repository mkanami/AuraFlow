import Darwin
@preconcurrency import CoreFoundation
import AppKit
import Foundation
import OSLog

private let wallpaperPreferencesApplicationID =
    WallpaperPlatformConstants.wallpaperApplicationID as CFString
private let systemWallpaperURLPreferenceKey =
    WallpaperPlatformConstants.systemWallpaperURLKey as CFString
private let lockScreenRemovalLogger = Logger(
    subsystem: "com.andrijvergeles.auraflow",
    category: "LockScreenRemoval"
)
private let lockScreenLifecycleLogger = Logger(
    subsystem: "com.andrijvergeles.auraflow",
    category: "LockScreenLifecycle"
)

public enum AerialLockScreenInstallerError: LocalizedError {
    case wallpaperStoreUnavailable
    case aerialAssetUnavailable
    case malformedWallpaperStore
    case wallpaperStoreUpdateFailed
    case aerialProviderRestartFailed
    case aerialAssetReplacedBySystem
    case aerialVideoPreparationFailed(String)
    case videoMissing(String)

    public var errorDescription: String? {
        switch self {
        case .wallpaperStoreUnavailable:
            return "The macOS wallpaper store is not available."
        case .aerialAssetUnavailable:
            return "No downloaded, unused macOS Aerial slot is available. AuraFlow will use the legacy Lock Screen fallback."
        case .malformedWallpaperStore:
            return "The macOS wallpaper store could not be read safely."
        case .wallpaperStoreUpdateFailed:
            return "macOS did not keep the new Lock Screen wallpaper configuration."
        case .aerialProviderRestartFailed:
            return "macOS did not restart the Lock Screen wallpaper provider."
        case .aerialAssetReplacedBySystem:
            return "macOS replaced the reserved Aerial asset. AuraFlow stopped native repair and will use the legacy Lock Screen fallback."
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
public final class AerialLockScreenInstaller: ModernLockScreenInstalling {
    private typealias ConditionalSystemAction =
        (_ shouldProceed: () -> Bool) throws -> Void
    private typealias PreparedConditionalSystemAction =
        (
            _ prepareForLaunch: () throws -> Void,
            _ shouldProceed: () -> Bool
        ) throws -> Void

    public static let preferredAssetID =
        "7C643A39-C0B2-4BA0-8BC2-2EAA47CC580E"

    private let fileManager: FileManager
    private let wallpaperStoreURL: URL
    private let stateDirectoryURL: URL
    private let configuredAssetID: String?
    private let refreshSystem: ConditionalSystemAction
    private let sharedDesktopRestoreSystem: PreparedConditionalSystemAction
    private let rearmSystem: ConditionalSystemAction
    private let desktopRestoreSystem: ConditionalSystemAction
    private let lockSessionHandoffSystem: ConditionalSystemAction
    private let journal: LockScreenJournal
    private let assetStore: AerialAssetStore
    private let mediaPreparer: AerialMediaPreparer
    private let wallpaperStoreTransaction: WallpaperStoreTransaction
    private let mutationCoordinator = AerialMutationCoordinator()
    private var wallpaperStoreChangeMonitor: WallpaperStoreChangeMonitor?
    var lockOnlyRemovalCommitHook: (() -> Void)?
    var lockOnlyRepairCommitHook: (() -> Void)?
    var sharedDesktopImageRestoreHook: ((String) -> Bool)?
    private var usesCanonicalWallpaperStore: Bool {
        wallpaperStoreURL.standardizedFileURL
            == Self.defaultWallpaperStoreURL().standardizedFileURL
    }

    private var markerURL: URL {
        journal.markerURL
    }

    private var wallpaperStoreBackupURL: URL {
        journal.wallpaperStoreBackupURL
    }

    private var lockSessionStoreBackupURL: URL {
        journal.lockSessionStoreBackupURL
    }

    private var latestUserWallpaperStoreURL: URL {
        journal.latestUserWallpaperStoreURL
    }

    private var assetBackupURL: URL {
        journal.assetBackupURL
    }

    private var thumbnailBackupURL: URL {
        journal.thumbnailBackupURL
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
        rearmSystem: (() -> Void)? = nil,
        lockSessionHandoffSystem: (() -> Void)? = nil
    ) {
        self.fileManager = fileManager
        let home = fileManager.homeDirectoryForCurrentUser
        let wallpaperSupport = WallpaperPlatformConstants.wallpaperSupportURL(
            homeURL: home
        )
        let resolvedWallpaperStoreURL = wallpaperStoreURL
            ?? WallpaperPlatformConstants.wallpaperStoreURL(homeURL: home)
        let resolvedSpacesPreferencesURL = spacesPreferencesURL
            ?? home
                .appendingPathComponent(
                    "Library/Preferences/com.apple.spaces.plist"
                )
        let resolvedAerialVideosURL = aerialVideosURL
            ?? wallpaperSupport
                .appendingPathComponent(
                    WallpaperPlatformConstants.aerialVideosRelativePath,
                    isDirectory: true
                )
        let resolvedAerialThumbnailsURL = aerialThumbnailsURL
            ?? wallpaperSupport
                .appendingPathComponent(
                    WallpaperPlatformConstants.aerialThumbnailsRelativePath,
                    isDirectory: true
                )
        let resolvedAerialProviderURL = aerialProviderURL
            ?? URL(
                fileURLWithPath:
                    WallpaperPlatformConstants.aerialProviderPath,
                isDirectory: true
            )
        let resolvedStateDirectoryURL = stateDirectoryURL
            ?? WallpaperRuntimeStore.defaultAppSupportURL()
                .appendingPathComponent(
                    "ModernLockScreen",
                    isDirectory: true
                )
        self.wallpaperStoreURL = resolvedWallpaperStoreURL
        self.stateDirectoryURL = resolvedStateDirectoryURL
        self.journal = LockScreenJournal(
            stateDirectoryURL: resolvedStateDirectoryURL,
            fileManager: fileManager
        )
        self.assetStore = AerialAssetStore(
            fileManager: fileManager,
            aerialVideosURL: resolvedAerialVideosURL,
            aerialThumbnailsURL: resolvedAerialThumbnailsURL,
            aerialProviderURL: resolvedAerialProviderURL
        )
        self.mediaPreparer = AerialMediaPreparer(
            fileManager: fileManager,
            usesCanonicalWallpaperStore:
                resolvedWallpaperStoreURL.standardizedFileURL
                == Self.defaultWallpaperStoreURL().standardizedFileURL,
            preparedCacheDirectoryURL: resolvedStateDirectoryURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "LockScreenMediaCache",
                    isDirectory: true
                )
        )
        self.wallpaperStoreTransaction = WallpaperStoreTransaction(
            fileManager: fileManager,
            wallpaperStoreURL: resolvedWallpaperStoreURL,
            spacesPreferencesURL: resolvedSpacesPreferencesURL,
            aerialVideosURL: resolvedAerialVideosURL,
            latestUserWallpaperStoreURL: resolvedStateDirectoryURL
                .appendingPathComponent("Index.latest-user.plist")
        )
        self.configuredAssetID = assetID
        if let refreshSystem {
            self.refreshSystem = { _ in refreshSystem() }
            self.sharedDesktopRestoreSystem = { prepareForLaunch, _ in
                try prepareForLaunch()
                refreshSystem()
            }
        } else {
            self.refreshSystem = AerialProviderController
                .refreshWallpaperProcesses
            self.sharedDesktopRestoreSystem = AerialProviderController
                .refreshDesktopWallpaperProvider
        }
        if let rearmSystem {
            self.rearmSystem = { _ in rearmSystem() }
            self.desktopRestoreSystem = { _ in rearmSystem() }
            self.lockSessionHandoffSystem = { _ in
                if let lockSessionHandoffSystem {
                    lockSessionHandoffSystem()
                } else {
                    rearmSystem()
                }
            }
        } else {
            self.rearmSystem = AerialProviderController
                .refreshLockScreenProvider
            // Unlock only needs the provider to remain available while
            // WallpaperAgent rereads the restored Desktop route. Restarting
            // the owner here causes a visible black Desktop during unlock.
            self.desktopRestoreSystem = AerialProviderController
                .prewarmLockScreenProvider
            // The provider is already warmed on the dedicated Idle route while
            // the user is unlocked. Do not kill WallpaperAgent after the
            // shield is raised: that leaves loginwindow with a blank surface
            // while the replacement provider is still starting. If the
            // provider is missing, prewarmLockScreenProvider launches it.
            if let lockSessionHandoffSystem {
                self.lockSessionHandoffSystem = { _ in
                    lockSessionHandoffSystem()
                }
            } else {
                self.lockSessionHandoffSystem = AerialProviderController
                    .prewarmLockScreenProvider
            }
        }
        startDesktopWallpaperChangeMonitorIfNeeded()
    }

    deinit {
        wallpaperStoreChangeMonitor?.stop()
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
            && markerUsesDedicatedLockOnlyRuntime(marker)
    }

    private var isDesktopAgentIsolatedInstallation: Bool {
        guard let marker = loadMarker() else { return false }
        return marker.completed == true
            && marker.lockScreenOnly == false
            && marker.desktopIncluded == false
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
              assetStore.providerSupportsAsset(marker.assetID),
              assetStore.managedAssetSignature(
                  at: URL(fileURLWithPath: marker.assetPath)
              ) == marker.assetSignature
        else {
            return false
        }
        if marker.lockScreenOnly == true
            || marker.desktopIncluded == false {
            let storeIsCorrect = wallpaperStoreTransaction
                .wallpaperStoreFullySelectsAerial(
                assetID: marker.assetID,
                scope: .lockScreenOnly
                )
            guard storeIsCorrect else { return false }
            if usesCanonicalWallpaperStore {
                let systemURLMatches = markerUsesDedicatedLockOnlyRuntime(marker)
                    ? systemWallpaperURLMatches(assetID: marker.assetID)
                    : systemWallpaperURLMatchesInstalledState(
                        assetID: marker.assetID,
                        marker: marker
                    )
                guard systemURLMatches
                else { return false }
            }
            return true
        }
        guard !usesCanonicalWallpaperStore
            || systemWallpaperURLMatchesInstalledState(
                assetID: marker.assetID,
                marker: marker
            )
        else { return false }
        return wallpaperStoreTransaction.wallpaperStoreFullySelectsAerial(
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
              markerUsesDedicatedLockOnlyRuntime(marker)
        else {
            return LockScreenOnlyGenerationStatus()
        }

        let resolvedVideoURL = videoURL
            ?? URL(fileURLWithPath: marker.videoPath)
        let sourceMatches: Bool
        if let sourceSignature = try? mediaPreparer.fileSignature(
            at: resolvedVideoURL
        ) {
            sourceMatches = URL(fileURLWithPath: marker.videoPath)
                .standardizedFileURL == resolvedVideoURL.standardizedFileURL
                && marker.videoSignature == sourceSignature
        } else {
            sourceMatches = false
        }

        let assetURL = URL(fileURLWithPath: marker.assetPath)
        let currentAssetSignature = try? mediaPreparer.fileSignature(at: assetURL)
        // The asset was decoded and checked before it was committed. During a
        // provider hand-off AVURLAsset can temporarily expose no format
        // descriptions even though the atomically installed file is intact.
        // The marker signature is the stable content check. Legacy markers
        // without one are treated as needing an async repair.
        let assetSignatureMatches = marker.assetSignature != nil
            && marker.assetSignature == currentAssetSignature
        let ownershipStampMatches = marker.assetSignature != nil
            && assetStore.managedAssetSignature(at: assetURL)
                == marker.assetSignature
        let assetValid = fileManager.fileExists(atPath: assetURL.path)
            && assetSignatureMatches
            && ownershipStampMatches
        let providerAvailable = assetStore.providerSupportsAsset(marker.assetID)
        let providerRunning: Bool
        if usesCanonicalWallpaperStore {
            let extensionRunning = !AerialProviderController.processIdentifiers(
                named: WallpaperPlatformConstants.aerialExtensionProcessName
            ).isEmpty
            let ownerRunning = !AerialProviderController.processIdentifiers(
                named: WallpaperPlatformConstants.wallpaperAgentProcessName
            ).isEmpty
            // WallpaperAgent owns the ExtensionKit provider and can be alive
            // while the extension is still lazy. Treat the owner as a valid
            // warm provider runtime; requiring the extension process itself
            // makes a freshly installed generation fail its readiness window.
            providerRunning = extensionRunning || ownerRunning
        } else {
            providerRunning = false
        }
        let storeData = try? Data(contentsOf: wallpaperStoreURL)
        let storeHash = storeData.map(signature(of:))
        let storeValid = storeData.map { data in
            guard let root = try? wallpaperStoreTransaction
                .propertyListDictionary(from: data) else {
                return false
            }
            return wallpaperStoreTransaction.wallpaperStoreFullySelectsAerial(
                in: root,
                assetID: marker.assetID,
                scope: .lockScreenOnly
            )
            && !wallpaperStoreTransaction.wallpaperStoreContainsAuraInDesktop(
                root,
                assetID: marker.assetID
            )
            && (!usesCanonicalWallpaperStore
                || systemWallpaperURLMatches(assetID: marker.assetID))
        } ?? false

        return LockScreenOnlyGenerationStatus(
            installed: true,
            sourceMatches: sourceMatches,
            assetValid: assetValid,
            providerAvailable: providerAvailable,
            providerRunning: providerRunning,
            wallpaperStoreValid: storeValid,
            // Native macOS 26 Aerial does not use the legacy screen-saver
            // selection. Keep this compatibility field satisfied so native
            // readiness is determined by the Aerial route itself.
            screenSaverSelected: true,
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
    ) async throws -> Bool {
        try await withMutationCoordinator {
            try await withCrossProcessLockAsync {
                try await repairLockScreenOnlyGenerationLocked(
                    videoURL: videoURL,
                    shouldProceed: shouldProceed
                )
            }
        }
    }

    public var isAvailable: Bool {
        guard fileManager.fileExists(atPath: wallpaperStoreURL.path) else {
            return false
        }
        if let marker = loadMarker(),
           marker.completed == true,
           assetStore.providerSupportsAsset(marker.assetID) {
            return true
        }
        if let configuredAssetID {
            return assetStore.providerSupportsAsset(configuredAssetID)
        }
        // After Remove the last Aura-owned slot can still be the user's only
        // locally downloaded Aerial. It is referenced by Apple's default Idle
        // route, so the free-slot filter intentionally excludes it. The slot
        // is nevertheless safe to reuse because the install transaction
        // snapshots the original movie and restores it on Remove.
        return !availableDownloadedAssetIDs().isEmpty
            || reusablePreviouslyManagedAssetID() != nil
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
        mutationCoordinator.withExclusiveNonThrowing {
            guard let stillFrameURL = currentStillFrameURL() else {
                return false
            }
            return WallpaperDesktopSupport.applyToAllDesktops(
                imagePath: stillFrameURL.path
            )
        }
    }

    public func install(videoURL: URL) async throws {
        try await withMutationCoordinator {
            try await withCrossProcessLockAsync {
                _ = try await installLocked(
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
    }

    public func installForDesktopAgent(videoURL: URL) async throws {
        try await withMutationCoordinator {
            try await withCrossProcessLockAsync {
                _ = try await installLocked(
                    videoURL: videoURL,
                    forceRefresh: false,
                    refreshAction: rearmSystem,
                    // AuraWallpaperAgent owns the visible Desktop. Apple's
                    // store only needs the Idle route for loginwindow, so the
                    // user's Desktop/Linked choices remain the source of truth.
                    scope: .lockScreenOnly,
                    lockScreenOnlyRoute: false,
                    restoreUserSystemWallpaperURLAfterInstall: true,
                    rollbackAction: refreshSystem,
                    shouldProceed: { true }
                )
            }
        }
    }

    public func installLockScreenOnly(videoURL: URL) async throws {
        try await withMutationCoordinator {
            try await withCrossProcessLockAsync {
                _ = try await installLocked(
                    videoURL: videoURL,
                    // Lock is an explicit user request. Even if the journal
                    // already looks current, rearm the provider so a stale
                    // WallpaperAgent cannot make this action a false no-op.
                    forceRefresh: true,
                    // A new or repaired lock-only generation must restart
                    // WallpaperAgent while the user is still unlocked. The
                    // provider keeps the selected Aerial asset in memory;
                    // prewarming an already-running owner can therefore
                    // report success while it still serves the old
                    // generation at the next lock. The targeted rearm only
                    // restarts WallpaperAgent, never Dock.
                    refreshAction: rearmSystem,
                    // Keep the user's Desktop route intact while unlocked. The
                    // agent promotes this installation to the shared route from
                    // the early shield callback immediately before loginwindow
                    // resolves the real Lock Screen.
                    scope: .lockScreenOnly,
                    lockScreenOnlyRoute: true,
                    // Replacing an existing lock-only source must not restart
                    // WallpaperAgent: it can replay the stale Desktop
                    // preference captured when the lock session started.
                    avoidProviderRestartOnExistingLockOnlySourceChange: true,
                    // A failed Lock-only attempt must not restart Dock. Doing so
                    // can bring existing Finder and Wallpaper Settings windows
                    // forward even though AuraFlow never asked to open them.
                    rollbackAction: AerialProviderController.prewarmLockScreenProvider,
                    shouldProceed: { true }
                )
            }
        }
    }

    /// Updates the speed of the movie consumed by Apple's Aerial provider.
    /// The provider has its own player process, so this is intentionally an
    /// asset-generation update rather than an AVPlayer rate update.
    public func updatePlaybackSpeed(
        videoURL: URL,
        speed: Double
    ) async throws -> Bool {
        guard !WallpaperMediaKind.forURL(videoURL).isStaticImage else {
            return false
        }
        let normalizedSpeed = normalizedPlaybackSpeed(speed)
        return try await withMutationCoordinator {
            try await withCrossProcessLockAsync {
                guard let marker = loadMarker(),
                      marker.completed == true,
                      URL(fileURLWithPath: marker.videoPath)
                        .standardizedFileURL == videoURL.standardizedFileURL,
                      fileManager.fileExists(atPath: videoURL.path)
                else {
                    return false
                }

                let currentSpeed = marker.playbackSpeed ?? 1.0
                guard abs(currentSpeed - normalizedSpeed) > 0.0001 else {
                    return false
                }

                // Speed changes made while Stop is active must not replace the
                // still frame. Store the requested speed in the journal; the
                // normal Resume repair will build the matching movie.
                if marker.state == "paused" {
                    var updatedMarker = marker
                    updatedMarker.playbackSpeed = normalizedSpeed
                    try saveMarker(updatedMarker)
                    return false
                }

                let lockScreenOnlyRoute = markerUsesDedicatedLockOnlyRuntime(
                    marker
                )
                let isolatedDesktopStore = marker.desktopIncluded == false
                return try await installLocked(
                    videoURL: videoURL,
                    playbackSpeed: normalizedSpeed,
                    scaleMode: WallpaperScaleMode(
                        rawValue: marker.scaleMode ?? ""
                    ) ?? .fill,
                    forceRefresh: true,
                    refreshAction: rearmSystem,
                    scope: isolatedDesktopStore
                        ? .lockScreenOnly
                        : .sharedWallpaper,
                    lockScreenOnlyRoute: lockScreenOnlyRoute,
                    avoidProviderRestartOnExistingLockOnlySourceChange:
                        isolatedDesktopStore,
                    restoreUserSystemWallpaperURLAfterInstall:
                        isolatedDesktopStore && !lockScreenOnlyRoute,
                    rollbackAction: refreshSystem,
                    shouldProceed: { true }
                )
            }
        }
    }

    /// Updates the movie consumed by Apple's Aerial provider so its fixed
    /// aspect-fill player presents the same Fit/Fill/Stretch result as the
    /// AuraFlow Desktop player.
    public func updateScaleMode(
        videoURL: URL,
        mode: WallpaperScaleMode
    ) async throws -> Bool {
        try await withMutationCoordinator {
            try await withCrossProcessLockAsync {
                guard let marker = loadMarker(),
                      marker.completed == true,
                      URL(fileURLWithPath: marker.videoPath)
                        .standardizedFileURL == videoURL.standardizedFileURL,
                      fileManager.fileExists(atPath: videoURL.path)
                else {
                    return false
                }

                let currentMode = WallpaperScaleMode(
                    rawValue: marker.scaleMode ?? ""
                ) ?? .fill
                guard currentMode != mode else { return false }

                // Keep Stop's still-frame asset in place. Resume rebuilds the
                // animated generation using this persisted mode.
                if marker.state == "paused" {
                    var updatedMarker = marker
                    updatedMarker.scaleMode = mode.rawValue
                    try saveMarker(updatedMarker)
                    return false
                }

                return try await updateInstalledMediaLocked(
                    marker: marker,
                    videoURL: videoURL,
                    playbackSpeed: marker.playbackSpeed ?? 1.0,
                    scaleMode: mode
                )
            }
        }
    }

    public func installLegacyLockScreenFallback(
        videoURL: URL,
        restoringLockScreenOnlyVideoURL: URL?
    ) async throws {
        throw LockScreenPlatformError.unsupported(
            "The legacy Lock Screen fallback is owned by the application adapter."
        )
    }

    /// Warms the persistent Aerial media cache without touching the wallpaper
    /// store or provider. Installation still performs its normal validation
    /// and atomic commit checks; this only moves HEVC conversion off the
    /// button action.
    public func prepareLockScreenMedia(videoURL: URL) async throws {
        try await withMutationCoordinator {
            try await withCrossProcessLockAsync {
                guard fileManager.fileExists(atPath: wallpaperStoreURL.path) else {
                    throw AerialLockScreenInstallerError.wallpaperStoreUnavailable
                }
                guard fileManager.fileExists(atPath: videoURL.path) else {
                    throw AerialLockScreenInstallerError.videoMissing(videoURL.path)
                }
                _ = try await mediaPreparer.prepare(from: videoURL)
                lockScreenLifecycleLogger.notice("Prepared Lock Screen media cache")
            }
        }
    }

    private func repairLockScreenOnlyGenerationLocked(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool {
        guard fileManager.fileExists(atPath: wallpaperStoreURL.path) else {
            throw AerialLockScreenInstallerError.wallpaperStoreUnavailable
        }
        guard let marker = loadMarker(),
              marker.completed == true,
              markerUsesDedicatedLockOnlyRuntime(marker)
        else {
            return false
        }
        guard URL(fileURLWithPath: marker.videoPath).standardizedFileURL
                == videoURL.standardizedFileURL,
              let sourceSignature = try? mediaPreparer.fileSignature(at: videoURL),
              marker.videoSignature == sourceSignature,
              shouldProceed()
        else {
            return false
        }

        let currentStoreData = try Data(contentsOf: wallpaperStoreURL)
        guard let currentRoot = try wallpaperStoreTransaction
            .propertyListDictionary(
            from: currentStoreData
        ) else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }
        let currentDesktopRoutes = wallpaperStoreTransaction
            .normalizedDesktopRoutesForComparison(
            try wallpaperStoreTransaction.currentDesktopRouteData(
                in: currentRoot,
                managedAssetID: marker.assetID
            )
        )
        guard !currentDesktopRoutes.isEmpty else {
            // There is no safe current user Desktop to preserve. Never guess
            // from Index.before-auraflow.plist or another old snapshot.
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }

        let updatedStoreData = try wallpaperStoreTransaction
            .aerialWallpaperStoreData(
            from: currentStoreData,
            assetID: marker.assetID,
            scope: .lockScreenOnly
        )
        guard let updatedRoot = try wallpaperStoreTransaction
            .propertyListDictionary(
            from: updatedStoreData
        ) else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }
        let updatedDesktopRoutes = wallpaperStoreTransaction
            .normalizedDesktopRoutesForComparison(
            try wallpaperStoreTransaction.currentDesktopRouteData(
                in: updatedRoot,
                managedAssetID: marker.assetID
            )
        )
        guard updatedDesktopRoutes == currentDesktopRoutes else {
            throw AerialLockScreenInstallerError.wallpaperStoreUpdateFailed
        }

        let assetURL = URL(fileURLWithPath: marker.assetPath)
        let currentAssetSignature = try? mediaPreparer.fileSignature(at: assetURL)
        // A paused still-frame is valid for the provider, but it is not the
        // animated asset that Resume must restore. Manual pause/resume cycles
        // are allowed to repair this deliberate replacement repeatedly; the
        // one-repair guard below remains for an externally replaced asset.
        let assetWasValid = marker.state != "paused"
            && fileManager.fileExists(atPath: assetURL.path)
            && marker.assetSignature != nil
            && marker.assetSignature == currentAssetSignature
        let storeChanged = updatedStoreData != currentStoreData
        let providerWasRunning = usesCanonicalWallpaperStore
            && !AerialProviderController.processIdentifiers(
                named: WallpaperPlatformConstants.aerialExtensionProcessName
            )
                .isEmpty
        var assetChanged = false
        var providerRefreshed = false
        let repairAssetSnapshotURL = !assetWasValid
            ? try rollbackSnapshotURL(for: assetURL)
            : nil
        defer { removeRollbackSnapshot(at: repairAssetSnapshotURL) }
        var expectedRepairedAssetSignature: String?

        do {
            if !assetWasValid {
                // Older journals and configured test/provider slots may not
                // carry a slot generation. Treat them as generation zero so
                // the one-repair limit also applies after an app upgrade.
                let repairGeneration = marker.generation ?? 0
                if marker.lastAssetRepairGeneration == repairGeneration,
                   marker.state != "paused" {
                    throw AerialLockScreenInstallerError
                        .aerialAssetReplacedBySystem
                }
                let preparedVideoURL = try await mediaPreparer.prepare(
                    from: videoURL,
                    playbackSpeed: marker.playbackSpeed ?? 1.0,
                    scaleMode: WallpaperScaleMode(
                        rawValue: marker.scaleMode ?? ""
                    ) ?? .fill
                )
                guard shouldProceed() else {
                    throw AerialLockScreenOperationAbort.sessionChanged
                }
                expectedRepairedAssetSignature = try mediaPreparer.fileSignature(
                    at: preparedVideoURL
                )
                var attemptedMarker = marker
                attemptedMarker.lastAssetRepairGeneration = repairGeneration
                try saveMarker(attemptedMarker)
                // `replaceFile` restores metadata after the atomic swap. Mark
                // the mutation first so a metadata failure still restores the
                // rollback snapshot.
                assetChanged = true
                try replaceFile(
                    at: assetURL,
                    withContentsOf: preparedVideoURL,
                    preservingDestinationMetadata: true,
                    shouldProceed: shouldProceed
                )
                guard let expectedRepairedAssetSignature else {
                    throw AerialLockScreenInstallerError
                        .aerialAssetReplacedBySystem
                }
                try assetStore.markManagedAsset(
                    signature: expectedRepairedAssetSignature,
                    at: assetURL
                )
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
               (assetChanged
                || marker.lastProviderRefreshGeneration != marker.generation) {
                try rearmSystem({ shouldProceed() })
                providerRefreshed = true
                updatedMarker.lastProviderRefreshGeneration = marker.generation
            } else if usesCanonicalWallpaperStore, !providerWasRunning {
                try desktopRestoreSystem({ shouldProceed() })
            }

            let observedStoreData = try Data(contentsOf: wallpaperStoreURL)
            guard let observedRoot = try wallpaperStoreTransaction
                .propertyListDictionary(
                from: observedStoreData
            ),
            wallpaperStoreTransaction.normalizedDesktopRoutesForComparison(
                try wallpaperStoreTransaction.currentDesktopRouteData(
                    in: observedRoot,
                    managedAssetID: marker.assetID
                )
            ) == currentDesktopRoutes,
            wallpaperStoreTransaction.wallpaperStoreFullySelectsAerial(
                in: observedRoot,
                assetID: marker.assetID,
                scope: .lockScreenOnly
            ) else {
                throw AerialLockScreenInstallerError
                    .wallpaperStoreUpdateFailed
            }

            if assetChanged {
                // An interrupted or legacy marker may carry the signature of
                // an older file. Persist the exact asset we just committed so
                // the next health check is a no-op.
                let installedSignature = try mediaPreparer.fileSignature(
                    at: assetURL
                )
                guard let expectedRepairedAssetSignature,
                      installedSignature == expectedRepairedAssetSignature
                else {
                    throw AerialLockScreenInstallerError
                        .aerialAssetReplacedBySystem
                }
                updatedMarker.assetSignature = expectedRepairedAssetSignature
                updatedMarker.lastAssetRepairGeneration =
                    marker.generation ?? 0
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
            return assetChanged || storeChanged || providerRefreshed
        } catch {
            if storeChanged,
               (try? Data(contentsOf: wallpaperStoreURL)) == updatedStoreData {
                try? currentStoreData.write(
                    to: wallpaperStoreURL,
                    options: .atomic
                )
            }
            if assetChanged {
                if let repairAssetSnapshotURL {
                    try? replaceFile(
                        at: assetURL,
                        withContentsOf: repairAssetSnapshotURL,
                        preservingDestinationMetadata: false
                    )
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
    ) async throws -> Bool {
        try await withMutationCoordinator {
            try await withCrossProcessLockAsync {
                let dedicatedLockOnly = isLockScreenOnlyInstallation
                let isolatedDesktopAgent =
                    isDesktopAgentIsolatedInstallation
                let settings = installedMediaSettings(for: videoURL)
                return try await installLocked(
                    videoURL: videoURL,
                    playbackSpeed: settings.speed,
                    scaleMode: settings.scaleMode,
                    forceRefresh: false,
                    refreshAction: rearmSystem,
                    scope: dedicatedLockOnly || isolatedDesktopAgent
                        ? .lockScreenOnly
                        : currentWallpaperStoreScope(),
                    lockScreenOnlyRoute: dedicatedLockOnly,
                    avoidProviderRestartOnExistingLockOnlySourceChange:
                        dedicatedLockOnly || isolatedDesktopAgent,
                    restoreUserSystemWallpaperURLAfterInstall:
                        isolatedDesktopAgent,
                    rollbackAction: refreshSystem,
                    shouldProceed: shouldProceed
                )
            }
        }
    }

    @discardableResult
    public func rearmForNextLock(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool = { true }
    ) async throws -> Bool {
        try await withMutationCoordinator {
            try await withCrossProcessLockAsync {
                // Stop replaces the managed movie with a still-frame asset.
                // A normal unlock rearm must preserve that state; restoring
                // the prepared movie here silently resumes the second Lock
                // Screen even though the persistent pause marker is still set.
                if let marker = loadMarker(),
                   marker.completed == true,
                   marker.state == "paused",
                   URL(fileURLWithPath: marker.videoPath).standardizedFileURL
                        == videoURL.standardizedFileURL {
                    guard shouldProceed() else { return false }
                    if usesCanonicalWallpaperStore {
                        try AerialProviderController.prewarmLockScreenProvider(
                            shouldProceed: shouldProceed
                        )
                    }
                    return false
                }
                let dedicatedLockOnly = isLockScreenOnlyInstallation
                let isolatedDesktopAgent =
                    isDesktopAgentIsolatedInstallation
                let settings = installedMediaSettings(for: videoURL)
                return try await installLocked(
                    videoURL: videoURL,
                    playbackSpeed: settings.speed,
                    scaleMode: settings.scaleMode,
                    forceRefresh: true,
                    refreshAction: rearmSystem,
                    scope: dedicatedLockOnly || isolatedDesktopAgent
                        ? .lockScreenOnly
                        : currentWallpaperStoreScope(),
                    currentInstallationRefreshAction: usesCanonicalWallpaperStore
                        ? AerialProviderController.prewarmLockScreenProvider
                        : rearmSystem,
                    lockScreenOnlyRoute: dedicatedLockOnly,
                    avoidProviderRestartOnExistingLockOnlySourceChange:
                        dedicatedLockOnly || isolatedDesktopAgent,
                    restoreUserSystemWallpaperURLAfterInstall:
                        isolatedDesktopAgent,
                    rollbackAction: refreshSystem,
                    shouldProceed: shouldProceed
                )
            }
        }
    }

    /// Freezes the movie consumed by Apple's native Aerial extension. The
    /// extension owns its AVPlayer in another process, so pausing AuraFlow's
    /// private assertion layer cannot stop the visible Lock Screen. Keep the
    /// normal source and the original asset backup in the journal; Resume and
    /// Remove can therefore restore the animated route without another source
    /// conversion.
    public func pauseLockScreenOnlyPlayback(
        videoURL: URL
    ) async throws -> Bool {
        guard let marker = loadMarker(),
              marker.completed == true,
              fileManager.fileExists(atPath: marker.assetPath)
        else {
            return false
        }

        return try await withMutationCoordinator {
            try await withCrossProcessLockAsync {
                guard let currentMarker = loadMarker(),
                      currentMarker.completed == true,
                      fileManager.fileExists(atPath: currentMarker.assetPath)
                else {
                    return false
                }

                let assetURL = URL(fileURLWithPath: currentMarker.assetPath)
                let pausedAssetSignature = try? mediaPreparer.fileSignature(
                    at: assetURL
                )
                let alreadyFrozen = currentMarker.state == "paused"
                    && currentMarker.assetSignature == pausedAssetSignature
                    && assetStore.managedAssetSignature(at: assetURL)
                        == pausedAssetSignature

                if !alreadyFrozen {
                    try fileManager.createDirectory(
                        at: stateDirectoryURL,
                        withIntermediateDirectories: true
                    )
                    let temporaryURL = stateDirectoryURL.appendingPathComponent(
                        ".paused-\(UUID().uuidString).mov"
                    )
                    defer { try? fileManager.removeItem(at: temporaryURL) }

                    try await mediaPreparer.writeStillFrameVideo(
                        from: videoURL,
                        to: temporaryURL
                    )
                    try replaceFile(
                        at: assetURL,
                        withContentsOf: temporaryURL,
                        preservingDestinationMetadata: true
                    )

                    let frozenSignature = try mediaPreparer.fileSignature(
                        at: assetURL
                    )
                    try? assetStore.markManagedAsset(
                        signature: frozenSignature,
                        at: assetURL
                    )
                    var pausedMarker = currentMarker
                    pausedMarker.assetSignature = frozenSignature
                    pausedMarker.state = "paused"
                    try? journal.saveMarker(pausedMarker)
                }

                // WallpaperAerialsExtension caches the movie. Restart its
                // owner so the new still asset is visible on the next frame.
                try rearmSystem({ true })
                return true
            }
        }
    }

    public func resumeLockScreenOnlyPlayback(
        videoURL: URL
    ) async throws -> Bool {
        if isLockScreenOnlyInstallation {
            // Repair sees the paused asset as non-current and atomically
            // restores the original prepared video from the source URL. Do
            // not gate this on marker.state: a full disk can leave the
            // replacement asset committed while the optional journal update
            // fails.
            return try await repairLockScreenOnlyGeneration(
                videoURL: videoURL,
                shouldProceed: { true }
            )
        }

        return try await withMutationCoordinator {
            try await withCrossProcessLockAsync {
                try await resumeSharedLockScreenPlaybackLocked(
                    videoURL: videoURL
                )
            }
        }
    }

    /// Restores the managed movie for a shared Desktop + native Lock Screen
    /// installation without rewriting the wallpaper store. Stop replaces the
    /// movie because Apple's secure provider owns its player in another
    /// process; Resume must put the prepared animated movie back before the
    /// provider is rearmed.
    private func resumeSharedLockScreenPlaybackLocked(
        videoURL: URL
    ) async throws -> Bool {
        guard let marker = loadMarker(),
              marker.completed == true,
              !markerUsesDedicatedLockOnlyRuntime(marker),
              URL(fileURLWithPath: marker.videoPath).standardizedFileURL
                == videoURL.standardizedFileURL,
              fileManager.fileExists(atPath: videoURL.path),
              fileManager.fileExists(atPath: marker.assetPath)
        else {
            return false
        }

        let preparedVideoURL = try await mediaPreparer.prepare(
            from: videoURL,
            playbackSpeed: marker.playbackSpeed ?? 1.0,
            scaleMode: WallpaperScaleMode(
                rawValue: marker.scaleMode ?? ""
            ) ?? .fill
        )
        try Task.checkCancellation()

        guard let currentMarker = loadMarker(),
              currentMarker.completed == true,
              !markerUsesDedicatedLockOnlyRuntime(currentMarker),
              URL(fileURLWithPath: currentMarker.videoPath)
                .standardizedFileURL == videoURL.standardizedFileURL
        else {
            return false
        }

        let assetURL = URL(fileURLWithPath: currentMarker.assetPath)
        guard fileManager.fileExists(atPath: assetURL.path) else {
            return false
        }
        let preparedSignature = try mediaPreparer.fileSignature(
            at: preparedVideoURL
        )
        let currentSignature = try? mediaPreparer.fileSignature(at: assetURL)
        let alreadyRestored = currentMarker.state != "paused"
            && currentSignature == preparedSignature
            && assetStore.managedAssetSignature(at: assetURL)
                == preparedSignature

        if !alreadyRestored {
            try replaceFile(
                at: assetURL,
                withContentsOf: preparedVideoURL,
                preservingDestinationMetadata: true
            )

            let restoredSignature = try mediaPreparer.fileSignature(at: assetURL)
            try? assetStore.markManagedAsset(
                signature: restoredSignature,
                at: assetURL
            )
            var restoredMarker = currentMarker
            restoredMarker.assetSignature = restoredSignature
            restoredMarker.state = "healthy"
            try? journal.saveMarker(restoredMarker)
        }

        // WallpaperAerialsExtension caches the movie. Restart its owner so
        // the animated asset is visible instead of the paused still frame.
        try rearmSystem({ true })
        return true
    }

    private func installLocked(
        videoURL: URL,
        playbackSpeed: Double = 1.0,
        scaleMode: WallpaperScaleMode = .fill,
        forceRefresh: Bool,
        refreshAction: ConditionalSystemAction,
        scope: AerialWallpaperStoreScope,
        currentInstallationRefreshAction: ConditionalSystemAction? = nil,
        lockScreenOnlyRoute: Bool = false,
        avoidProviderRestartOnExistingLockOnlySourceChange: Bool = false,
        restoreUserSystemWallpaperURLAfterInstall: Bool = false,
        rollbackAction: ConditionalSystemAction,
        shouldProceed: @escaping () -> Bool
    ) async throws -> Bool {
        guard fileManager.fileExists(atPath: wallpaperStoreURL.path) else {
            throw AerialLockScreenInstallerError.wallpaperStoreUnavailable
        }
        guard fileManager.fileExists(atPath: videoURL.path) else {
            throw AerialLockScreenInstallerError.videoMissing(videoURL.path)
        }
        guard let assetID = resolveAssetIDForInstallation() else {
            throw AerialLockScreenInstallerError.aerialAssetUnavailable
        }
        guard assetStore.providerSupportsAsset(assetID) else {
            throw AerialLockScreenInstallerError.aerialAssetUnavailable
        }

        let assetURL = assetStore.assetURL(for: assetID)
        let thumbnailURL = assetStore.thumbnailURL(for: assetID)
        let normalizedSpeed = normalizedPlaybackSpeed(playbackSpeed)
        let systemWallpaperURLBeforeAttempt = currentSystemWallpaperURL()
        let existingMarker = loadMarker()
        let currentVideoSignature = try? mediaPreparer.fileSignature(at: videoURL)
        let replacingExistingLockOnlySource: Bool = {
            guard let existingMarker,
                  existingMarker.completed == true,
                  existingMarker.lockScreenOnly == true
                    || existingMarker.desktopIncluded == false
            else {
                return false
            }
            if let previousSignature = existingMarker.videoSignature,
               let currentVideoSignature {
                return previousSignature != currentVideoSignature
            }
            return URL(fileURLWithPath: existingMarker.videoPath)
                .standardizedFileURL
                != videoURL.standardizedFileURL
        }()

        if installationIsCurrent(
            videoURL: videoURL,
            assetID: assetID,
            scope: scope,
            lockScreenOnlyRoute: lockScreenOnlyRoute,
            playbackSpeed: normalizedSpeed,
            scaleMode: scaleMode
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

        let preparedVideoURL = try await mediaPreparer.prepare(
            from: videoURL,
            playbackSpeed: normalizedSpeed,
            scaleMode: scaleMode
        )
        try Task.checkCancellation()

        guard shouldProceed() else {
            return false
        }

        try fileManager.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true
        )

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
            originalStoreData = try wallpaperStoreTransaction
                .cleanedWallpaperStoreData(from: currentStoreData)
            try originalStoreData.write(
                to: wallpaperStoreBackupURL,
                options: .atomic
            )
        }

        // Re-read after slot selection. System Settings can select a different
        // downloaded Aerial between the initial availability check and this
        // transaction; a new install must never overwrite that user route.
        // The one exception is the slot previously owned by AuraFlow. It is
        // recoverable after Remove when no free local slot exists because the
        // transaction snapshots its original contents first.
        let currentStoreDataForAttempt = try Data(contentsOf: wallpaperStoreURL)
        let reusingPreviouslyManagedSlot = reusablePreviouslyManagedAssetID()
            == assetID
        if configuredAssetID == nil,
           existingMarker?.completed != true,
           !reusingPreviouslyManagedSlot,
           try wallpaperStoreTransaction.referencedAerialAssetIDs(
                in: currentStoreDataForAttempt
           ).contains(assetID) {
            throw AerialLockScreenInstallerError.aerialAssetUnavailable
        }

        if originalAssetExisted,
           fileManager.fileExists(atPath: assetURL.path),
           !fileManager.fileExists(atPath: assetBackupURL.path) {
            try copyItemEfficiently(at: assetURL, to: assetBackupURL)
        }
        if originalThumbnailExisted,
           fileManager.fileExists(atPath: thumbnailURL.path),
           !fileManager.fileExists(atPath: thumbnailBackupURL.path) {
            try fileManager.copyItem(
                at: thumbnailURL,
                to: thumbnailBackupURL
            )
        }

        // For a newly isolated route, the live Index is the sole source of
        // truth for Desktop. When migrating an older shared Start marker, its
        // live Desktop can still be Aura's Aerial route; merge the serialized
        // latest-user journal with the original backup exactly once instead.
        let updateBaseStoreData: Data
        if !scope.includesDesktop {
            if let existingMarker,
               existingMarker.completed == true,
               markerStoreIncludesDesktop(existingMarker) {
                updateBaseStoreData = try wallpaperStoreTransaction
                    .captureLatestUserWallpaperStoreData(
                        from: currentStoreDataForAttempt,
                        fallbackData: originalStoreData,
                        managedAssetID: assetID,
                        propagateGlobalDesktopChanges: true,
                        userSystemWallpaperURL: currentUserSystemWallpaperURL()
                    )
            } else {
                updateBaseStoreData = currentStoreDataForAttempt
            }
        } else {
            updateBaseStoreData = originalStoreData
        }
        if !scope.includesDesktop {
            guard let currentRoot = try wallpaperStoreTransaction
                .propertyListDictionary(from: updateBaseStoreData),
            !wallpaperStoreTransaction.normalizedDesktopRoutesForComparison(
                try wallpaperStoreTransaction.currentDesktopRouteData(
                    in: currentRoot,
                    managedAssetID: assetID
                )
            ).isEmpty else {
                // There is no safe live Desktop to preserve. Do not guess
                // from an older session snapshot.
                throw AerialLockScreenInstallerError.malformedWallpaperStore
            }
        }
        let updatedStoreData = try wallpaperStoreTransaction
            .aerialWallpaperStoreData(
                from: updateBaseStoreData,
                assetID: assetID,
                scope: scope
            )
        let desktopRoutesBeforeAttempt: [String: Data]
        if !scope.includesDesktop,
           let updateBaseRoot = try wallpaperStoreTransaction
               .propertyListDictionary(from: updateBaseStoreData) {
            desktopRoutesBeforeAttempt = wallpaperStoreTransaction
                .normalizedDesktopRoutesForComparison(
                try wallpaperStoreTransaction.currentDesktopRouteData(
                    in: updateBaseRoot,
                    managedAssetID: assetID
                )
            )
        } else {
            desktopRoutesBeforeAttempt = [:]
        }
        let storeBeforeAttempt = currentStoreDataForAttempt
        let assetSnapshotURL = try rollbackSnapshotURL(for: assetURL)
        defer { removeRollbackSnapshot(at: assetSnapshotURL) }
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
            lockScreenOnlyRoute: lockScreenOnlyRoute,
            playbackSpeed: normalizedSpeed,
            scaleMode: scaleMode
        )
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
            try journal.saveMarker(marker)
            markerMutated = true
            guard shouldProceed() else {
                throw AerialLockScreenOperationAbort.sessionChanged
            }
            assetMutated = true
            try replaceFile(
                at: assetURL,
                withContentsOf: preparedVideoURL,
                preservingDestinationMetadata: true,
                shouldProceed: shouldProceed
            )
            guard let assetSignature = marker.assetSignature else {
                throw AerialLockScreenInstallerError
                    .wallpaperStoreUpdateFailed
            }
            try assetStore.markManagedAsset(
                signature: assetSignature,
                at: assetURL
            )
            guard shouldProceed() else {
                throw AerialLockScreenOperationAbort.sessionChanged
            }
            if let currentStillURL = currentStillFrameURL(),
               fileManager.fileExists(atPath: currentStillURL.path) {
                thumbnailMutated = true
                try replaceFile(
                    at: thumbnailURL,
                    withContentsOf: currentStillURL,
                    shouldProceed: shouldProceed
                )
            }
            guard shouldProceed() else {
                throw AerialLockScreenOperationAbort.sessionChanged
            }
            if !scope.includesDesktop,
               try Data(contentsOf: wallpaperStoreURL) != storeBeforeAttempt {
                // System Settings may have committed a newer Desktop while
                // media was being prepared. Abort before touching Index.plist
                // so the next Apply can use that newest Desktop.
                throw AerialLockScreenOperationAbort.storeChanged
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
            if lockScreenOnlyRoute,
               avoidProviderRestartOnExistingLockOnlySourceChange,
               replacingExistingLockOnlySource {
                // The dedicated lock-only route is already registered. A
                // WallpaperAgent restart here can replay an old
                // SystemWallpaperURL and overwrite the user's live Desktop.
                // Keep the owner alive; the updated Idle asset is consumed by
                // the next lock transition. If the provider is absent,
                // prewarm it without replacing the current owner.
                if usesCanonicalWallpaperStore {
                    try AerialProviderController.prewarmLockScreenProvider(
                        shouldProceed: { shouldProceed() }
                    )
                }
                didRefresh = false
            } else if shouldProceed() {
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
                if wallpaperStoreTransaction.wallpaperStoreFullySelectsAerial(
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
                if usesCanonicalWallpaperStore {
                    guard setSystemWallpaperURL(
                        desiredSystemWallpaperURL(assetID: assetID)
                    ) else {
                        throw AerialLockScreenInstallerError
                            .wallpaperStoreUpdateFailed
                    }
                }
                if attempt < 2 {
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            guard configurationConfirmed
                || wallpaperStoreTransaction.wallpaperStoreFullySelectsAerial(
                    assetID: assetID,
                    scope: scope
                ) else {
                throw AerialLockScreenInstallerError
                    .wallpaperStoreUpdateFailed
            }
            if !scope.includesDesktop {
                guard let observedRoot = try wallpaperStoreTransaction
                    .propertyListDictionary(from: Data(contentsOf: wallpaperStoreURL)),
                wallpaperStoreTransaction.normalizedDesktopRoutesForComparison(
                    try wallpaperStoreTransaction.currentDesktopRouteData(
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
            if restoreUserSystemWallpaperURLAfterInstall,
               marker.systemWallpaperURLWasCaptured == true {
                // Registering the native provider requires its Aerial URL,
                // but leaving that URL selected while unlocked makes System
                // Settings identify the user's Desktop as Golden Gate. The
                // lock-session promotion restores Aerial only for the actual
                // secure transition.
                guard applyRestoredSystemWallpaperURL(
                    from: updatedStoreData,
                    marker: marker
                ) else {
                    throw AerialLockScreenInstallerError
                        .wallpaperStoreUpdateFailed
                }
                // The previous shared marker can contain Aura's Aerial URL.
                // Persist the value that was actually restored so later
                // health checks and Remove never compare against stale state.
                completedMarker.originalSystemWallpaperURL =
                    currentSystemWallpaperURL()
            }
            completedMarker.completed = true
            completedMarker.desiredMode = lockScreenOnlyRoute
                ? "lockOnly"
                : scope.includesDesktop
                    ? "shared"
                    : "desktopAgentIsolated"
            completedMarker.lastValidatedStoreHash = signature(
                of: try Data(contentsOf: wallpaperStoreURL)
            )
            completedMarker.fallbackFramePath = currentStillFrameURL()?.path
            completedMarker.state = "healthy"
            try journal.saveMarker(completedMarker)
            startDesktopWallpaperChangeMonitorIfNeeded()
            return didRefresh
        } catch {
            if storeMutated {
                try? storeBeforeAttempt.write(
                    to: wallpaperStoreURL,
                    options: .atomic
                )
            }
            if assetMutated {
                if let assetSnapshotURL {
                    try? replaceFile(
                        at: assetURL,
                        withContentsOf: assetSnapshotURL,
                        preservingDestinationMetadata: false
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
        try withMutationCoordinator {
            try withCrossProcessLock {
                try uninstallLocked()
            }
        }
    }

    /// Non-blocking orchestration entry point for Remove. The compatibility
    /// `uninstall()` method remains for synchronous protocol clients, while
    /// this path acquires the same coordinator and process lock as install.
    public func uninstallAsync() async throws {
        try await withMutationCoordinator {
            try await withCrossProcessLockAsync {
                // Keep the large, carefully-tested transaction in one place.
                // After the suspension above this nonisolated async path runs
                // away from a caller's Main Actor instead of blocking it.
                await Task.yield()
                try uninstallLocked()
            }
        }
    }

    public func uninstallLockScreenOnlyPreservingCurrentDesktop() throws {
        try withMutationCoordinator {
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
    }

    /// Async counterpart used by downgrade/remove workflows. It deliberately
    /// shares the coordinator with install and the synchronous compatibility
    /// method, so no two store transactions can overlap.
    public func uninstallLockScreenOnlyPreservingCurrentDesktopAsync() async throws {
        try await withMutationCoordinator {
            try await withCrossProcessLockAsync {
                await Task.yield()
                guard let marker = loadMarker() else {
                    if fileManager.fileExists(atPath: markerURL.path) {
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
            let plan = try wallpaperStoreTransaction.lockOnlyRemovalStorePlan(
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
            if wallpaperStoreTransaction.lockOnlyRemovalStoreIsValid(
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

        stopDesktopWallpaperChangeMonitor()

        let assetURL = URL(fileURLWithPath: marker.assetPath)
        let thumbnailURL = marker.thumbnailPath.map(URL.init(fileURLWithPath:))
        let storeBeforeAttempt = try? Data(contentsOf: wallpaperStoreURL)
        let assetBeforeAttempt = try? Data(contentsOf: assetURL)
        let thumbnailBeforeAttempt = thumbnailURL.flatMap {
            try? Data(contentsOf: $0)
        }
        let systemWallpaperURLBeforeAttempt = currentSystemWallpaperURL()
        let userSystemWallpaperURL = currentUserSystemWallpaperURL()
        var systemWallpaperURLMutated = false
        let sharedDesktopRemove = markerStoreIncludesDesktop(marker)

        do {
            let originalStoreData = try Data(
                contentsOf: wallpaperStoreBackupURL
            )
            var restorationStoreData = originalStoreData
            if let storeBeforeAttempt {
                if markerStoreIncludesDesktop(marker) {
                    // Shared Start owns Desktop. Its journal can therefore
                    // restore a short-lived user image even when
                    // WallpaperAgent has already flushed Aura's route back
                    // over the live store.
                    if fileManager.fileExists(
                        atPath: latestUserWallpaperStoreURL.path
                    ) || wallpaperStoreTransaction.wallpaperStoreHasUserDesktop(
                        storeBeforeAttempt,
                        managedAssetID: marker.assetID
                    ) || userSystemWallpaperURL != nil {
                        restorationStoreData = try
                            wallpaperStoreTransaction
                                .captureLatestUserWallpaperStoreData(
                                    from: storeBeforeAttempt,
                                    fallbackData: originalStoreData,
                                    managedAssetID: marker.assetID,
                                    propagateGlobalDesktopChanges: true,
                                    userSystemWallpaperURL: userSystemWallpaperURL
                                )
                    }
                } else {
                    // Lock-only never owns Desktop and must preserve each
                    // Space/display route independently. Do not let shared
                    // global propagation enter this path.
                    restorationStoreData = try wallpaperStoreTransaction
                        .captureLatestUserWallpaperStoreData(
                            from: storeBeforeAttempt,
                            fallbackData: originalStoreData,
                            managedAssetID: marker.assetID
                        )
                }
            }
            let restoredDesktopImagePath = restoredDesktopImagePath(
                from: restorationStoreData,
                marker: marker
            )
            if sharedDesktopRemove && restoredDesktopImagePath != nil {
                // A user image can already be present before Start with an
                // opaque Configuration and an empty Files array. A fresh
                // WallpaperAgent cannot resolve that descriptor and falls
                // back to Aerial/Golden Gate. Normalize every image route
                // before the provider is relaunched, including the untouched
                // pre-Start backup when no live wallpaper change occurred.
                restorationStoreData = try wallpaperStoreTransaction
                    .wallpaperStoreDataByNormalizingImageDescriptors(
                        restorationStoreData,
                        preferredSystemWallpaperURL:
                            userSystemWallpaperURL
                                ?? marker.originalSystemWallpaperURL
                    )
            }
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
            if sharedDesktopRemove {
                if restoredDesktopImagePath != nil {
                    // Stop the old WallpaperAgent before committing the image
                    // store. Otherwise that old owner can observe the write
                    // while it still owns Aura's Aerial provider and flush an
                    // empty-Files descriptor back to disk during shutdown.
                    try sharedDesktopRestoreSystem({
                        try restorationStoreData.write(
                            to: wallpaperStoreURL,
                            options: .atomic
                        )
                        if marker.systemWallpaperURLWasCaptured == true {
                            guard applyRestoredSystemWallpaperURL(
                                from: restorationStoreData,
                                marker: marker
                            ) else {
                                throw AerialLockScreenInstallerError
                                    .wallpaperStoreUpdateFailed
                            }
                            systemWallpaperURLMutated = true
                        }
                    }, { true })
                } else {
                    try restorationStoreData.write(
                        to: wallpaperStoreURL,
                        options: .atomic
                    )
                    if marker.systemWallpaperURLWasCaptured == true {
                        guard applyRestoredSystemWallpaperURL(
                            from: restorationStoreData,
                            marker: marker
                        ) else {
                            throw AerialLockScreenInstallerError
                                .wallpaperStoreUpdateFailed
                        }
                        systemWallpaperURLMutated = true
                    }
                    try refreshSystem({ true })
                }
            } else {
                try restorationStoreData.write(
                    to: wallpaperStoreURL,
                    options: .atomic
                )
                if marker.systemWallpaperURLWasCaptured == true {
                    guard applyRestoredSystemWallpaperURL(
                        from: restorationStoreData,
                        marker: marker
                    ) else {
                        throw AerialLockScreenInstallerError
                            .wallpaperStoreUpdateFailed
                    }
                    systemWallpaperURLMutated = true
                }
                // Keep the lock-only stabilization path unchanged: it must
                // preserve independent Space/display Desktop routes while
                // WallpaperAgent is settling the Lock Screen route.
                var restorationVerified = false
                for _ in 0..<3 {
                    try restorationStoreData.write(
                        to: wallpaperStoreURL,
                        options: .atomic
                    )
                    try refreshSystem({ true })
                    Thread.sleep(forTimeInterval: 0.4)
                    if wallpaperStoreTransaction.wallpaperStoreSemanticallyMatches(
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
                // WallpaperAgent can flush the split lock-only route and its
                // old fallback URL while it is terminating. Reassert both
                // values after the final process refresh.
                try restorationStoreData.write(
                    to: wallpaperStoreURL,
                    options: .atomic
                )
                if marker.systemWallpaperURLWasCaptured == true {
                    guard applyRestoredSystemWallpaperURL(
                        from: restorationStoreData,
                        marker: marker
                    ) else {
                        throw AerialLockScreenInstallerError
                            .wallpaperStoreUpdateFailed
                    }
                }
            }
            // The fresh provider starts from the complete normalized journal,
            // including every captured Space/display. NSWorkspace now owns
            // the live temporary -> target transition. Do not write the old
            // journal or restart WallpaperAgent after it succeeds: either
            // action can replace macOS's working descriptor with stale data.
            if let restoredDesktopImagePath {
                let didReactivate = sharedDesktopImageRestoreHook?(
                    restoredDesktopImagePath
                ) ?? WallpaperDesktopSupport
                    .reactivateCurrentScreensAfterSharedRemove(
                        imagePath: restoredDesktopImagePath,
                        appSupportPath: stateDirectoryURL.path,
                        managedAssetID: marker.assetID,
                        wallpaperStoreURL: wallpaperStoreURL
                    )
                if !didReactivate {
                    lockScreenRemovalLogger.error(
                        "The live image transition was not confirmed; committing the captured user Desktop route without restarting Aura"
                    )
                }
                lockScreenRemovalLogger.notice(
                    "Restored the user Desktop image across all captured Spaces; live transition confirmed=\(didReactivate, privacy: .public)"
                )
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
            startDesktopWallpaperChangeMonitorIfNeeded()
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

    private func withCrossProcessLockAsync<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
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

        var acquired = false
        defer {
            if acquired {
                _ = flock(descriptor, LOCK_UN)
            }
            _ = Darwin.close(descriptor)
        }

        while !acquired {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                acquired = true
                break
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw AerialLockScreenInstallerError
                    .wallpaperStoreUnavailable
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        return try await operation()
    }

    private func withMutationCoordinator<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try await mutationCoordinator.acquire()
        defer { mutationCoordinator.release() }
        return try await operation()
    }

    private func withMutationCoordinator<T>(
        _ operation: () throws -> T
    ) throws -> T {
        mutationCoordinator.acquireSynchronously()
        defer { mutationCoordinator.release() }
        return try operation()
    }

    private func resolveAssetID() -> String? {
        if let configuredAssetID {
            return configuredAssetID
        }
        if let marker = loadMarker(), marker.completed == true {
            return marker.assetID
        }
        return availableDownloadedAssetIDs(
            lastAssetID: journal.loadSlotState()?.lastAssetID
        ).first
    }

    private func resolveAssetIDForInstallation() -> String? {
        if let configuredAssetID {
            return configuredAssetID
        }
        if let marker = loadMarker(), marker.completed == true {
            return marker.assetID
        }
        let lastAssetID = journal.loadSlotState()?.lastAssetID
        let assetID: String
        if let availableAssetID = availableDownloadedAssetIDs(
            lastAssetID: lastAssetID
        ).first {
            assetID = availableAssetID
        } else if let reusableAssetID = reusablePreviouslyManagedAssetID() {
            assetID = reusableAssetID
            lockScreenLifecycleLogger.notice(
                "Reusing the last Aura-owned Aerial slot after Remove"
            )
        } else {
            return nil
        }
        var state = journal.loadSlotState()
            ?? AerialSlotState(lastAssetID: nil, generation: 0)
        state.lastAssetID = assetID
        state.generation &+= 1
        do {
            try journal.saveSlotState(state)
        } catch {
            lockScreenLifecycleLogger.error(
                "Failed to persist Aerial slot rotation"
            )
            return nil
        }
        lockScreenLifecycleLogger.notice(
            "Selected downloaded Aerial slot generation=\(state.generation, privacy: .public)"
        )
        return assetID
    }

    private func availableDownloadedAssetIDs(
        lastAssetID: String? = nil
    ) -> [String] {
        let referencedAssetIDs: Set<String>
        if let storeData = try? Data(contentsOf: wallpaperStoreURL),
           let referenced = try? wallpaperStoreTransaction
               .referencedAerialAssetIDs(in: storeData) {
            referencedAssetIDs = referenced
        } else {
            // Selection must fail closed if the live store cannot be parsed;
            // otherwise AuraFlow could reserve an Aerial the user is using.
            return []
        }
        return assetStore.orderedDownloadedProviderAssetIDs(
            lastAssetID: lastAssetID
        ).filter { !referencedAssetIDs.contains($0) }
    }

    /// Returns the last locally downloaded slot that AuraFlow owned. Remove
    /// restores that slot's file and system route but intentionally keeps the
    /// rotation state. This lets a subsequent Lock reuse the slot when
    /// Apple's default configuration references every local Aerial, while
    /// still rejecting an arbitrary user-selected slot.
    private func reusablePreviouslyManagedAssetID() -> String? {
        guard loadMarker()?.completed != true,
              let assetID = journal.loadSlotState()?.lastAssetID,
              assetStore.providerSupportsAsset(assetID),
              fileManager.fileExists(
                  atPath: assetStore.assetURL(for: assetID).path
              )
        else {
            return nil
        }
        return assetID
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

    /// Promotes the dedicated Lock Screen choice immediately before
    /// loginwindow resolves the secure Lock Screen. The original Desktop
    /// route is restored after unlock.
    @discardableResult
    public func activateLockScreenForCurrentSession() throws -> Bool {
        try withMutationCoordinator {
            try withCrossProcessLock {
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
                    wallpaperStoreTransaction.captureLatestUserWallpaperStoreData(
                        from: currentStoreData,
                        fallbackData: originalStoreData,
                        managedAssetID: marker.assetID
                    )
                if markerStoreIncludesDesktop(marker),
                   wallpaperStoreTransaction.wallpaperStoreFullySelectsAerial(
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
                        wallpaperStoreTransaction.latestUserSystemWallpaperURL(
                            from: latestUserStoreData,
                            managedAssetID: marker.assetID
                        ) ?? currentSystemWallpaperURL()
                    try saveMarker(marker)
                }
                if !wallpaperStoreTransaction.wallpaperStoreFullySelectsAerial(
                    assetID: marker.assetID,
                    scope: .sharedWallpaper
                ) {
                    try latestUserStoreData.write(
                        to: lockSessionStoreBackupURL,
                        options: .atomic
                    )
                }
                let activeStoreData = try wallpaperStoreTransaction
                    .aerialWallpaperStoreData(
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
    }

    /// Restores the user's Desktop/Idle wallpaper route after a temporary
    /// shared Aerial promotion used for the secure Lock Screen.
    @discardableResult
    public func restoreDesktopAfterLockScreenSession() throws -> Bool {
        try withMutationCoordinator {
            try withCrossProcessLock {
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
                let hasManagedDesktop = wallpaperStoreTransaction
                    .wallpaperStoreHasManagedDesktop(
                        currentStoreData,
                        managedAssetID: marker.assetID
                    )
                let hasManagedSystemURL = systemWallpaperURLMatches(
                    assetID: marker.assetID
                )
                let promotionIsActive = markerStoreIncludesDesktop(marker)
                    ? hasManagedDesktop || hasManagedSystemURL
                    : hasSessionBackup
                guard promotionIsActive else {
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
                let desktopStoreData = try wallpaperStoreTransaction
                    .captureLatestUserWallpaperStoreData(
                        from: currentStoreData,
                        fallbackData: originalStoreData,
                        managedAssetID: marker.assetID
                    )
                let lockOnlyStoreData = try wallpaperStoreTransaction
                    .aerialWallpaperStoreData(
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
                        wallpaperStoreTransaction.latestUserSystemWallpaperURL(
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
    }

    /// Async counterpart for agent recovery. It uses the same mutation and
    /// cross-process locks as install/remove; the sync implementation remains
    /// available for signal-time compatibility paths.
    @discardableResult
    public func restoreDesktopAfterLockScreenSessionAsync() async throws -> Bool {
        try await withMutationCoordinator {
            try await withCrossProcessLockAsync {
                await Task.yield()
                return try restoreDesktopAfterLockScreenSessionLocked()
            }
        }
    }

    private func restoreDesktopAfterLockScreenSessionLocked() throws -> Bool {
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
        let hasManagedDesktop = wallpaperStoreTransaction
            .wallpaperStoreHasManagedDesktop(
                currentStoreData,
                managedAssetID: marker.assetID
            )
        let hasManagedSystemURL = systemWallpaperURLMatches(
            assetID: marker.assetID
        )
        let promotionIsActive = markerStoreIncludesDesktop(marker)
            ? hasManagedDesktop || hasManagedSystemURL
            : hasSessionBackup
        guard promotionIsActive else {
            if hasSessionBackup {
                try? fileManager.removeItem(at: lockSessionStoreBackupURL)
            }
            return false
        }
        let originalStoreData = try Data(
            contentsOf: wallpaperStoreBackupURL
        )
        let desktopStoreData = try wallpaperStoreTransaction
            .captureLatestUserWallpaperStoreData(
                from: currentStoreData,
                fallbackData: originalStoreData,
                managedAssetID: marker.assetID
            )
        let lockOnlyStoreData = try wallpaperStoreTransaction
            .aerialWallpaperStoreData(
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
                wallpaperStoreTransaction.latestUserSystemWallpaperURL(
                    from: desktopStoreData,
                    managedAssetID: marker.assetID
                ) ?? marker.originalSystemWallpaperURL
            guard setSystemWallpaperURL(restoredSystemWallpaperURL) else {
                throw AerialLockScreenInstallerError.wallpaperStoreUpdateFailed
            }
        }
        if storeChanged, usesCanonicalWallpaperStore {
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

    private func currentSystemWallpaperURL() -> String? {
        guard usesCanonicalWallpaperStore else { return nil }
        return CFPreferencesCopyValue(
            systemWallpaperURLPreferenceKey,
            wallpaperPreferencesApplicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? String
    }

    private func currentUserSystemWallpaperURL() -> String? {
        guard usesCanonicalWallpaperStore else {
            return nil
        }
        // On macOS 26, an ordinary image can be visible through the public
        // Desktop API while SystemWallpaperURL still points to Aura's Aerial
        // asset (or is unset). Prefer the wallpaper currently presented by
        // the active Desktop and use the preference as a fallback.
        let visibleWallpaperURLs = NSScreen.screens.compactMap {
            NSWorkspace.shared.desktopImageURL(for: $0)
        }
        for url in visibleWallpaperURLs {
            if let userURL = validatedUserWallpaperURL(url) {
                return userURL
            }
        }

        guard let currentURL = currentSystemWallpaperURL(),
              let url = URL(string: currentURL) else {
            return nil
        }
        return validatedUserWallpaperURL(url)
    }

    private func validatedUserWallpaperURL(_ url: URL) -> String? {
        guard url.isFileURL else {
            return nil
        }
        let path = url.standardizedFileURL.path
        let managedAssetRoot = assetStore.aerialVideosURL
            .standardizedFileURL.path
        let managedStillFramePath = WallpaperRuntimeStore
            .defaultAppSupportURL()
            .appendingPathComponent("last_frame.png")
            .standardizedFileURL.path
        let loweredPath = path.lowercased()
        guard !loweredPath.hasPrefix(managedAssetRoot.lowercased() + "/"),
              loweredPath != managedStillFramePath.lowercased(),
              !loweredPath.hasPrefix("/system/library/"),
              !loweredPath.hasPrefix("/library/desktop pictures/"),
              fileManager.fileExists(atPath: path) else {
            return nil
        }
        return url.standardizedFileURL.absoluteString
    }

    private func restoredDesktopImagePath(
        from storeData: Data,
        marker: AerialLockScreenMarker
    ) -> String? {
        guard (usesCanonicalWallpaperStore
                || sharedDesktopImageRestoreHook != nil),
              markerStoreIncludesDesktop(marker)
        else {
            return nil
        }
        let userURL = wallpaperStoreTransaction
            .latestUserSystemWallpaperURL(
                      from: storeData,
                      managedAssetID: marker.assetID
                  ) ?? marker.originalSystemWallpaperURL
        guard let userURL,
              let url = URL(string: userURL),
              url.isFileURL,
              WallpaperMediaKind.forURL(url).isStaticImage,
              fileManager.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url.standardizedFileURL.path
    }

    private func startDesktopWallpaperChangeMonitorIfNeeded() {
        guard let marker = loadMarker(),
              marker.completed == true,
              markerStoreIncludesDesktop(marker),
              wallpaperStoreChangeMonitor == nil
        else {
            return
        }

        let monitor = WallpaperStoreChangeMonitor(
            directoryURL: wallpaperStoreURL.deletingLastPathComponent(),
            storeURL: wallpaperStoreURL,
            callback: { [weak self] storeData in
                self?.captureLatestUserDesktopWallpaperIfPresent(
                    storeData: storeData
                )
            }
        )
        if monitor.start() {
            wallpaperStoreChangeMonitor = monitor
        } else {
            lockScreenLifecycleLogger.error(
                "Could not start Desktop wallpaper change monitor"
            )
        }
    }

    private func stopDesktopWallpaperChangeMonitor() {
        wallpaperStoreChangeMonitor?.stop()
        wallpaperStoreChangeMonitor = nil
    }

    private func captureLatestUserDesktopWallpaperIfPresent(
        storeData currentStoreData: Data
    ) {
        guard let marker = loadMarker(),
              marker.completed == true,
              markerStoreIncludesDesktop(marker),
              let originalStoreData = try? Data(
                  contentsOf: wallpaperStoreBackupURL
              )
        else {
            return
        }

        let userSystemWallpaperURL = currentUserSystemWallpaperURL()
        let hasUserDesktop = wallpaperStoreTransaction.wallpaperStoreHasUserDesktop(
            currentStoreData,
            managedAssetID: marker.assetID
        )
        // WallpaperAgent can rewrite Index.plist back to Aura's route before
        // the filesystem callback runs, while SystemWallpaperURL still holds
        // the image just selected by the user. Keep that URL as a valid change
        // signal so the exact image can be journaled instead of being lost.
        guard hasUserDesktop || userSystemWallpaperURL != nil else {
            return
        }

        do {
            _ = try wallpaperStoreTransaction
                .captureLatestUserWallpaperStoreData(
                    from: currentStoreData,
                    fallbackData: originalStoreData,
                    managedAssetID: marker.assetID,
                    propagateGlobalDesktopChanges: true,
                    userSystemWallpaperURL: userSystemWallpaperURL
                )
            lockScreenLifecycleLogger.notice(
                "Captured a user Desktop wallpaper change while shared Aura is running"
            )
        } catch {
            // A transient, partially-written Index.plist must not affect the
            // running wallpaper. The next filesystem event retries capture.
            lockScreenLifecycleLogger.debug(
                "Could not capture a transient user Desktop wallpaper change"
            )
        }
    }

    private func applyRestoredSystemWallpaperURL(
        from storeData: Data,
        marker: AerialLockScreenMarker
    ) -> Bool {
        if let userURL = wallpaperStoreTransaction.latestUserSystemWallpaperURL(
            from: storeData,
            managedAssetID: marker.assetID
        ) {
            return setSystemWallpaperURL(userURL)
        }
        if wallpaperStoreTransaction
            .wallpaperStoreHasExplicitUserDesktopWithoutSystemWallpaperURL(
                storeData,
                managedAssetID: marker.assetID
            ) {
            // Explicit native providers (for example Sequoia) are restored
            // entirely by Index.plist. Clear both preference hosts so an old
            // Aura URL cannot override that provider after a restart.
            return setSystemWallpaperURL(
                nil,
                clearConflictingCurrentHostOverride: true
            )
        }
        return setSystemWallpaperURL(marker.originalSystemWallpaperURL)
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

        let managedRoot = assetStore.aerialVideosURL.standardizedFileURL.path
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
        let assetURL = assetStore.assetURL(for: assetID)
        return assetURL.standardizedFileURL.absoluteString
    }

    // Kept as an internal compatibility seam for callers that used the
    // installer to inspect the resolved user wallpaper URL. The parsing now
    // belongs to WallpaperStoreTransaction.
    func latestUserSystemWallpaperURL(
        from storeData: Data,
        managedAssetID: String
    ) -> String? {
        wallpaperStoreTransaction.latestUserSystemWallpaperURL(
            from: storeData,
            managedAssetID: managedAssetID
        )
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
        lockScreenOnlyRoute: Bool,
        playbackSpeed: Double,
        scaleMode: WallpaperScaleMode
    ) -> Bool {
        guard let marker = loadMarker(),
              marker.completed == true,
              marker.assetID == assetID,
              (marker.lockScreenOnly ?? false) == lockScreenOnlyRoute,
              markerStoreIncludesDesktop(marker) == scope.includesDesktop,
              abs((marker.playbackSpeed ?? 1.0) - playbackSpeed) < 0.0001,
              (WallpaperScaleMode(rawValue: marker.scaleMode ?? "") ?? .fill)
                == scaleMode,
              URL(fileURLWithPath: marker.videoPath).standardizedFileURL
                == videoURL.standardizedFileURL
        else {
            return false
        }

        // A paused marker deliberately points to a valid still replacement;
        // it must still go through the restore path on Resume.
        guard marker.state != "paused" else { return false }

        let assetURL = assetStore.assetURL(for: assetID)
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

        guard let sourceSignature = try? mediaPreparer.fileSignature(at: videoURL),
              let assetSignature = try? mediaPreparer.fileSignature(at: assetURL),
              assetStore.managedAssetSignature(at: assetURL)
                  == marker.assetSignature,
              usesCanonicalWallpaperStore
                ? marker.assetSignature == assetSignature
                : sourceSignature == assetSignature
        else {
            return false
        }
        if let markerSignature = marker.videoSignature,
           markerSignature != sourceSignature {
            return false
        }
        if usesCanonicalWallpaperStore {
            // A dedicated Lock-only marker is not current when the URL that
            // loginwindow consumes is missing or still points at the user's
            // previous wallpaper. Otherwise an old marker could take the
            // refresh-only fast path forever and never repair the real Lock
            // Screen route.
            let systemURLMatches = lockScreenOnlyRoute
                ? systemWallpaperURLMatches(assetID: assetID)
                : systemWallpaperURLMatchesInstalledState(
                    assetID: assetID,
                    marker: marker
                )
            guard systemURLMatches else { return false }
        }
        return wallpaperStoreTransaction.wallpaperStoreFullySelectsAerial(
            assetID: assetID,
            scope: scope
        )
    }

    private func signature(of data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func defaultWallpaperStoreURL() -> URL {
        WallpaperPlatformConstants.wallpaperStoreURL(
            homeURL: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    private func replaceFile(
        at destinationURL: URL,
        withContentsOf sourceURL: URL,
        preservingDestinationMetadata: Bool = false,
        shouldProceed: (() -> Bool)? = nil
    ) throws {
        let replacementMetadata = preservingDestinationMetadata
            ? assetStore.replacementMetadata(at: destinationURL)
            : nil
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
        try copyItemEfficiently(at: sourceURL, to: temporaryURL)
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
        if preservingDestinationMetadata {
            try assetStore.restoreReplacementMetadata(
                replacementMetadata,
                to: destinationURL
            )
        }
    }

    /// APFS clonefile keeps rollback of large Apple Aerial downloads cheap.
    /// Fall back to FileManager when the source and state directory are on
    /// different volumes or the filesystem does not support cloning.
    private func rollbackSnapshotURL(for sourceURL: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }
        try fileManager.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true
        )
        let snapshotURL = stateDirectoryURL.appendingPathComponent(
            ".asset-rollback-\(UUID().uuidString).mov"
        )
        try copyItemEfficiently(at: sourceURL, to: snapshotURL)
        return snapshotURL
    }

    private func copyItemEfficiently(
        at sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let cloned = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                clonefile(sourcePath, destinationPath, 0) == 0
            }
        }
        guard !cloned else { return }
        // A failed clone must not leave a partial destination that prevents
        // FileManager's portable fallback.
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    private func removeRollbackSnapshot(at snapshotURL: URL?) {
        guard let snapshotURL else { return }
        try? fileManager.removeItem(at: snapshotURL)
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
        lockScreenOnlyRoute: Bool,
        playbackSpeed: Double,
        scaleMode: WallpaperScaleMode
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
            videoSignature: try mediaPreparer.fileSignature(at: videoURL),
            assetSignature: try mediaPreparer.fileSignature(at: installedAssetURL),
            playbackSpeed: playbackSpeed,
            scaleMode: scaleMode.rawValue,
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
            generation: journal.loadSlotState()?.generation,
            desiredMode: lockScreenOnlyRoute
                ? "lockOnly"
                : scope.includesDesktop
                    ? "shared"
                    : "desktopAgentIsolated",
            lastValidatedStoreHash: nil,
            lastProviderRefreshGeneration: nil,
            lastAssetRepairGeneration: nil,
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

    private func installedMediaSettings(
        for videoURL: URL
    ) -> (speed: Double, scaleMode: WallpaperScaleMode) {
        guard let marker = loadMarker(),
              marker.completed == true,
              URL(fileURLWithPath: marker.videoPath).standardizedFileURL
                == videoURL.standardizedFileURL
        else {
            return (1.0, .fill)
        }
        return (
            marker.playbackSpeed ?? 1.0,
            WallpaperScaleMode(rawValue: marker.scaleMode ?? "") ?? .fill
        )
    }

    /// Replaces only the movie already owned by the active Aerial generation.
    /// Runtime presentation changes must not rerun the installation transaction:
    /// that transaction also owns the user's wallpaper-store backup and Remove
    /// recovery state. Keeping those bytes untouched makes Scale updates and
    /// subsequent Remove independent and deterministic.
    private func updateInstalledMediaLocked(
        marker: AerialLockScreenMarker,
        videoURL: URL,
        playbackSpeed: Double,
        scaleMode: WallpaperScaleMode
    ) async throws -> Bool {
        let preparedVideoURL = try await mediaPreparer.prepare(
            from: videoURL,
            playbackSpeed: normalizedPlaybackSpeed(playbackSpeed),
            scaleMode: scaleMode
        )
        try Task.checkCancellation()

        guard let currentMarker = loadMarker(),
              currentMarker.completed == true,
              currentMarker.generation == marker.generation,
              currentMarker.assetID == marker.assetID,
              URL(fileURLWithPath: currentMarker.videoPath)
                .standardizedFileURL == videoURL.standardizedFileURL
        else {
            return false
        }

        let assetURL = URL(fileURLWithPath: currentMarker.assetPath)
        guard fileManager.fileExists(atPath: assetURL.path) else {
            return false
        }

        let assetSnapshotURL = try rollbackSnapshotURL(for: assetURL)
        defer { removeRollbackSnapshot(at: assetSnapshotURL) }
        let originalAssetSignature = try? mediaPreparer.fileSignature(
            at: assetURL
        )
        var providerRefreshed = false

        do {
            try replaceFile(
                at: assetURL,
                withContentsOf: preparedVideoURL,
                preservingDestinationMetadata: true
            )
            let installedSignature = try mediaPreparer.fileSignature(
                at: assetURL
            )
            try assetStore.markManagedAsset(
                signature: installedSignature,
                at: assetURL
            )

            var updatedMarker = currentMarker
            updatedMarker.assetSignature = installedSignature
            updatedMarker.playbackSpeed = normalizedPlaybackSpeed(playbackSpeed)
            updatedMarker.scaleMode = scaleMode.rawValue
            updatedMarker.lastAssetRepairGeneration = nil
            updatedMarker.state = "healthy"
            try saveMarker(updatedMarker)

            // The provider caches the movie by asset ID. Restart only its
            // owner; this action does not rewrite the wallpaper store.
            try rearmSystem({ true })
            providerRefreshed = true
            updatedMarker.lastProviderRefreshGeneration =
                updatedMarker.generation
            try saveMarker(updatedMarker)
            lockScreenLifecycleLogger.notice(
                "Updated Lock Screen media without rewriting wallpaper store"
            )
            return true
        } catch {
            if let assetSnapshotURL {
                try? replaceFile(
                    at: assetURL,
                    withContentsOf: assetSnapshotURL,
                    preservingDestinationMetadata: false
                )
                if let originalAssetSignature {
                    try? assetStore.markManagedAsset(
                        signature: originalAssetSignature,
                        at: assetURL
                    )
                }
            }
            try? saveMarker(currentMarker)
            if providerRefreshed {
                try? rearmSystem({ true })
            }
            throw error
        }
    }

    private func markerStoreIncludesDesktop(
        _ marker: AerialLockScreenMarker
    ) -> Bool {
        marker.desktopIncluded ?? (marker.lockScreenOnly != true)
    }

    private func markerUsesDedicatedLockOnlyRuntime(
        _ marker: AerialLockScreenMarker
    ) -> Bool {
        if marker.lockScreenOnly == true {
            return true
        }
        // Journals created before the explicit runtime bit used only
        // `desktopIncluded=false` for Lock-only. New isolated Start journals
        // persist `lockScreenOnly=false`, so they remain Desktop-agent routes.
        return marker.lockScreenOnly == nil
            && marker.desktopIncluded == false
    }

    private func loadMarker() -> AerialLockScreenMarker? {
        journal.loadMarker()
    }

    private func saveMarker(_ marker: AerialLockScreenMarker) throws {
        try journal.saveMarker(marker)
    }

    private func makeRecoveryMarker() -> AerialLockScreenMarker? {
        let assetID =
            configuredAssetID
            ?? resolveAssetID()
            ?? Self.preferredAssetID
        return journal.makeRecoveryMarker(
            assetID: assetID,
            assetURL: assetStore.assetURL(for: assetID),
            thumbnailURL: assetStore.thumbnailURL(for: assetID)
        )
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
        journal.removeIncompleteBackupsIfSafe()
    }

    private func normalizedPlaybackSpeed(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1.0 }
        return max(0.1, min(speed, 4.0))
    }
}
