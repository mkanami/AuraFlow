import Darwin
@preconcurrency import CoreFoundation
import Foundation
import OSLog

private let wallpaperPreferencesApplicationID =
    WallpaperPlatformConstants.wallpaperApplicationID as CFString
private let systemWallpaperURLPreferenceKey =
    WallpaperPlatformConstants.systemWallpaperURLKey as CFString
private let screenSaverPreferencesApplicationID =
    WallpaperPlatformConstants.screenSaverApplicationID as CFString
private let lockScreenRemovalLogger = Logger(
    subsystem: "com.andrijvergeles.auraflow",
    category: "LockScreenRemoval"
)
private let lockScreenLifecycleLogger = Logger(
    subsystem: "com.andrijvergeles.auraflow",
    category: "LockScreenLifecycle"
)

private actor AerialOperationGate {
    private var isHeld = false

    func acquire() async throws {
        while isHeld {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try Task.checkCancellation()
        isHeld = true
    }

    func release() {
        isHeld = false
    }
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
public final class AerialLockScreenInstaller: ModernLockScreenInstalling {
    private typealias ConditionalSystemAction =
        (_ shouldProceed: () -> Bool) throws -> Void

    public static let preferredAssetID =
        "7C643A39-C0B2-4BA0-8BC2-2EAA47CC580E"

    private let fileManager: FileManager
    private let wallpaperStoreURL: URL
    private let stateDirectoryURL: URL
    private let configuredAssetID: String?
    private let refreshSystem: ConditionalSystemAction
    private let rearmSystem: ConditionalSystemAction
    private let desktopRestoreSystem: ConditionalSystemAction
    private let lockSessionHandoffSystem: ConditionalSystemAction
    private let journal: LockScreenJournal
    private let assetStore: AerialAssetStore
    private let mediaPreparer: AerialMediaPreparer
    private let wallpaperStoreTransaction: WallpaperStoreTransaction
    private let operationLock = NSLock()
    private let asyncOperationGate = AerialOperationGate()
    var lockOnlyRemovalCommitHook: (() -> Void)?
    var lockOnlyRepairCommitHook: (() -> Void)?
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
        rearmSystem: (() -> Void)? = nil
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
        } else {
            self.refreshSystem = AerialProviderController
                .refreshWallpaperProcesses
        }
        if let rearmSystem {
            self.rearmSystem = { _ in rearmSystem() }
            self.desktopRestoreSystem = { _ in rearmSystem() }
            self.lockSessionHandoffSystem = { _ in rearmSystem() }
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
            self.lockSessionHandoffSystem = AerialProviderController
                .prewarmLockScreenProvider
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
              assetStore.providerSupportsAsset(marker.assetID)
        else {
            return false
        }
        if marker.lockScreenOnly == true
            || marker.desktopIncluded == false {
            return wallpaperStoreTransaction.wallpaperStoreFullySelectsAerial(
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
              (marker.lockScreenOnly == true
                || marker.desktopIncluded == false)
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
        let assetValid = fileManager.fileExists(atPath: assetURL.path)
            && assetSignatureMatches
        let providerAvailable = assetStore.providerSupportsAsset(marker.assetID)
        let providerRunning = usesCanonicalWallpaperStore
            && !AerialProviderController.processIdentifiers(
                named: WallpaperPlatformConstants.aerialExtensionProcessName
            )
                .isEmpty
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
    ) async throws -> Bool {
        try await withAsyncOperationGate {
            try await withCrossProcessLockAsync {
                try await repairLockScreenOnlyGenerationLocked(
                    videoURL: videoURL,
                    shouldProceed: shouldProceed
                )
            }
        }
    }

    public var isAvailable: Bool {
        fileManager.fileExists(atPath: wallpaperStoreURL.path)
            && !assetStore.supportedProviderAssetIDs().isEmpty
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

    public func install(videoURL: URL) async throws {
        try await withAsyncOperationGate {
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

    public func installLockScreenOnly(videoURL: URL) async throws {
        try await withAsyncOperationGate {
            try await withCrossProcessLockAsync {
                _ = try await installLocked(
                    videoURL: videoURL,
                    forceRefresh: false,
                    refreshAction: rearmSystem,
                    // Keep the user's Desktop route intact while unlocked. The
                    // agent promotes this installation to the shared route from
                    // the early shield callback immediately before loginwindow
                    // resolves the real Lock Screen.
                    scope: .lockScreenOnly,
                    lockScreenOnlyRoute: true,
                    // Replacing an existing lock-only source must not restart
                    // WallpaperAgent: it can replay the stale Desktop preference
                    // captured when the lock session originally started.
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
        try await withAsyncOperationGate {
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
              (marker.lockScreenOnly == true
                || marker.desktopIncluded == false)
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
        let assetBefore = try? Data(contentsOf: assetURL)
        let currentAssetSignature = try? mediaPreparer.fileSignature(at: assetURL)
        let assetWasValid = fileManager.fileExists(atPath: assetURL.path)
            && marker.assetSignature != nil
            && marker.assetSignature == currentAssetSignature
        let storeChanged = updatedStoreData != currentStoreData
        let usesCanonicalStore = usesCanonicalWallpaperStore
        let saverWasSelected = usesCanonicalStore
            ? lockScreenSaverIsSelected()
            : true
        let providerWasRunning = usesCanonicalWallpaperStore
            && !AerialProviderController.processIdentifiers(
                named: WallpaperPlatformConstants.aerialExtensionProcessName
            )
                .isEmpty
        var assetChanged = false
        var selectionChanged = false
        var providerRefreshed = false

        do {
            if !assetWasValid {
                let preparedVideoURL = try await mediaPreparer.prepare(from: videoURL)
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
                updatedMarker.assetSignature = try mediaPreparer.fileSignature(
                    at: assetURL
                )
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
    ) async throws -> Bool {
        try await withAsyncOperationGate {
            try await withCrossProcessLockAsync {
                try await installLocked(
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
    }

    @discardableResult
    public func rearmForNextLock(
        videoURL: URL,
        shouldProceed: @escaping () -> Bool = { true }
    ) async throws -> Bool {
        try await withAsyncOperationGate {
            try await withCrossProcessLockAsync {
                try await installLocked(
                    videoURL: videoURL,
                    forceRefresh: true,
                    refreshAction: rearmSystem,
                    scope: isLockScreenOnlyInstallation
                        ? .lockScreenOnly
                        : currentWallpaperStoreScope(),
                    currentInstallationRefreshAction: usesCanonicalWallpaperStore
                        ? AerialProviderController.prewarmLockScreenProvider
                        : rearmSystem,
                    lockScreenOnlyRoute: isLockScreenOnlyInstallation,
                    rollbackAction: refreshSystem,
                    shouldProceed: shouldProceed
                )
            }
        }
    }

    private func installLocked(
        videoURL: URL,
        forceRefresh: Bool,
        refreshAction: ConditionalSystemAction,
        scope: AerialWallpaperStoreScope,
        currentInstallationRefreshAction: ConditionalSystemAction? = nil,
        lockScreenOnlyRoute: Bool = false,
        avoidProviderRestartOnExistingLockOnlySourceChange: Bool = false,
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

        let preparedVideoURL = try await mediaPreparer.prepare(from: videoURL)
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

        // In lock-only mode, the live Index is the sole source of truth for
        // Desktop. Session snapshots are recovery data for Remove and must
        // never select a wallpaper for a later Apply.
        let currentStoreDataForAttempt = try Data(contentsOf: wallpaperStoreURL)
        let updateBaseStoreData: Data
        if lockScreenOnlyRoute {
            updateBaseStoreData = currentStoreDataForAttempt
        } else {
            updateBaseStoreData = originalStoreData
        }
        if lockScreenOnlyRoute {
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
        if lockScreenOnlyRoute,
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
            if lockScreenOnlyRoute,
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
            if lockScreenOnlyRoute,
               avoidProviderRestartOnExistingLockOnlySourceChange,
               replacingExistingLockOnlySource {
                // The dedicated lock-only route is already registered. A
                // WallpaperAgent restart here can replay an old
                // SystemWallpaperURL and overwrite the user's live Desktop.
                // If the provider is genuinely absent, prewarm it; otherwise
                // leave the owner alive and let the updated Idle asset be
                // consumed by the next lock transition.
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
                if usesCanonicalWallpaperStore, !lockScreenOnlyRoute {
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
            if lockScreenOnlyRoute {
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
            completedMarker.completed = true
            completedMarker.desiredMode = lockScreenOnlyRoute
                ? "lockOnly"
                : "shared"
            completedMarker.lastValidatedStoreHash = signature(
                of: try Data(contentsOf: wallpaperStoreURL)
            )
            completedMarker.fallbackFramePath = currentStillFrameURL()?.path
            completedMarker.state = "healthy"
            try journal.saveMarker(completedMarker)
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
                        wallpaperStoreTransaction.captureLatestUserWallpaperStoreData(
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
                    wallpaperStoreTransaction.latestUserSystemWallpaperURL(
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
                    wallpaperStoreTransaction.latestUserSystemWallpaperURL(
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

    private func withAsyncOperationGate<T>(
        _ operation: () async throws -> T
    ) async throws -> T {
        try await asyncOperationGate.acquire()
        do {
            let result = try await operation()
            await asyncOperationGate.release()
            return result
        } catch {
            await asyncOperationGate.release()
            throw error
        }
    }

    private func resolveAssetID() -> String? {
        if let configuredAssetID {
            return configuredAssetID
        }
        if let marker = loadMarker(), marker.completed == true {
            return marker.assetID
        }
        return assetStore.orderedFreeProviderAssetIDs(
            lastAssetID: journal.loadSlotState()?.lastAssetID
        ).first
            ?? assetStore.supportedProviderAssetIDs().sorted().first
    }

    private func resolveAssetIDForInstallation() -> String? {
        if let configuredAssetID {
            return configuredAssetID
        }
        if let marker = loadMarker(), marker.completed == true {
            return marker.assetID
        }
        guard let assetID = assetStore.orderedFreeProviderAssetIDs(
            lastAssetID: journal.loadSlotState()?.lastAssetID
        ).first else {
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
            "Selected free Aerial slot generation=\(state.generation, privacy: .public)"
        )
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
            let hasManagedDesktop = wallpaperStoreTransaction
                .wallpaperStoreHasManagedDesktop(
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
            videoSignature: try mediaPreparer.fileSignature(at: videoURL),
            assetSignature: try mediaPreparer.fileSignature(at: installedAssetURL),
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
}
