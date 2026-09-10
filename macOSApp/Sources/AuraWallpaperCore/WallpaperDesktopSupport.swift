import AppKit
import CoreFoundation
import Foundation

internal struct DesktopImageTransitionOperations {
    var applyToCurrentScreens: (URL) -> Bool
    var currentScreensMatch: (URL) -> Bool
    var readWallpaperStore: () -> Data?
    var pause: (TimeInterval) -> Void
    var setSystemWallpaperURL: ((URL) -> Bool)? = nil
    var applyToAllDesktopSpaces: ((URL) -> Bool)? = nil
}

public enum WallpaperDesktopSupport {
    private static let backupNames = ["wallpaper_backup.json", "wallpaper_backup_original.json"]
    private static let lockScreenBackupName = "lock_screen_desktop_backup.json"

    @discardableResult
    public static func captureCurrentDesktopWallpaperBackup(
        appSupportPath: String
    ) -> Bool {
        let managedPath = managedWallpaperPath(appSupportPath: appSupportPath)
        let workspace = NSWorkspace.shared
        var wallpapers: [String: String] = [:]

        for screen in NSScreen.screens {
            guard let url = workspace.desktopImageURL(for: screen) else { continue }
            let standardized = url.standardizedFileURL.path
            guard !standardized.isEmpty, standardized != managedPath else { continue }
            wallpapers[screenIdentifier(screen)] = standardized
        }

        guard !wallpapers.isEmpty else { return false }
        return saveWallpaperBackup(
            appSupportPath: appSupportPath,
            wallpapers: wallpapers
        )
    }

    /// Captures the Desktop image that must remain visible while the modern
    /// shared Aerial route is active for Lock Screen only. This backup is
    /// separate from the Start/Remove backup and is refreshed per install.
    @discardableResult
    public static func captureLockScreenDesktopWallpaperBackup(
        appSupportPath: String
    ) -> Bool {
        let managedPath = managedWallpaperPath(appSupportPath: appSupportPath)
        let aerialPath = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/aerials",
                isDirectory: true
            )
            .standardizedFileURL.path
        var wallpapers: [String: String] = [:]

        for screen in NSScreen.screens {
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
                continue
            }
            let standardized = url.standardizedFileURL.path
            guard !standardized.isEmpty,
                  standardized != managedPath,
                  !standardized.hasPrefix(aerialPath + "/")
            else {
                continue
            }
            wallpapers[screenIdentifier(screen)] = standardized
        }

        guard !wallpapers.isEmpty else { return false }
        return saveWallpaperBackup(
            appSupportPath: appSupportPath,
            wallpapers: wallpapers,
            fileNames: [lockScreenBackupName],
            overwriteExisting: true
        )
    }

    /// Returns one captured Desktop image for the lock-only runtime cover.
    /// The cover is only used while the user is unlocked; it hides the
    /// temporary shared Aerial Desktop choice that keeps repeated Lock Screen
    /// sessions reliable.
    public static func desktopBackupImageURL(
        appSupportPath: String
    ) -> URL? {
        for fileNames in [[lockScreenBackupName], backupNames] {
            guard let wallpapers = loadWallpaperBackup(
                appSupportPath: appSupportPath,
                fileNames: fileNames
            ) else {
                continue
            }
            let imageURLs = wallpapers.values.map { value in
                URL(fileURLWithPath: value).standardizedFileURL
            }
            if let imageURL = imageURLs.first(where: { url in
                FileManager.default.fileExists(atPath: url.path)
            }) {
                return imageURL
            }
        }
        return nil
    }

    @discardableResult
    public static func applyToAllDesktops(imagePath: String, retryCount: Int = 3) -> Bool {
        let standardizedPath = URL(fileURLWithPath: imagePath).standardized.path
        guard FileManager.default.fileExists(atPath: standardizedPath) else { return false }
        let escapedPath = escapeForAppleScript(standardizedPath)
        let scripts = [
            """
            tell application "System Events"
              repeat with d in desktops
                set picture of d to POSIX file "\(escapedPath)"
              end repeat
            end tell
            """,
            """
            tell application "System Events" to set picture of every desktop to POSIX file "\(escapedPath)"
            """,
            """
            tell application "Finder" to set desktop picture to POSIX file "\(escapedPath)"
            """
        ]

        let attempts = max(1, retryCount)
        for _ in 0..<attempts {
            var appliedAny = false
            for screen in NSScreen.screens {
                if (try? NSWorkspace.shared.setDesktopImageURL(
                    URL(fileURLWithPath: standardizedPath),
                    for: screen,
                    options: [:]
                )) != nil {
                    appliedAny = true
                }
            }
            // The public API is sufficient for every currently visible
            // display. Avoid sending synchronous Apple Events when that fast
            // path worked: WallpaperAgent can stop answering System Events
            // while its provider is being replaced, which previously left
            // Remove spinning forever.
            if appliedAny && currentScreensMatch(path: standardizedPath) {
                return true
            }
            for script in scripts {
                _ = runAppleScript(script)
            }
            if appliedAny && currentScreensMatch(path: standardizedPath) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    @discardableResult
    public static func applyToCurrentScreens(imagePath: String) -> Bool {
        let url = URL(fileURLWithPath: imagePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }

        let workspace = NSWorkspace.shared
        var appliedAny = false
        for screen in NSScreen.screens {
            if (try? workspace.setDesktopImageURL(
                url,
                for: screen,
                options: [:]
            )) != nil {
                appliedAny = true
            }
        }
        return appliedAny
    }

    /// Forces a real image-provider transition after the shared Aerial route
    /// has been removed. Writing the target URL to Index.plist before calling
    /// NSWorkspace can make the public setter a no-op, leaving WallpaperAgent
    /// on its previously exported Aerial fallback. A temporary URL guarantees
    /// that the final target is a distinct, system-owned transition.
    @discardableResult
    internal static func reactivateCurrentScreensAfterSharedRemove(
        imagePath: String,
        appSupportPath: String,
        managedAssetID: String,
        wallpaperStoreURL: URL,
        operations suppliedOperations: DesktopImageTransitionOperations? = nil
    ) -> Bool {
        let fileManager = FileManager.default
        let targetURL = URL(fileURLWithPath: imagePath).standardizedFileURL
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return false
        }

        let transitionDirectoryURL = URL(
            fileURLWithPath: appSupportPath,
            isDirectory: true
        ).appendingPathComponent(
            ".desktop-restore-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: transitionDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            return false
        }
        var temporaryTransitionAttempted = false
        var finalTransitionConfirmed = false
        defer {
            // Once macOS may have accepted the temporary route, its backing
            // file has to survive every failed attempt. The install journal
            // and the temporary image then remain available for recovery.
            if !temporaryTransitionAttempted || finalTransitionConfirmed {
                try? fileManager.removeItem(at: transitionDirectoryURL)
            }
        }

        let fileExtension = targetURL.pathExtension
        let temporaryName = fileExtension.isEmpty
            ? "wallpaper-transition"
            : "wallpaper-transition.\(fileExtension)"
        let temporaryURL = transitionDirectoryURL
            .appendingPathComponent(temporaryName)
        do {
            // A hard link has a different path but the same inode. Wallpaper
            // Agent can deduplicate that as the already-selected image and
            // skip the provider transition. A real copy gives it a distinct
            // file identity as well as a distinct URL.
            try fileManager.copyItem(at: targetURL, to: temporaryURL)
        } catch {
            return false
        }

        let operations = suppliedOperations ?? productionTransitionOperations(
            wallpaperStoreURL: wallpaperStoreURL
        )
        let restorationURL: URL
        if suppliedOperations == nil {
            guard let durableURL = durableRestorationURL(
                for: targetURL,
                appSupportPath: appSupportPath
            ) else {
                return false
            }
            restorationURL = durableURL
            guard operations.setSystemWallpaperURL?(restorationURL) ?? true
            else {
                return false
            }
        } else {
            restorationURL = targetURL
        }
        guard let storeBeforeTemporary = operations.readWallpaperStore()
        else {
            return false
        }
        temporaryTransitionAttempted = true
        let applyForTransition = operations.applyToAllDesktopSpaces
            ?? operations.applyToCurrentScreens
        guard applyForTransition(temporaryURL),
              waitForDesktopImageTransition(
                  to: temporaryURL,
                  after: storeBeforeTemporary,
                  managedAssetID: managedAssetID,
                  operations: operations
              ),
              let storeBeforeTarget = operations.readWallpaperStore(),
              applyForTransition(restorationURL),
              waitForDesktopImageTransition(
                  to: restorationURL,
                  after: storeBeforeTarget,
                  managedAssetID: managedAssetID,
                  operations: operations
              )
        else {
            return false
        }
        finalTransitionConfirmed = true
        return true
    }

    private static func productionTransitionOperations(
        wallpaperStoreURL: URL
    ) -> DesktopImageTransitionOperations {
        DesktopImageTransitionOperations(
            applyToCurrentScreens: { url in
                let screens = NSScreen.screens
                guard !screens.isEmpty else { return false }
                var appliedToEveryScreen = true
                for screen in screens {
                    do {
                        try NSWorkspace.shared.setDesktopImageURL(
                            url,
                            for: screen,
                            options: [:]
                        )
                    } catch {
                        appliedToEveryScreen = false
                    }
                }
                return appliedToEveryScreen
            },
            currentScreensMatch: { url in
                currentScreensMatch(path: url.path)
            },
            readWallpaperStore: {
                try? Data(contentsOf: wallpaperStoreURL)
            },
            pause: { interval in
                Thread.sleep(forTimeInterval: interval)
            },
            setSystemWallpaperURL: { url in
                setTransitionSystemWallpaperURL(url)
            },
            applyToAllDesktopSpaces: { url in
                applyToAllDesktopSpaces(url)
            }
        )
    }

    /// Applies a transition to every Space on every display. The public
    /// NSWorkspace setter normally targets only the active Space; the
    /// all-Spaces option is required here because the other Spaces can keep
    /// Aerial/Golden Gate even though the active Desktop reports the restored
    /// image.
    private static func applyToAllDesktopSpaces(_ url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
            return false
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }
        let allSpacesKey = NSWorkspace.DesktopImageOptionKey(
            rawValue: "NSWorkspaceDesktopImageAllSpacesKey"
        )
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            allSpacesKey: true,
        ]
        var appliedToEveryScreen = true
        for screen in screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(
                    standardizedURL,
                    for: screen,
                    options: options
                )
            } catch {
                appliedToEveryScreen = false
            }
        }
        return appliedToEveryScreen
    }

    private static func durableRestorationURL(
        for targetURL: URL,
        appSupportPath: String
    ) -> URL? {
        let fileManager = FileManager.default
        let auraFlowDirectoryURL = URL(
            fileURLWithPath: appSupportPath,
            isDirectory: true
        ).deletingLastPathComponent().standardizedFileURL
        let targetPath = targetURL.standardizedFileURL.path
        let rootPath = auraFlowDirectoryURL.path
        if targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") {
            // Catalog/imported wallpapers already live in an application-owned
            // directory that WallpaperAgent can read without a Downloads or
            // Desktop security scope.
            return targetURL
        }

        let restoredDirectoryURL = auraFlowDirectoryURL
            .appendingPathComponent("Restored Wallpapers", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: restoredDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        let resourceValues = try? targetURL.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        let fingerprint = [
            targetPath,
            String(resourceValues?.fileSize ?? 0),
            String(
                resourceValues?.contentModificationDate?.timeIntervalSince1970
                    ?? 0
            ),
        ].joined(separator: "|")
        let token = stableRestoreToken(fingerprint)
        let fileExtension = targetURL.pathExtension.lowercased()
        let fileName = fileExtension.isEmpty
            ? "desktop-\(token)"
            : "desktop-\(token).\(fileExtension)"
        let destinationURL = restoredDirectoryURL
            .appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        let accessedSecurityScopedResource =
            targetURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScopedResource {
                targetURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            try fileManager.copyItem(at: targetURL, to: destinationURL)
            return destinationURL
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            return nil
        }
    }

    private static func stableRestoreToken(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func setTransitionSystemWallpaperURL(_ url: URL) -> Bool {
        let applicationID = WallpaperPlatformConstants.wallpaperApplicationID
            as CFString
        let preferenceKey = WallpaperPlatformConstants.systemWallpaperURLKey
            as CFString
        let value = url.standardizedFileURL.absoluteString as CFPropertyList
        CFPreferencesSetValue(
            preferenceKey,
            value,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        CFPreferencesSetValue(
            preferenceKey,
            value,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        return CFPreferencesSynchronize(
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) && CFPreferencesSynchronize(
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
    }

    private static func waitForDesktopImageTransition(
        to expectedURL: URL,
        after previousStoreData: Data,
        managedAssetID: String,
        operations: DesktopImageTransitionOperations
    ) -> Bool {
        // WallpaperAgent exports an image asynchronously. The store and
        // NSWorkspace can report the target before that export has settled;
        // a short three-sample check lets the agent later fall back to Aerial
        // with NSCocoaErrorDomain 4865. Require a full quiet second and allow
        // slow HEIC/JPEG exports enough time to finish.
        let timeout: TimeInterval = 8.0
        let pollInterval: TimeInterval = 0.1
        let deadline = Date().addingTimeInterval(timeout)
        var stableSamples = 0
        let previousLastSet = latestDesktopImageTimestamp(
            in: previousStoreData,
            matching: expectedURL
        )

        repeat {
            if let storeData = operations.readWallpaperStore(),
               storeData != previousStoreData,
               let currentLastSet = latestDesktopImageTimestamp(
                   in: storeData,
                   matching: expectedURL
               ),
               previousLastSet.map({ currentLastSet > $0 }) ?? true,
               !wallpaperStoreContainsManagedDesktop(
                   storeData,
                   managedAssetID: managedAssetID
               ),
               operations.currentScreensMatch(expectedURL) {
                stableSamples += 1
                if stableSamples >= 10 {
                    return true
                }
            } else {
                stableSamples = 0
            }
            operations.pause(pollInterval)
        } while Date() < deadline

        return false
    }

    private static func latestDesktopImageTimestamp(
        in data: Data,
        matching expectedURL: URL
    ) -> Date? {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else {
            return nil
        }
        let expectedPath = expectedURL.standardizedFileURL.path
        var latestTimestamp: Date?
        _ = wallpaperStoreContainsMode(root) { mode in
            guard let content = mode["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]]
            else {
                return false
            }
            let matches = choices.contains { choice in
                guard choice["Provider"] as? String
                        == WallpaperPlatformConstants.imageProviderID
                else {
                    return false
                }
                return wallpaperImageURLs(in: choice).contains {
                    $0.standardizedFileURL.path == expectedPath
                }
            }
            guard matches else { return false }
            let timestamp = [mode["LastSet"], mode["LastUse"]]
                .compactMap { $0 as? Date }
                .max() ?? .distantPast
            latestTimestamp = max(latestTimestamp ?? .distantPast, timestamp)
            return true
        }
        return latestTimestamp
    }

    private static func wallpaperStoreContainsManagedDesktop(
        _ data: Data,
        managedAssetID: String
    ) -> Bool {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else {
            return true
        }
        return wallpaperStoreContainsMode(root) { mode in
            containsManagedWallpaperReference(mode)
                || wallpaperModeSelectsAerial(
                    mode,
                    assetID: managedAssetID
                )
        }
    }

    private static func wallpaperModeSelectsAerial(
        _ mode: [String: Any],
        assetID: String
    ) -> Bool {
        guard let content = mode["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]]
        else {
            return false
        }
        return choices.contains { choice in
            guard choice["Provider"] as? String
                    == WallpaperPlatformConstants.aerialProviderID,
                  let configurationData = choice["Configuration"] as? Data,
                  let configuration = try? PropertyListSerialization
                    .propertyList(
                        from: configurationData,
                        options: [],
                        format: nil
                    ) as? [String: Any]
            else {
                return false
            }
            return configuration["assetID"] as? String == assetID
        }
    }

    private static func wallpaperStoreContainsMode(
        _ value: Any,
        matching predicate: ([String: Any]) -> Bool
    ) -> Bool {
        if let dictionary = value as? [String: Any] {
            for key in ["Desktop", "Linked"] {
                if let mode = dictionary[key] as? [String: Any],
                   predicate(mode) {
                    return true
                }
            }
            return dictionary.values.contains {
                wallpaperStoreContainsMode($0, matching: predicate)
            }
        }
        if let array = value as? [Any] {
            return array.contains {
                wallpaperStoreContainsMode($0, matching: predicate)
            }
        }
        return false
    }

    private static func wallpaperImageURLs(
        in choice: [String: Any]
    ) -> [URL] {
        var values = (choice["Files"] as? [[String: Any]])?
            .compactMap { $0["relative"] as? String } ?? []
        if let configurationData = choice["Configuration"] as? Data,
           let configuration = (
               try? PropertyListSerialization.propertyList(
                   from: configurationData,
                   options: [],
                   format: nil
               )
           ) as? [String: Any],
           let url = configuration["url"] as? [String: Any],
           let relative = url["relative"] as? String {
            values.append(relative)
        }
        return values.compactMap { value in
            if let url = URL(string: value), url.isFileURL {
                return url
            }
            return URL(fileURLWithPath: value)
        }
    }

    @discardableResult
    public static func restoreFromBackupFilesResult(
        appSupportPath: String
    ) -> WallpaperRestoreStatus {
        // The modern lock-screen installer restores the exact binary
        // Index.plist, including distinct wallpapers per Space and display.
        // If that restoration is already clean, do not flatten it through the
        // older one-image JSON fallback.
        if wallpaperStoreImageDescriptorsAreValid(),
           wallpaperStoreHasNoManagedDesktopReferences(),
           !modernLockScreenRecoveryStateExists() {
            removeWallpaperBackupFiles(appSupportPath: appSupportPath)
            return .notNeeded
        }

        guard let wallpapers = loadWallpaperBackup(appSupportPath: appSupportPath) else {
            return hasWallpaperBackupFiles(appSupportPath: appSupportPath)
                ? .failed
                : .notNeeded
        }
        let fallbackPath = wallpapers.values.first
        let workspace = NSWorkspace.shared
        var appliedAny = false
        var appliedPathForAllDesktops: String?

        for screen in NSScreen.screens {
            let identifier = screenIdentifier(screen)
            guard let imagePath = wallpapers[identifier] ?? fallbackPath else { continue }
            let standardized = URL(fileURLWithPath: imagePath).standardized.path
            guard FileManager.default.fileExists(atPath: standardized) else { continue }
            let url = URL(fileURLWithPath: standardized)
            if (try? workspace.setDesktopImageURL(url, for: screen, options: [:])) != nil {
                appliedAny = true
                if appliedPathForAllDesktops == nil {
                    appliedPathForAllDesktops = standardized
                }
            }
        }

        guard appliedAny, let path = appliedPathForAllDesktops else {
            return .failed
        }
        guard applyToAllDesktops(imagePath: path) else {
            return .failed
        }
        guard repairWallpaperStoreForRestore(imagePath: path) else {
            return .failed
        }

        // On recent macOS versions WallpaperAgent may report the restored URL
        // while Dock still presents the cached AuraFlow fallback in the active
        // Space. Briefly select an equivalent URL and switch back using only
        // NSWorkspace, then restart Dock's desktop presenter.
        forceRefreshCurrentScreens(
            wallpapers: wallpapers,
            fallbackPath: path,
            appSupportPath: appSupportPath
        )
        restartWallpaperAgent()
        Thread.sleep(forTimeInterval: 0.2)
        // This must be the final wallpaper-store write. Calling NSWorkspace or
        // System Events after it lets their cached pre-repair descriptor
        // overwrite `Files` again, which makes WallpaperImageExtension render
        // black on its next launch.
        guard repairWallpaperStoreForRestore(imagePath: path) else {
            return .failed
        }
        refreshDesktopPresentation()
        Thread.sleep(forTimeInterval: 0.2)
        guard currentScreensMatch(path: path),
              wallpaperStoreHasNoManagedDesktopReferences(),
              wallpaperStoreImageDescriptorsAreValid()
        else {
            return .failed
        }
        removeWallpaperBackupFiles(appSupportPath: appSupportPath)
        return .restored
    }

    @discardableResult
    public static func restoreFromBackupFiles(
        appSupportPath: String
    ) -> Bool {
        restoreFromBackupFilesResult(appSupportPath: appSupportPath) != .failed
    }

    public static func hasWallpaperBackupFiles(appSupportPath: String) -> Bool {
        backupNames.contains {
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: appSupportPath)
                    .appendingPathComponent($0)
                    .path
            )
        }
    }

    /// Deletes legacy Desktop snapshots without applying them. Lock-screen-
    /// only mode never owns the Desktop, so its Remove path must preserve the
    /// user's current wallpaper instead of restoring a pre-Aura snapshot.
    public static func discardWallpaperBackupFiles(
        appSupportPath: String
    ) {
        removeWallpaperBackupFiles(appSupportPath: appSupportPath)
    }

    /// Recovers a wallpaper store left by an older or interrupted AuraFlow
    /// removal even after the JSON backup has already been consumed.
    @discardableResult
    public static func repairCurrentDesktopWallpaperIfNeeded() -> Bool {
        let needsRepair =
            !wallpaperStoreImageDescriptorsAreValid()
            || !wallpaperStoreHasNoManagedDesktopReferences()
        guard needsRepair,
              let imageURL = safeRepairImageURL()
        else {
            return false
        }
        restartWallpaperAgent()
        Thread.sleep(forTimeInterval: 0.2)
        guard repairWallpaperStoreForRestore(
            imagePath: imageURL.path
        ) else {
            return false
        }
        refreshDesktopPresentation()
        Thread.sleep(forTimeInterval: 0.2)
        return wallpaperStoreImageDescriptorsAreValid()
            && wallpaperStoreHasNoManagedDesktopReferences()
    }

    private static func safeRepairImageURL() -> URL? {
        let fileManager = FileManager.default
        let appSupportPath =
            WallpaperRuntimeStore.defaultAppSupportURL().path

        if let backup = loadWallpaperBackup(
            appSupportPath: appSupportPath
        ) {
            for path in backup.values.sorted() {
                if let url = safeExistingImageURL(from: path) {
                    return url
                }
            }
        }

        for screen in NSScreen.screens {
            if let url = NSWorkspace.shared.desktopImageURL(for: screen),
               let safeURL = safeExistingImageURL(from: url.path) {
                return safeURL
            }
        }

        let storeURL = WallpaperPlatformConstants.wallpaperStoreURL(
            homeURL: fileManager.homeDirectoryForCurrentUser
        )
        if let data = try? Data(contentsOf: storeURL),
           let root = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
           ),
           let url = firstSafeImageURL(in: root) {
            return url
        }

        let desktopPicturesURL = URL(
            fileURLWithPath: "/System/Library/Desktop Pictures",
            isDirectory: true
        )
        if let enumerator = fileManager.enumerator(
            at: desktopPicturesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                if let safeURL = safeExistingImageURL(from: url.path) {
                    return safeURL
                }
            }
        }
        return nil
    }

    private static func firstSafeImageURL(in value: Any) -> URL? {
        if let string = value as? String {
            let path: String
            if string.hasPrefix("file://"),
               let url = URL(string: string),
               url.isFileURL {
                path = url.path
            } else {
                path = string
            }
            return safeExistingImageURL(from: path)
        }
        if let data = value as? Data,
           let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
           ) {
            return firstSafeImageURL(in: propertyList)
        }
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                guard let nestedValue = dictionary[key] else { continue }
                if let url = firstSafeImageURL(in: nestedValue) {
                    return url
                }
            }
        }
        if let array = value as? [Any] {
            for item in array {
                if let url = firstSafeImageURL(in: item) {
                    return url
                }
            }
        }
        return nil
    }

    private static func safeExistingImageURL(from path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let lowered = url.path.lowercased()
        let imageExtensions = Set([
            "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff",
        ])
        guard imageExtensions.contains(url.pathExtension.lowercased()),
              !lowered.contains("auraflow"),
              !lowered.contains("last_frame"),
              FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    private static func loadWallpaperBackup(
        appSupportPath: String,
        fileNames: [String] = backupNames
    ) -> [String: String]? {
        let managedPath = managedWallpaperPath(appSupportPath: appSupportPath)
        for fileName in fileNames {
            let path = (appSupportPath as NSString).appendingPathComponent(fileName)
            guard
                let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                let object = try? JSONSerialization.jsonObject(with: data),
                let dictionary = object as? [String: Any]
            else {
                continue
            }

            let parsed = dictionary.reduce(into: [String: String]()) { result, item in
                guard let value = item.value as? String, !value.isEmpty else { return }
                let standardized = URL(fileURLWithPath: value).standardized.path
                if standardized == managedPath {
                    return
                }
                result[item.key] = standardized
            }

            if !parsed.isEmpty {
                return parsed
            }
        }
        return nil
    }

    @discardableResult
    public static func saveWallpaperBackup(
        appSupportPath: String,
        wallpapers: [String: String]
    ) -> Bool {
        saveWallpaperBackup(
            appSupportPath: appSupportPath,
            wallpapers: wallpapers,
            fileNames: backupNames,
            overwriteExisting: false
        )
    }

    private static func saveWallpaperBackup(
        appSupportPath: String,
        wallpapers: [String: String],
        fileNames: [String],
        overwriteExisting: Bool
    ) -> Bool {
        if !overwriteExisting,
           loadWallpaperBackup(
               appSupportPath: appSupportPath,
               fileNames: fileNames
           ) != nil {
            return true
        }
        let managedPath = managedWallpaperPath(appSupportPath: appSupportPath)
        let sanitized = wallpapers.reduce(into: [String: String]()) { result, item in
            let standardized = URL(fileURLWithPath: item.value).standardizedFileURL.path
            guard !standardized.isEmpty, standardized != managedPath else { return }
            result[item.key] = standardized
        }

        guard !sanitized.isEmpty else { return false }

        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: appSupportPath, isDirectory: true),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys])
            for fileName in fileNames {
                let path = (appSupportPath as NSString).appendingPathComponent(fileName)
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }

    private static func runAppleScript(_ source: String) -> (success: Bool, output: String?) {
        let task = Process()
        let outputPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", source]
        task.standardOutput = outputPipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return (false, nil)
        }

        let deadline = Date().addingTimeInterval(2)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard !task.isRunning else {
            task.terminate()
            return (false, nil)
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (task.terminationStatus == 0, output)
    }

    private static func allDesktopsMatch(path: String) -> Bool {
        let escapedPath = escapeForAppleScript(path)
        let verificationScript = """
        tell application "System Events"
          set targetPath to POSIX path of (POSIX file "\(escapedPath)")
          repeat with d in desktops
            try
              set currentPath to POSIX path of (picture of d)
              if currentPath is not targetPath then
                return "mismatch"
              end if
            on error
              return "mismatch"
            end try
          end repeat
          return "ok"
        end tell
        """
        let result = runAppleScript(verificationScript)
        return result.success && result.output?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
    }

    private static func currentScreensMatch(path: String) -> Bool {
        let standardized = URL(fileURLWithPath: path)
            .standardizedFileURL.path
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }
        return screens.allSatisfy {
            NSWorkspace.shared.desktopImageURL(for: $0)?
                .standardizedFileURL.path == standardized
        }
    }

    /// Repairs the private persistence record that backs the public
    /// NSWorkspace API on modern macOS. WallpaperAgent requires image choices
    /// to contain both the image configuration and its URL in `Files`; a URL
    /// only in Configuration can resolve through NSWorkspace yet render black
    /// after WallpaperAgent is restarted.
    private static func repairWallpaperStoreForRestore(
        imagePath: String
    ) -> Bool {
        let fileManager = FileManager.default
        let storeURL = WallpaperPlatformConstants.wallpaperStoreURL(
            homeURL: fileManager.homeDirectoryForCurrentUser
        )
        guard let data = try? Data(contentsOf: storeURL),
              var root = (
                try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                )
              ) as? [String: Any]
        else {
            return false
        }

        let topology = validWallpaperTopology()
        if !topology.spaceIDs.isEmpty,
           var spaces = root["Spaces"] as? [String: Any] {
            spaces = spaces.filter {
                topology.spaceIDs.contains($0.key)
            }
            spaces = spaces.mapValues { value in
                guard var space = value as? [String: Any] else {
                    return value
                }
                if !topology.displayIDs.isEmpty,
                   var displays =
                    space["Displays"] as? [String: Any] {
                    displays = displays.filter {
                        topology.displayIDs.contains($0.key)
                    }
                    space["Displays"] = displays
                }
                return space
            }
            root["Spaces"] = spaces
        }
        if !topology.displayIDs.isEmpty,
           var displays = root["Displays"] as? [String: Any] {
            displays = displays.filter {
                topology.displayIDs.contains($0.key)
            }
            root["Displays"] = displays
        }

        let desktopMode = imageWallpaperStoreMode(
            imagePath: imagePath,
            date: Date()
        )
        let fallbackIdleMode = screenSaverWallpaperStoreMode(date: Date())
        root = mapWallpaperStoreContainers(in: root) { container in
            var result = container
            if result["Desktop"] != nil || result["Idle"] != nil {
                result["Desktop"] = desktopMode
                result["Type"] = "individual"
            }
            if let idle = result["Idle"],
               containsManagedWallpaperReference(idle) {
                result["Idle"] = fallbackIdleMode
            }
            if !topology.displayIDs.isEmpty,
               var displays = result["Displays"] as? [String: Any] {
                displays = displays.filter {
                    topology.displayIDs.contains($0.key)
                }
                result["Displays"] = displays
            }
            return result
        }

        guard let repairedData = try? PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        ) else {
            return false
        }
        do {
            try repairedData.write(to: storeURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func wallpaperStoreHasNoManagedDesktopReferences() -> Bool {
        let storeURL = WallpaperPlatformConstants.wallpaperStoreURL(
            homeURL: FileManager.default.homeDirectoryForCurrentUser
        )
        guard let data = try? Data(contentsOf: storeURL),
              let root = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              )
        else {
            return false
        }
        return !containsManagedWallpaperReference(root)
    }

    private static func modernLockScreenRecoveryStateExists() -> Bool {
        let directoryURL = WallpaperRuntimeStore
            .defaultAppSupportURL()
            .appendingPathComponent(
                "ModernLockScreen",
                isDirectory: true
            )
        for fileName in [
            "installation.json",
            "Index.before-auraflow.plist",
        ] {
            if FileManager.default.fileExists(
                atPath: directoryURL
                    .appendingPathComponent(fileName).path
            ) {
                return true
            }
        }
        return false
    }

    private static func wallpaperStoreImageDescriptorsAreValid() -> Bool {
        let storeURL = WallpaperPlatformConstants.wallpaperStoreURL(
            homeURL: FileManager.default.homeDirectoryForCurrentUser
        )
        guard let data = try? Data(contentsOf: storeURL),
              let root = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              )
        else {
            return false
        }
        return imageDescriptorsAreValid(in: root)
    }

    private static func imageDescriptorsAreValid(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary["Provider"] as? String
                == WallpaperPlatformConstants.imageProviderID {
                guard let files = dictionary["Files"] as? [Any],
                      !files.isEmpty
                else {
                    return false
                }
            }
            return dictionary.values.allSatisfy {
                imageDescriptorsAreValid(in: $0)
            }
        }
        if let array = value as? [Any] {
            return array.allSatisfy {
                imageDescriptorsAreValid(in: $0)
            }
        }
        return true
    }

    private static func containsManagedWallpaperReference(_ value: Any) -> Bool {
        if let string = value as? String {
            return isManagedWallpaperReferencePath(string)
        }
        if let data = value as? Data,
           let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
           ) {
            return containsManagedWallpaperReference(propertyList)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.contains {
                containsManagedWallpaperReference($0.key)
                    || containsManagedWallpaperReference($0.value)
            }
        }
        if let array = value as? [Any] {
            return array.contains(
                where: containsManagedWallpaperReference
            )
        }
        return false
    }

    private static func isManagedWallpaperReferencePath(_ value: String) -> Bool {
        let path: String
        if let url = URL(string: value), url.isFileURL {
            path = url.path
        } else {
            path = value
        }
        let components = URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
            .lowercased()
            .split(separator: "/")
            .map(String.init)
        return components.contains { component in
            component == "last_frame.png"
                || component.hasPrefix("last_frame_")
                    && component.hasSuffix(".png")
                || component == "auraflowlockscreen"
                || component == "auraflowlockscreen.saver"
        }
    }

    private static func imageWallpaperStoreMode(
        imagePath: String,
        date: Date
    ) -> [String: Any] {
        let imageURL = URL(fileURLWithPath: imagePath)
            .standardizedFileURL
        let encodedURL: [String: Any] = [
            "relative": imageURL.absoluteString,
        ]
        let configuration: [String: Any] = [
            "type": "imageFile",
            "url": encodedURL,
        ]
        let configurationData = (
            try? PropertyListSerialization.data(
                fromPropertyList: configuration,
                format: .binary,
                options: 0
            )
        ) ?? Data()
        return [
            "LastSet": date,
            "LastUse": date,
            "Content": [
                "Choices": [[
                    "Provider": WallpaperPlatformConstants.imageProviderID,
                    "Files": [encodedURL],
                    "Configuration": configurationData,
                ]],
                "Shuffle": "$null",
                "EncodedOptionValues": "$null",
            ],
        ]
    }

    private static func screenSaverWallpaperStoreMode(
        date: Date
    ) -> [String: Any] {
        let configuration: [String: Any] = [
            "module": [
                "relative":
                    URL(fileURLWithPath: WallpaperPlatformConstants.fallbackScreenSaverPath)
                        .absoluteString,
            ],
        ]
        let configurationData = (
            try? PropertyListSerialization.data(
                fromPropertyList: configuration,
                format: .binary,
                options: 0
            )
        ) ?? Data()
        return [
            "LastSet": date,
            "LastUse": date,
            "Content": [
                "Choices": [[
                    "Provider":
                        WallpaperPlatformConstants.screenSaverProviderID,
                    "Files": [],
                    "Configuration": configurationData,
                ]],
                "Shuffle": "$null",
                "EncodedOptionValues": "$null",
            ],
        ]
    }

    private static func mapWallpaperStoreContainers(
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

    private static func validWallpaperTopology() -> (
        spaceIDs: Set<String>,
        displayIDs: Set<String>
    ) {
        let spacesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Preferences/com.apple.spaces.plist"
            )
        guard let data = try? Data(contentsOf: spacesURL),
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
        collectWallpaperTopology(
            from: root,
            spaceIDs: &spaceIDs,
            displayIDs: &displayIDs
        )
        return (spaceIDs, displayIDs)
    }

    private static func collectWallpaperTopology(
        from value: Any,
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
                collectWallpaperTopology(
                    from: nestedValue,
                    spaceIDs: &spaceIDs,
                    displayIDs: &displayIDs
                )
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectWallpaperTopology(
                    from: item,
                    spaceIDs: &spaceIDs,
                    displayIDs: &displayIDs
                )
            }
        }
    }

    private static func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func screenIdentifier(_ screen: NSScreen) -> String {
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        if let number = screenNumber as? NSNumber {
            let displayID = CGDirectDisplayID(number.uint32Value)
            return [
                "display",
                String(CGDisplayVendorNumber(displayID)),
                String(CGDisplayModelNumber(displayID)),
                String(CGDisplaySerialNumber(displayID)),
            ].joined(separator: "-")
        }
        return String(describing: ObjectIdentifier(screen))
    }

    private static func managedWallpaperPath(appSupportPath: String) -> String {
        let managedPath = (appSupportPath as NSString).appendingPathComponent("last_frame.png")
        return URL(fileURLWithPath: managedPath).standardized.path
    }

    private static func forceRefreshCurrentScreens(
        wallpapers: [String: String],
        fallbackPath: String,
        appSupportPath: String
    ) {
        let fileManager = FileManager.default
        let workspace = NSWorkspace.shared
        let refreshDirectory = URL(
            fileURLWithPath: appSupportPath,
            isDirectory: true
        ).appendingPathComponent(
            ".wallpaper-restore-\(UUID().uuidString)",
            isDirectory: true
        )
        try? fileManager.createDirectory(
            at: refreshDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: refreshDirectory)
        }

        for (index, screen) in NSScreen.screens.enumerated() {
            let identifier = screenIdentifier(screen)
            let originalPath = wallpapers[identifier] ?? fallbackPath
            let originalURL = URL(
                fileURLWithPath: originalPath
            ).standardizedFileURL
            guard fileManager.fileExists(atPath: originalURL.path) else {
                continue
            }

            let fileExtension = originalURL.pathExtension
            let refreshName = fileExtension.isEmpty
                ? "desktop-\(index)"
                : "desktop-\(index).\(fileExtension)"
            let refreshURL = refreshDirectory
                .appendingPathComponent(refreshName)
            do {
                do {
                    try fileManager.linkItem(
                        at: originalURL,
                        to: refreshURL
                    )
                } catch {
                    try fileManager.copyItem(
                        at: originalURL,
                        to: refreshURL
                    )
                }
                try workspace.setDesktopImageURL(
                    refreshURL,
                    for: screen,
                    options: [:]
                )
                try workspace.setDesktopImageURL(
                    originalURL,
                    for: screen,
                    options: [:]
                )
            } catch {
                continue
            }
        }
    }

    private static func refreshDesktopPresentation() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private static func restartWallpaperAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = [WallpaperPlatformConstants.wallpaperAgentProcessName]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private static func removeWallpaperBackupFiles(
        appSupportPath: String
    ) {
        for fileName in backupNames + [lockScreenBackupName] {
            let url = URL(
                fileURLWithPath: appSupportPath,
                isDirectory: true
            ).appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: url)
        }
    }

}
