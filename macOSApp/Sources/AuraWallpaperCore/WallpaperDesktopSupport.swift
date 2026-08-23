import AppKit
import Foundation

public enum WallpaperDesktopSupport {
    private static let backupNames = ["wallpaper_backup.json", "wallpaper_backup_original.json"]
    private static let backupSessionName = "wallpaper_backup_session.json"
    private static let backupMetadataName = "wallpaper_backup_metadata.json"
    private static let backupAssetsDirectoryName = "Restored Wallpapers"

    private struct ExternalWallpaperCandidate {
        let date: Date
        let path: String
    }

    @discardableResult
    public static func captureCurrentDesktopWallpaperBackup(
        appSupportPath: String,
        includeRecoverySnapshot: Bool = false
    ) -> Bool {
        let managedPath = managedWallpaperPath(appSupportPath: appSupportPath)

        // Once Start has opened a backup session, the staged baseline is
        // immutable unless macOS records a genuinely newer external choice.
        // AuraFlow polls this method while running; trusting NSWorkspace on
        // those polls can replace the user's baseline with a cached system
        // dynamic-wallpaper fallback (Golden Gate on some Macs).
        if let sessionStart = wallpaperBackupSessionStartDate(
            appSupportPath: appSupportPath
        ),
           let existing = loadWallpaperBackup(appSupportPath: appSupportPath) {
            if let candidate = currentLiveExternalDesktopWallpaperCandidates()
                .first(where: {
                    $0.date > sessionStart
                        && isEligibleExternalWallpaperPath(
                            $0.path,
                            managedPath: managedPath
                        )
                }) {
                var updated = existing
                var metadata = loadWallpaperBackupMetadata(
                    appSupportPath: appSupportPath
                )
                for screen in NSScreen.screens {
                    let identifier = screenIdentifier(screen)
                    updated[identifier] = candidate.path
                    metadata[identifier] = candidate.date.timeIntervalSince1970
                }
                guard let staged = stageWallpaperBackupFiles(
                    updated,
                    appSupportPath: appSupportPath
                ) else {
                    return false
                }
                let saved = saveWallpaperBackup(
                    appSupportPath: appSupportPath,
                    wallpapers: staged
                )
                if saved {
                    saveWallpaperBackupMetadata(
                        appSupportPath: appSupportPath,
                        dates: metadata
                    )
                }
                return saved
            }

            guard includeRecoverySnapshot,
                  let candidate = currentExternalDesktopWallpaperCandidates()
                    .first(where: {
                        isEligibleExternalWallpaperPath(
                            $0.path,
                            managedPath: managedPath
                        )
                    })
            else {
                return true
            }
            var updated = existing
            var metadata = loadWallpaperBackupMetadata(
                appSupportPath: appSupportPath
            )
            for screen in NSScreen.screens {
                let identifier = screenIdentifier(screen)
                updated[identifier] = candidate.path
                metadata[identifier] = candidate.date.timeIntervalSince1970
            }
            guard let staged = stageWallpaperBackupFiles(
                updated,
                appSupportPath: appSupportPath
            ) else {
                return false
            }
            let saved = saveWallpaperBackup(
                appSupportPath: appSupportPath,
                wallpapers: staged
            )
            if saved {
                saveWallpaperBackupMetadata(
                    appSupportPath: appSupportPath,
                    dates: metadata
                )
            }
            return saved
        }

        let workspace = NSWorkspace.shared
        // Keep the last known external wallpaper for displays whose current
        // desktop URL is temporarily occupied by AuraFlow's still-frame.
        // Refresh every external display on each capture so Remove restores
        // what the user most recently selected outside AuraFlow.
        var wallpapers: [String: String] = [:]
        var metadata = loadWallpaperBackupMetadata(appSupportPath: appSupportPath)
        for screen in NSScreen.screens {
            guard let url = workspace.desktopImageURL(for: screen) else { continue }
            let standardized = url.standardizedFileURL.path
            guard isEligibleExternalWallpaperPath(
                standardized,
                managedPath: managedPath
            ) else {
                continue
            }
            let identifier = screenIdentifier(screen)
            wallpapers[identifier] = standardized
            if metadata[identifier] == nil {
                metadata[identifier] = 0
            }
        }

        // NSWorkspace can keep reporting the provider's cached fallback while
        // System Settings has already committed a newer ordinary image to the
        // wallpaper Store. Prefer the newest external Store entry. During an
        // AuraFlow session an older Store entry may only seed an empty backup;
        // otherwise it must be newer than the session start so that an Aerial
        // snapshot cannot roll the user's return target backwards.
        let liveCandidate = currentLiveExternalDesktopWallpaperCandidates()
            .first(where: {
                isEligibleExternalWallpaperPath(
                    $0.path,
                    managedPath: managedPath
                )
            })
        let recoveryCandidate = includeRecoverySnapshot
            ? currentExternalDesktopWallpaperCandidates()
                .first(where: {
                    isEligibleExternalWallpaperPath(
                        $0.path,
                        managedPath: managedPath
                    )
                })
            : nil
        if let candidate = liveCandidate ?? recoveryCandidate {
            for screen in NSScreen.screens {
                let identifier = screenIdentifier(screen)
                // Aerial owns Idle only. A normal image still present in the
                // live Desktop slot is therefore a stronger source than any
                // legacy JSON that may become readable after the user grants
                // Downloads access.
                wallpapers[identifier] = candidate.path
                metadata[identifier] = candidate.date.timeIntervalSince1970
            }
        }

        if wallpapers.isEmpty,
           let existing = loadWallpaperBackup(appSupportPath: appSupportPath) {
            wallpapers = existing
        }

        guard !wallpapers.isEmpty,
              let stagedWallpapers = stageWallpaperBackupFiles(
                wallpapers,
                appSupportPath: appSupportPath
              )
        else {
            return false
        }
        let saved = saveWallpaperBackup(
            appSupportPath: appSupportPath,
            wallpapers: stagedWallpapers
        )
        if saved {
            saveWallpaperBackupMetadata(
                appSupportPath: appSupportPath,
                dates: metadata
            )
        }
        return saved
    }

    /// Keep the restore payload inside AuraFlow's own container. A wallpaper
    /// selected from Downloads may require folder coordination; doing that
    /// during Remove can block the UI or re-open the TCC prompt. Start is the
    /// only point where we touch the external source. Remove then works only
    /// with this stable local file, which also gives WallpaperAgent a real
    /// image URL instead of falling back to a cached Aerial asset.
    private static func stageWallpaperBackupFiles(
        _ wallpapers: [String: String],
        appSupportPath: String
    ) -> [String: String]? {
        let fileManager = FileManager.default
        let directory = URL(
            fileURLWithPath: appSupportPath,
            isDirectory: true
        ).appendingPathComponent(
            backupAssetsDirectoryName,
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        var staged: [String: String] = [:]
        for (identifier, sourcePath) in wallpapers {
            let sourceURL = URL(fileURLWithPath: sourcePath)
                .standardizedFileURL
            if sourceURL.path.hasPrefix(directory.path + "/") {
                staged[identifier] = sourceURL.path
                continue
            }
            let safeIdentifier = identifier.replacingOccurrences(
                of: "[^A-Za-z0-9._-]",
                with: "-",
                options: .regularExpression
            )
            let fileExtension = sourceURL.pathExtension.lowercased()
            let fileName = fileExtension.isEmpty
                ? safeIdentifier
                : "\(safeIdentifier).\(fileExtension)"
            let stagedURL = directory.appendingPathComponent(fileName)
            do {
                if fileManager.fileExists(atPath: stagedURL.path) {
                    try fileManager.removeItem(at: stagedURL)
                }
                do {
                    try fileManager.linkItem(at: sourceURL, to: stagedURL)
                } catch {
                    try fileManager.copyItem(at: sourceURL, to: stagedURL)
                }
                staged[identifier] = stagedURL.path
            } catch {
                return nil
            }
        }
        return staged.isEmpty ? nil : staged
    }

    /// Starts the lifetime of the backup used by the current AuraFlow
    /// Desktop + Lock Screen session. The wallpaper captured before Start is
    /// the baseline; only Store entries written after Start may replace it.
    @discardableResult
    public static func beginWallpaperBackupSession(
        appSupportPath: String
    ) -> Bool {
        let url = URL(fileURLWithPath: appSupportPath, isDirectory: true)
            .appendingPathComponent(backupSessionName)
        if wallpaperBackupSessionStartDate(appSupportPath: appSupportPath) != nil {
            return true
        }
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: appSupportPath, isDirectory: true),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: ["startedAt": Date().timeIntervalSince1970],
                options: [.sortedKeys]
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func endWallpaperBackupSession(appSupportPath: String) {
        let url = URL(fileURLWithPath: appSupportPath, isDirectory: true)
            .appendingPathComponent(backupSessionName)
        try? FileManager.default.removeItem(at: url)
    }

    /// Returns the stable, app-owned image captured before Start. The Aerial
    /// uninstaller uses this path while composing its one final Store write,
    /// avoiding a visible intermediate system wallpaper during Remove.
    public static func restorationImagePath(
        appSupportPath: String
    ) -> String? {
        loadWallpaperBackup(appSupportPath: appSupportPath)?
            .values
            .map { URL(fileURLWithPath: $0).standardized.path }
            .first { FileManager.default.fileExists(atPath: $0) }
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

            // NSWorkspace changes only the currently visible desktop for a
            // Space. Remove must restore every existing Space, including the
            // ones that are not active when the button is pressed, so always
            // run the System Events all-desktops operation before accepting
            // the fast current-screen result.
            for script in scripts {
                let result = runAppleScript(script)
                if result.success && allDesktopsMatch(path: standardizedPath) {
                    return true
                }
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
            if workspace.desktopImageURL(for: screen)?
                .standardizedFileURL.path == url.path {
                appliedAny = true
                continue
            }
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

    /// The secure login Lock Screen on current macOS releases resolves its
    /// wallpaper from the Desktop slot. The live AuraFlow agent cannot draw
    /// over loginwindow, so keep the selected wallpaper's current frame in
    /// that slot while the agent continues rendering the live desktop.
    @discardableResult
    public static func applyLockScreenFallbackFrame(imagePath: String) -> Bool {
        let standardizedPath = URL(fileURLWithPath: imagePath)
            .standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: standardizedPath) else {
            return false
        }

        let storeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/Store",
                isDirectory: true
            )
            .appendingPathComponent("Index.plist")
        guard let data = try? Data(contentsOf: storeURL),
              let repairedData = wallpaperStoreDataWithLockScreenFallbackFrame(
                  data: data,
                  imagePath: standardizedPath,
                  date: Date()
              )
        else {
            return false
        }

        do {
            try repairedData.write(to: storeURL, options: .atomic)
        } catch {
            return false
        }

        restartWallpaperAgent()
        Thread.sleep(forTimeInterval: 0.2)
        // WallpaperAgent can rewrite its cached descriptor while restarting.
        // Make the fallback frame the final Desktop state that loginwindow
        // will see during the next lock transition.
        do {
            try repairedData.write(to: storeURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Pure Store transformation used by the runtime method and its tests.
    /// It deliberately changes only Desktop modes and preserves Idle, which
    /// is owned by the Aerial Lock Screen installer in this configuration.
    public static func wallpaperStoreDataWithLockScreenFallbackFrame(
        data: Data,
        imagePath: String,
        date: Date
    ) -> Data? {
        guard var root = (
            try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        ) as? [String: Any]
        else {
            return nil
        }

        let desktopMode = imageWallpaperStoreMode(
            imagePath: imagePath,
            date: date
        )
        root = mapWallpaperStoreContainers(in: root) { container in
            var result = container
            if result["Desktop"] != nil || result["Idle"] != nil {
                result["Desktop"] = desktopMode
                result["Type"] = "individual"
            }
            return result
        }

        return try? PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
    }

    /// Pure Store transformation used by Remove. Both surfaces must point to
    /// the restored external image before WallpaperAgent is restarted.
    public static func wallpaperStoreDataWithRestoredImage(
        data: Data,
        imagePath: String,
        date: Date
    ) -> Data? {
        guard var root = (
            try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        ) as? [String: Any]
        else {
            return nil
        }

        let imageMode = imageWallpaperStoreMode(
            imagePath: imagePath,
            date: date
        )
        root = mapWallpaperStoreContainers(in: root) { container in
            var result = container
            if result["Desktop"] != nil || result["Idle"] != nil {
                result["Desktop"] = imageMode
                result["Idle"] = imageMode
                result["Type"] = "individual"
            }
            return result
        }
        return try? PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
    }

    @discardableResult
    public static func restoreFromBackupFiles(
        appSupportPath: String
    ) -> Bool {
        let wallpapers = loadWallpaperBackup(appSupportPath: appSupportPath)
        guard let wallpapers else { return false }

        // Test and preview stores use temporary app-support directories.
        // They may exercise backup serialization, but must never rewrite the
        // signed-in user's real macOS wallpaper Store or NSWorkspace desktop.
        // Only AuraFlow's canonical runtime directory owns that operation.
        let requestedSupportURL = URL(
            fileURLWithPath: appSupportPath,
            isDirectory: true
        ).standardizedFileURL
        let runtimeSupportURL = WallpaperRuntimeStore
            .defaultAppSupportURL()
            .standardizedFileURL
        guard requestedSupportURL.path == runtimeSupportURL.path else {
            let hasRestorableImage = wallpapers.values.contains { path in
                FileManager.default.fileExists(atPath: path)
            }
            removeWallpaperBackupFiles(appSupportPath: appSupportPath)
            return hasRestorableImage
        }

        guard let path = wallpapers.values
            .map({ URL(fileURLWithPath: $0).standardized.path })
            .first(where: { FileManager.default.fileExists(atPath: $0) })
        else {
            return false
        }

        // Remove is a single wallpaper transaction. Do not call NSWorkspace,
        // System Events, Finder, or a provider uninstall before/after this
        // write: every one of those APIs performs another asynchronous
        // wallpaper mutation and creates the user-image → grey → Aerial →
        // user-image sequence. Replace every Desktop and Idle slot atomically,
        // then reload WallpaperAgent exactly once.
        guard repairWallpaperStoreForRestore(imagePath: path) else {
            return false
        }

        // WallpaperAgent may rewrite its cached provider after the first
        // restart. Keep the backup until the final Store really contains the
        // restored image in both Desktop and Idle slots.
        restartWallpaperAgent()
        Thread.sleep(forTimeInterval: 0.35)
        terminateAerialProvider()
        var restorationVerified = false
        for _ in 0..<3 {
            guard repairWallpaperStoreForRestore(imagePath: path) else {
                return false
            }
            Thread.sleep(forTimeInterval: 0.2)
            if wallpaperStoreImageDescriptorsAreValid(),
               wallpaperStoreHasNoManagedDesktopReferences(),
               !wallpaperStoreNeedsLockScreenSync() {
                restorationVerified = true
                break
            }
        }
        guard restorationVerified else {
            return false
        }
        discardAerialRecoveryState(appSupportPath: appSupportPath)
        removeWallpaperBackupFiles(appSupportPath: appSupportPath)
        return true
    }

    /// Removes recovery files without changing the system wallpaper store.
    /// Desktop-only playback never owns that store, so any stale recovery
    /// files from an older version must be discarded rather than restored.
    public static func discardWallpaperBackups(appSupportPath: String) {
        removeWallpaperBackupFiles(appSupportPath: appSupportPath)
    }

    /// Recovers a wallpaper store left by an older or interrupted AuraFlow
    /// removal even after the JSON backup has already been consumed.
    @discardableResult
    public static func repairCurrentDesktopWallpaperIfNeeded() -> Bool {
        let needsRepair =
            !wallpaperStoreImageDescriptorsAreValid()
            || !wallpaperStoreHasNoManagedDesktopReferences()
            || wallpaperStoreNeedsLockScreenSync()
        guard needsRepair else { return false }

        if let imageURL = safeRepairImageURL() {
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
                && !wallpaperStoreNeedsLockScreenSync()
        }

        // A system dynamic wallpaper (for example, an Aerial) has no user
        // image file to restore. In that case copy the valid Desktop mode to
        // Idle instead of falling back to a black/default Lock Screen.
        return syncLockScreenStoreToDesktop()
    }

    private static func safeRepairImageURL() -> URL? {
        let fileManager = FileManager.default
        let appSupportPath =
            WallpaperRuntimeStore.defaultAppSupportURL().path

        // The live wallpaper store is the freshest source. System Settings
        // stores ordinary image URLs in Configuration even when Files is
        // empty, so use the same parser as the backup capture path here.
        for path in currentExternalDesktopWallpaperPaths() {
            if let url = safeExistingImageURL(from: path) {
                return url
            }
        }

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
               let safeURL = safeExistingImageURL(from: url.path),
               !isSystemWallpaperURL(safeURL) {
                return safeURL
            }
        }

        let storeURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/Store",
                isDirectory: true
            )
            .appendingPathComponent("Index.plist")
        if let data = try? Data(contentsOf: storeURL),
           let root = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
           ),
           let url = firstSafeImageURL(in: root) {
            return url
        }

        return nil
    }

    private static func isSystemWallpaperURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        return path.hasPrefix("/system/library/desktop pictures/")
            || path.contains("/system/library/coreservices/defaultdesktop")
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
              !lowered.contains("last_frame"),
              !lowered.contains("/com.apple.wallpaper/aerials/"),
              FileManager.default.fileExists(atPath: url.path)
        else {
            return nil
        }
        return url
    }

    private static func isSafeExternalWallpaperPath(
        _ path: String,
        managedPath: String
    ) -> Bool {
        guard !path.isEmpty,
              URL(fileURLWithPath: path).standardizedFileURL.path != managedPath
        else {
            return false
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !isAuraFlowOwnedWallpaperURL(url, managedPath: managedPath) else {
            return false
        }
        guard let safeURL = safeExistingImageURL(from: url.path) else {
            return false
        }
        // NSWorkspace can expose Apple's fallback wallpaper while the Aerial
        // provider owns the live slot. It is not a user backup and must never
        // replace the last real wallpaper selected in System Settings.
        return !isSystemWallpaperURL(safeURL)
    }

    private static func isSafeBackupPath(
        _ path: String,
        managedPath: String,
        appSupportPath: String
    ) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let restoredDirectory = URL(
            fileURLWithPath: appSupportPath,
            isDirectory: true
        )
        .appendingPathComponent(backupAssetsDirectoryName, isDirectory: true)
        .standardizedFileURL

        // Only the staged restore asset is allowed to live inside AuraFlow's
        // support directory. Other managed files such as last_frame.png must
        // never become the user's wallpaper baseline.
        if url.path.hasPrefix(restoredDirectory.path + "/") {
            return safeExistingImageURL(from: url.path) != nil
        }
        return isSafeExternalWallpaperPath(
            url.path,
            managedPath: managedPath
        )
    }

    /// Capture must not probe protected folders with `fileExists` first:
    /// macOS answers that probe with `false` after a denial and never presents
    /// the folder-access dialog. The staging copy is the authoritative
    /// readability check and gives the user the normal one-time TCC prompt.
    private static func isEligibleExternalWallpaperPath(
        _ path: String,
        managedPath: String
    ) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let lowered = url.path.lowercased()
        let imageExtensions = Set([
            "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff",
        ])
        guard !url.path.isEmpty,
              url.path != managedPath,
              !isAuraFlowOwnedWallpaperURL(url, managedPath: managedPath),
              imageExtensions.contains(url.pathExtension.lowercased()),
              !lowered.contains("last_frame"),
              !lowered.contains("/com.apple.wallpaper/aerials/"),
              !isSystemWallpaperURL(url)
        else {
            return false
        }
        return true
    }

    private static func isAuraFlowOwnedWallpaperURL(
        _ url: URL,
        managedPath: String
    ) -> Bool {
        let normalizedPath = url.standardizedFileURL.path
        let managedURL = URL(fileURLWithPath: managedPath)
            .standardizedFileURL
        let appSupportPath = managedURL.deletingLastPathComponent().path
        return normalizedPath == managedURL.path
            || normalizedPath.hasPrefix(appSupportPath + "/")
    }

    private static func currentExternalDesktopWallpaperPaths() -> [String] {
        currentExternalDesktopWallpaperCandidates().map(\.path)
    }

    private static func currentExternalDesktopWallpaperCandidates() -> [ExternalWallpaperCandidate] {
        currentExternalDesktopWallpaperCandidates(includeModernBackup: true)
    }

    private static func currentLiveExternalDesktopWallpaperCandidates() -> [ExternalWallpaperCandidate] {
        currentExternalDesktopWallpaperCandidates(includeModernBackup: false)
    }

    private static func currentExternalDesktopWallpaperCandidates(
        includeModernBackup: Bool
    ) -> [ExternalWallpaperCandidate] {
        var candidates: [ExternalWallpaperCandidate] = []
        let storeURLs = wallpaperStoreURLsForCapture()
        for (index, storeURL) in storeURLs.enumerated() {
            if index > 0 && !includeModernBackup {
                break
            }
            guard let data = try? Data(contentsOf: storeURL),
                  let root = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  )
            else {
                continue
            }
            collectExternalDesktopWallpaperPaths(
                in: root,
                into: &candidates
            )
            // The live store wins whenever it still contains a user image.
            // The second file is only the exact pre-AuraFlow snapshot kept by
            // the modern Lock Screen installer.
            if !candidates.isEmpty {
                break
            }
        }

        var result: [ExternalWallpaperCandidate] = []
        for candidate in candidates.sorted(by: { $0.date > $1.date }) {
            guard !result.contains(where: { $0.path == candidate.path }) else {
                continue
            }
            result.append(candidate)
        }
        return result
    }

    private static func wallpaperStoreURLsForCapture() -> [URL] {
        let storeDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/Store",
                isDirectory: true
            )
        let modernBackup = WallpaperRuntimeStore.defaultAppSupportURL()
            .appendingPathComponent(
                "ModernLockScreen/Index.before-auraflow.plist"
            )
        return [
            storeDirectory.appendingPathComponent("Index.plist"),
            modernBackup,
        ]
    }

    private static func collectExternalDesktopWallpaperPaths(
        in value: Any,
        into candidates: inout [ExternalWallpaperCandidate]
    ) {
        if let dictionary = value as? [String: Any] {
            // macOS can record the latest ordinary image in Desktop or only
            // in Idle while it transitions between the unlocked and locked
            // surfaces. Reading Desktop alone leaves the previous cached
            // image as the next Remove target.
            // Desktop is the authoritative external wallpaper while AuraFlow
            // owns the Lock Screen. Consult Idle only when this container has
            // no ordinary Desktop image; otherwise an older Idle picture can
            // beat the user's actual Desktop merely because its LastSet is
            // newer.
            let desktopMode = dictionary["Desktop"] as? [String: Any]
            let desktopURL = desktopMode.flatMap {
                externalImageURL(from: $0)
            }
            let selectedModes: [([String: Any], URL)]
            if let desktopMode, let desktopURL {
                selectedModes = [(desktopMode, desktopURL)]
            } else if let idleMode = dictionary["Idle"] as? [String: Any],
                      let idleURL = externalImageURL(from: idleMode) {
                selectedModes = [(idleMode, idleURL)]
            } else {
                selectedModes = []
            }
            for (mode, imageURL) in selectedModes {
                candidates.append(ExternalWallpaperCandidate(
                    date: mode["LastSet"] as? Date ?? .distantPast,
                    path: imageURL.path
                ))
            }
            for (key, nestedValue) in dictionary
            where key != "Desktop" && key != "Idle" {
                collectExternalDesktopWallpaperPaths(
                    in: nestedValue,
                    into: &candidates
                )
            }
            return
        }
        if let array = value as? [Any] {
            for item in array {
                collectExternalDesktopWallpaperPaths(
                    in: item,
                    into: &candidates
                )
            }
        }
    }

    private static func externalImageURL(
        from desktop: [String: Any]
    ) -> URL? {
        guard let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [Any]
        else {
            return nil
        }

        for choice in choices {
            guard let dictionary = choice as? [String: Any] else { continue }
            let provider = (dictionary["Provider"] as? String)?.lowercased() ?? ""
            guard !provider.contains("aerial"),
                  !provider.contains("screen-saver"),
                  provider != "default"
            else {
                continue
            }
            if let imageURL = imageURL(from: dictionary) {
                return imageURL
            }
        }
        return nil
    }

    /// Returns the image represented by a wallpaper choice. Recent macOS
    /// versions often leave `Files` empty for a normal user wallpaper and put
    /// the file URL only in the binary property-list stored in `Configuration`.
    private static func imageURL(from choice: [String: Any]) -> URL? {
        if let files = choice["Files"],
           let imageURL = firstSafeImageURL(in: files) {
            return imageURL
        }
        guard let configuration = choice["Configuration"] else {
            return nil
        }
        return firstSafeImageURL(in: configuration)
    }

    private static func loadWallpaperBackup(appSupportPath: String) -> [String: String]? {
        let managedPath = managedWallpaperPath(appSupportPath: appSupportPath)
        for fileName in backupNames {
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
                let standardized = URL(fileURLWithPath: value)
                    .standardizedFileURL.path
                if !isSafeBackupPath(
                    standardized,
                    managedPath: managedPath,
                    appSupportPath: appSupportPath
                ) {
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

    private static func wallpaperBackupSessionStartDate(
        appSupportPath: String
    ) -> Date? {
        let url = URL(fileURLWithPath: appSupportPath, isDirectory: true)
            .appendingPathComponent(backupSessionName)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let startedAt = dictionary["startedAt"] as? NSNumber
        else {
            return nil
        }
        return Date(timeIntervalSince1970: startedAt.doubleValue)
    }

    private static func loadWallpaperBackupMetadata(
        appSupportPath: String
    ) -> [String: Double] {
        let url = URL(fileURLWithPath: appSupportPath, isDirectory: true)
            .appendingPathComponent(backupMetadataName)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return [:]
        }
        return dictionary.reduce(into: [String: Double]()) { result, item in
            if let value = item.value as? NSNumber {
                result[item.key] = value.doubleValue
            }
        }
    }

    private static func saveWallpaperBackupMetadata(
        appSupportPath: String,
        dates: [String: Double]
    ) {
        guard !dates.isEmpty else { return }
        let url = URL(fileURLWithPath: appSupportPath, isDirectory: true)
            .appendingPathComponent(backupMetadataName)
        guard let data = try? JSONSerialization.data(
            withJSONObject: dates,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    @discardableResult
    public static func saveWallpaperBackup(appSupportPath: String, wallpapers: [String: String]) -> Bool {
        let managedPath = managedWallpaperPath(appSupportPath: appSupportPath)
        let sanitized = wallpapers.reduce(into: [String: String]()) { result, item in
            let standardized = URL(fileURLWithPath: item.value).standardizedFileURL.path
            guard isSafeBackupPath(
                standardized,
                managedPath: managedPath,
                appSupportPath: appSupportPath
            ) else {
                return
            }
            result[item.key] = standardized
        }

        guard !sanitized.isEmpty else { return false }

        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: appSupportPath, isDirectory: true),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys])
            for fileName in backupNames {
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
        let storeURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/Store",
                isDirectory: true
            )
            .appendingPathComponent("Index.plist")
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
        root = mapWallpaperStoreContainers(in: root) { container in
            var result = container
            if result["Desktop"] != nil || result["Idle"] != nil {
                result["Desktop"] = desktopMode
                // Keep the restored Lock Screen in sync with the restored
                // desktop. Leaving Idle as `default` is what produces the
                // completely black Lock Screen after Remove.
                result["Idle"] = desktopMode
                result["Type"] = "individual"
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

        guard let filteredData = try? PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        ),
        let repairedData = wallpaperStoreDataWithRestoredImage(
            data: filteredData,
            imagePath: imagePath,
            date: Date()
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
        let storeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/Store",
                isDirectory: true
            )
            .appendingPathComponent("Index.plist")
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

    /// Detects a normal desktop image whose Lock Screen slot is missing,
    /// default, or points at a different ordinary image. The app intentionally
    /// keeps these two slots synchronized whenever AuraFlow is not using a
    /// dedicated Lock Screen source.
    private static func wallpaperStoreNeedsLockScreenSync() -> Bool {
        let storeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/Store",
                isDirectory: true
            )
            .appendingPathComponent("Index.plist")
        guard let data = try? Data(contentsOf: storeURL),
              let root = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              )
        else {
            return false
        }
        return wallpaperStoreNeedsLockScreenSync(in: root)
    }

    private static func wallpaperStoreNeedsLockScreenSync(in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if let desktop = dictionary["Desktop"] as? [String: Any] {
                let desktopProvider = wallpaperProvider(from: desktop)
                let idle = dictionary["Idle"] as? [String: Any]
                let idleProvider = idle.flatMap {
                    wallpaperProvider(from: $0)
                }
                let desktopURL = externalImageURL(from: desktop)
                let idleURL = idle.flatMap {
                    externalImageURL(from: $0)
                }

                // A normal image in either slot is a user wallpaper. During
                // a macOS transition the other slot may still be `default`;
                // keep both surfaces synchronized instead of allowing a
                // black Lock Screen or an old cached image on Remove.
                if desktopURL?.standardizedFileURL.path
                    != idleURL?.standardizedFileURL.path {
                    if desktopURL != nil || idleURL != nil {
                        return true
                    }
                } else if desktopURL == nil,
                          desktopProvider != idleProvider,
                          desktopProvider != nil || idleProvider != nil {
                    return true
                }
            }
            return dictionary.values.contains {
                wallpaperStoreNeedsLockScreenSync(in: $0)
            }
        }
        if let array = value as? [Any] {
            return array.contains {
                wallpaperStoreNeedsLockScreenSync(in: $0)
            }
        }
        return false
    }

    private static func wallpaperProvider(
        from mode: [String: Any]
    ) -> String? {
        guard let content = mode["Content"] as? [String: Any],
              let choices = content["Choices"] as? [Any]
        else {
            return nil
        }
        return choices
            .compactMap { $0 as? [String: Any] }
            .compactMap { $0["Provider"] as? String }
            .first?
            .lowercased()
    }

    private static func syncLockScreenStoreToDesktop() -> Bool {
        let storeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/Store",
                isDirectory: true
            )
            .appendingPathComponent("Index.plist")
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

        root = mapWallpaperStoreContainers(in: root) { container in
            var result = container
            guard let desktop = result["Desktop"] as? [String: Any],
                  let desktopProvider = wallpaperProvider(from: desktop),
                  desktopProvider != "default",
                  !desktopProvider.contains("screen-saver")
            else {
                return result
            }
            result["Idle"] = desktop
            result["Type"] = "individual"
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
        } catch {
            return false
        }
        restartWallpaperAgent()
        Thread.sleep(forTimeInterval: 0.2)
        // WallpaperAgent can rewrite its cached descriptor while restarting.
        // Make the synchronized Idle mode the final store state.
        do {
            try repairedData.write(to: storeURL, options: .atomic)
        } catch {
            return false
        }
        refreshDesktopPresentation()
        return !wallpaperStoreNeedsLockScreenSync()
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
        let storeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/Store",
                isDirectory: true
            )
            .appendingPathComponent("Index.plist")
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
                == "com.apple.wallpaper.choice.image" {
                guard imageURL(from: dictionary) != nil else {
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
            let lowered = string.lowercased()
            return lowered.contains("auraflow")
                || lowered.contains("last_frame")
        }
        if let data = value as? Data {
            // Configuration blobs are binary property lists and may contain
            // nested Data values. Recursively decoding every blob can keep
            // Remove on the main thread for tens of seconds (or loop through
            // nested encoded values). Managed provider IDs and file paths are
            // ASCII, so a raw case-insensitive scan is sufficient here.
            let lowered = String(decoding: data, as: UTF8.self).lowercased()
            return lowered.contains("auraflow")
                || lowered.contains("last_frame")
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
                    "Provider": "com.apple.wallpaper.choice.image",
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
                    "file:///System/Library/ExtensionKit/Extensions/Ventura.appex",
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
                        "com.apple.wallpaper.choice.screen-saver",
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
        if let allSpacesAndDisplays =
            result["AllSpacesAndDisplays"] as? [String: Any] {
            result["AllSpacesAndDisplays"] = transform(
                allSpacesAndDisplays
            )
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
        process.arguments = ["WallpaperAgent"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private static func discardAerialRecoveryState(appSupportPath: String) {
        let stateDirectory = URL(
            fileURLWithPath: appSupportPath,
            isDirectory: true
        ).appendingPathComponent("ModernLockScreen", isDirectory: true)
        try? FileManager.default.removeItem(at: stateDirectory)
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
            return
        }
    }

    private static func removeWallpaperBackupFiles(
        appSupportPath: String
    ) {
        for fileName in backupNames {
            let url = URL(
                fileURLWithPath: appSupportPath,
                isDirectory: true
            ).appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: url)
        }
        endWallpaperBackupSession(appSupportPath: appSupportPath)
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: appSupportPath, isDirectory: true)
                .appendingPathComponent(backupMetadataName)
        )
    }

}
