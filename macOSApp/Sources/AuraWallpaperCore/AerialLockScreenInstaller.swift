import Darwin
import Foundation

private let auraFlowAerialProvider = "com.apple.wallpaper.choice.aerials"
private let auraFlowImageProvider = "com.apple.wallpaper.choice.image"
private let auraFlowScreenSaverProvider =
    "com.apple.wallpaper.choice.screen-saver"

private enum AerialLockScreenOperationAbort: Error {
    case sessionChanged
}
private struct AerialLockScreenMarker: Codable {
    var assetID: String
    var assetPath: String
    var thumbnailPath: String?
    var videoPath: String
    var videoSize: UInt64
    var videoModifiedAt: TimeInterval
    var videoSignature: String?
    var originalAssetExisted: Bool?
    var originalThumbnailExisted: Bool?
    var completed: Bool?
}

public enum AerialLockScreenInstallerError: LocalizedError {
    case wallpaperStoreUnavailable
    case aerialAssetUnavailable
    case malformedWallpaperStore
    case wallpaperStoreUpdateFailed
    case aerialProviderRestartFailed
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
    private let operationLock = NSLock()
    private lazy var supportedProviderAssetIDs =
        loadSupportedProviderAssetIDs()

    private var markerURL: URL {
        stateDirectoryURL.appendingPathComponent("installation.json")
    }

    private var wallpaperStoreBackupURL: URL {
        stateDirectoryURL.appendingPathComponent("Index.before-auraflow.plist")
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
        } else {
            self.rearmSystem = Self.refreshLockScreenProvider
        }
    }

    public var isInstalled: Bool {
        fileManager.fileExists(atPath: markerURL.path)
    }

    public var isAvailable: Bool {
        guard fileManager.fileExists(atPath: wallpaperStoreURL.path),
              let assetID = resolveAssetID()
        else {
            return false
        }
        return providerSupportsAsset(assetID)
    }

    public func install(videoURL: URL) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try withCrossProcessLock {
            _ = try installLocked(
                videoURL: videoURL,
                forceRefresh: false,
                refreshAction: rearmSystem,
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
                rollbackAction: refreshSystem,
                shouldProceed: shouldProceed
            )
        }
    }

    private func installLocked(
        videoURL: URL,
        forceRefresh: Bool,
        refreshAction: ConditionalSystemAction,
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

        if installationIsCurrent(videoURL: videoURL, assetID: assetID) {
            guard forceRefresh, shouldProceed() else {
                return false
            }
            // Unlock only needs a fresh Apple player process. Keeping the
            // already-verified asset and store untouched makes the rearm fast
            // and greatly narrows the next-lock race window.
            do {
                try refreshAction({ shouldProceed() })
            } catch is AerialLockScreenOperationAbort {
                return false
            }
            return true
        }

        guard shouldProceed() else {
            return false
        }

        try fileManager.createDirectory(
            at: stateDirectoryURL,
            withIntermediateDirectories: true
        )

        let existingMarker = loadMarker()
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
            assetID: assetID
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
            originalAssetExisted: originalAssetExisted,
            originalThumbnailExisted: originalThumbnailExisted
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
                withContentsOf: videoURL,
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
            let didRefresh: Bool
            if shouldProceed() {
                try refreshAction({ shouldProceed() })
                didRefresh = true
            } else {
                didRefresh = false
            }
            guard wallpaperStoreFullySelectsAerial(assetID: assetID) else {
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

    /// The desktop restore is performed after the Aerial journal is removed.
    /// Restart the system wallpaper owner once more so a provider that was
    /// already holding an old Aerial frame cannot repaint it over the
    /// restored user image.
    public func refreshAfterWallpaperRestore() {
        // The legacy uninstall path briefly restores the old Store before
        // Remove writes the user's image back. WallpaperAgent can therefore
        // relaunch Aerial after the first kill. Retry only that provider after
        // the Store transaction has settled; never restart Dock/WallpaperAgent
        // here, because that creates the grey → Golden Gate repaint race.
        Self.terminateAerialProvider()
        DispatchQueue.global(qos: .utility).async {
            for delay in [0.75, 1.5, 3.0] {
                Thread.sleep(forTimeInterval: delay)
                Self.terminateAerialProvider()
            }
        }
    }

    private static func terminateAerialProvider() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-x", "WallpaperAerialsExtension"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // The provider may already be gone.
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

        do {
            let originalStoreData = try Data(
                contentsOf: wallpaperStoreBackupURL
            )
            let currentStoreData = storeBeforeAttempt ?? originalStoreData
            let restoredStoreData = try restoreIdleSlots(
                in: currentStoreData,
                from: originalStoreData,
                assetID: marker.assetID
            )
            try restoredStoreData.write(
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
            var restorationVerified = false
            for _ in 0..<3 {
                try restoredStoreData.write(
                    to: wallpaperStoreURL,
                    options: .atomic
                )
                try refreshSystem({ true })
                Thread.sleep(forTimeInterval: 0.4)
                if wallpaperStoreSemanticallyMatches(
                    expectedData: restoredStoreData
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
            try? refreshSystem({ true })
            throw error
        }
    }

    /// Restore only Lock Screen slots owned by AuraFlow. Desktop entries are
    /// read from the current store so a wallpaper changed while AuraFlow was
    /// active is not overwritten by the old installation snapshot.
    private func restoreIdleSlots(
        in currentData: Data,
        from originalData: Data,
        assetID: String
    ) throws -> Data {
        guard var currentRoot = try propertyListDictionary(from: currentData),
              let originalRoot = try propertyListDictionary(from: originalData)
        else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }

        if let currentAll = currentRoot["AllSpacesAndDisplays"] as? [String: Any],
           let originalAll = originalRoot["AllSpacesAndDisplays"] as? [String: Any] {
            currentRoot["AllSpacesAndDisplays"] = restoreIdleSlot(
                in: currentAll,
                from: originalAll,
                assetID: assetID
            )
        }
        if let currentDefault = currentRoot["SystemDefault"] as? [String: Any],
           let originalDefault = originalRoot["SystemDefault"] as? [String: Any] {
            currentRoot["SystemDefault"] = restoreIdleSlot(
                in: currentDefault,
                from: originalDefault,
                assetID: assetID
            )
        }
        if let currentDisplays = currentRoot["Displays"] as? [String: Any],
           let originalDisplays = originalRoot["Displays"] as? [String: Any] {
            currentRoot["Displays"] = restoreIdleSlots(
                inDisplays: currentDisplays,
                from: originalDisplays,
                assetID: assetID
            )
        }
        if let currentSpaces = currentRoot["Spaces"] as? [String: Any],
           let originalSpaces = originalRoot["Spaces"] as? [String: Any] {
            currentRoot["Spaces"] = restoreIdleSlots(
                inSpaces: currentSpaces,
                from: originalSpaces,
                assetID: assetID
            )
        }

        return try PropertyListSerialization.data(
            fromPropertyList: currentRoot,
            format: .binary,
            options: 0
        )
    }

    private func restoreIdleSlots(
        inDisplays currentDisplays: [String: Any],
        from originalDisplays: [String: Any],
        assetID: String
    ) -> [String: Any] {
        currentDisplays.reduce(into: [String: Any]()) { result, entry in
            let (displayID, currentValue) = entry
            guard let currentContainer = currentValue as? [String: Any],
                  let originalContainer = originalDisplays[displayID]
                    as? [String: Any]
            else {
                result[displayID] = currentValue
                return
            }
            result[displayID] = restoreIdleSlot(
                in: currentContainer,
                from: originalContainer,
                assetID: assetID
            )
        }
    }

    private func restoreIdleSlots(
        inSpaces currentSpaces: [String: Any],
        from originalSpaces: [String: Any],
        assetID: String
    ) -> [String: Any] {
        currentSpaces.reduce(into: [String: Any]()) { result, entry in
            let (spaceID, currentValue) = entry
            guard var currentSpace = currentValue as? [String: Any],
                  let originalSpace = originalSpaces[spaceID] as? [String: Any]
            else {
                result[spaceID] = currentValue
                return
            }
            if let currentDefault = currentSpace["Default"] as? [String: Any],
               let originalDefault = originalSpace["Default"] as? [String: Any] {
                currentSpace["Default"] = restoreIdleSlot(
                    in: currentDefault,
                    from: originalDefault,
                    assetID: assetID
                )
            }
            if let currentDisplays = currentSpace["Displays"] as? [String: Any],
               let originalDisplays = originalSpace["Displays"] as? [String: Any] {
                currentSpace["Displays"] = restoreIdleSlots(
                    inDisplays: currentDisplays,
                    from: originalDisplays,
                    assetID: assetID
                )
            }
            result[spaceID] = currentSpace
        }
    }

    private func restoreIdleSlot(
        in currentContainer: [String: Any],
        from originalContainer: [String: Any],
        assetID: String
    ) -> [String: Any] {
        guard let currentIdle = currentContainer["Idle"] as? [String: Any],
              modeFullySelectsAerial(currentIdle, assetID: assetID),
              let originalIdle = originalContainer["Idle"]
        else {
            return currentContainer
        }
        var result = currentContainer
        result["Idle"] = originalIdle
        if let currentDesktop = currentContainer["Desktop"],
           let originalDesktop = originalContainer["Desktop"],
           wallpaperStoreValuesSemanticallyMatch(
                currentDesktop,
                originalDesktop
           ) {
            if let originalType = originalContainer["Type"] {
                result["Type"] = originalType
            } else {
                result.removeValue(forKey: "Type")
            }
        }
        return result
    }

    private func wallpaperStoreValuesSemanticallyMatch(
        _ lhs: Any,
        _ rhs: Any
    ) -> Bool {
        guard let lhsData = try? PropertyListSerialization.data(
                fromPropertyList: wallpaperStoreComparableValue(lhs),
                format: .xml,
                options: 0
              ),
              let rhsData = try? PropertyListSerialization.data(
                fromPropertyList: wallpaperStoreComparableValue(rhs),
                format: .xml,
                options: 0
              )
        else {
            return false
        }
        return lhsData == rhsData
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
            ?? supportedProviderAssetIDs.sorted().first
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
        if var allSpaces = root["AllSpacesAndDisplays"] as? [String: Any] {
            if let desktop = allSpaces["Desktop"] as? [String: Any],
               modeReferencesAuraFlow(desktop) {
                allSpaces["Desktop"] = fallbackDesktop
            }
            if let desktop = allSpaces["Desktop"] as? [String: Any] {
                allSpaces["Desktop"] = normalizeImageModeFiles(desktop)
            }
            if let idle = allSpaces["Idle"] as? [String: Any],
               modeReferencesAuraFlow(idle) {
                allSpaces["Idle"] = fallbackIdle
            }
            root["AllSpacesAndDisplays"] = allSpaces
        }
        return try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
    }

    private func aerialWallpaperStoreData(
        from data: Data,
        assetID: String
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
            if result["Desktop"] != nil || result["Idle"] != nil {
                result["Idle"] = aerialMode
                result["Type"] = "individual"
            }
            return result
        }
        // On current macOS versions the active Lock Screen is resolved from
        // AllSpacesAndDisplays.Idle. Keep its Desktop slot untouched so a
        // user wallpaper is not replaced, while selecting AuraFlow only for
        // the secure Lock Screen slot.
        if var allSpaces = root["AllSpacesAndDisplays"] as? [String: Any],
           allSpaces["Desktop"] != nil || allSpaces["Idle"] != nil {
            allSpaces["Idle"] = aerialMode
            allSpaces["Type"] = "individual"
            root["AllSpacesAndDisplays"] = allSpaces
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

    private func installationIsCurrent(
        videoURL: URL,
        assetID: String
    ) -> Bool {
        guard let marker = loadMarker(),
              marker.completed == true,
              marker.assetID == assetID,
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
              sourceSignature == assetSignature
        else {
            return false
        }
        if let markerSignature = marker.videoSignature,
           markerSignature != sourceSignature {
            return false
        }
        return wallpaperStoreFullySelectsAerial(assetID: assetID)
    }

    private func wallpaperStoreFullySelectsAerial(
        assetID: String
    ) -> Bool {
        guard let data = try? Data(contentsOf: wallpaperStoreURL),
              let root = try? propertyListDictionary(from: data)
        else {
            return false
        }

        var containers: [[String: Any]] = []
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
            guard let mode = container["Idle"] as? [String: Any] else {
                continue
            }
            inspectedModes += 1
            guard modeFullySelectsAerial(mode, assetID: assetID) else {
                return false
            }
        }

        if let allSpaces = root["AllSpacesAndDisplays"] as? [String: Any],
           let idle = allSpaces["Idle"] as? [String: Any] {
            inspectedModes += 1
            guard modeFullySelectsAerial(idle, assetID: assetID) else {
                return false
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
        originalAssetExisted: Bool,
        originalThumbnailExisted: Bool
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
            originalAssetExisted: originalAssetExisted,
            originalThumbnailExisted: originalThumbnailExisted,
            completed: false
        )
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
            originalAssetExisted: fileManager.fileExists(
                atPath: assetBackupURL.path
            ),
            originalThumbnailExisted: fileManager.fileExists(
                atPath: thumbnailBackupURL.path
            ),
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

    private static func waitForFreshProvider(
        excluding previousPIDs: Set<Int32>
    ) -> Bool {
        for _ in 0..<40 {
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

    private static func processIdentifiers(named name: String) -> Set<Int32> {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
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
            process.waitUntilExit()
        } catch {
            return
        }
    }
}
