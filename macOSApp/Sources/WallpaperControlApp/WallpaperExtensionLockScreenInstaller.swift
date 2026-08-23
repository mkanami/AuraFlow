import AppKit
import ApplicationServices
import CoreFoundation
import Foundation

enum WallpaperExtensionLockScreenInstallerError: LocalizedError {
    case extensionNotBundled
    case videoMissing(String)
    case wallpaperStoreUnavailable
    case wallpaperStoreMalformed
    case noLockScreenSlot
    case selectionWriteFailed
    case selectionActivationFailed(String)

    var errorDescription: String? {
        switch self {
        case .extensionNotBundled:
            return "AuraFlow's macOS 26+ Lock Screen extension is not bundled with this build."
        case .videoMissing(let path):
            return "Lock Screen media was not found: \(path)"
        case .wallpaperStoreUnavailable:
            return "macOS's wallpaper store is unavailable."
        case .wallpaperStoreMalformed:
            return "macOS's wallpaper store has an unsupported format."
        case .noLockScreenSlot:
            return "macOS did not expose a Lock Screen slot to update."
        case .selectionWriteFailed:
            return "macOS did not accept AuraFlow as the Lock Screen wallpaper."
        case .selectionActivationFailed(let detail):
            return "AuraFlow could not activate its Lock Screen wallpaper: \(detail)"
        }
    }
}

/// Installs AuraFlow media through Apple's macOS 26+ WallpaperExtensionKit
/// provider. Only `Idle` entries are changed; `Desktop` entries are never
/// written by this type.
final class WallpaperExtensionLockScreenInstaller: ModernLockScreenInstalling {
    private struct DeploymentMetadata: Codable {
        var id: String
        var name: String
        var filename: String
        var duration: Double
        var fps: Double
        var resolution: CGSize
        var dateAdded: Date
        var variants: [String: String]?
    }

    private let fileManager: FileManager
    private let extensionBundleURL: URL
    private let extensionDocumentsURL: URL
    private let wallpaperStoreURL: URL
    private let backupURL: URL
    private let entryID = "A2A1B4DD-6CB6-4AF2-8F9D-2A6730B43218"
    private let extensionBundleID = "com.andrijvergeles.auraflow.wallpaper-extension"
    private let restartWallpaperAgentAction: () -> Void
    private let notifyExtensionLibraryChangedAction: () -> Void
    private let activateSelectionAction: () throws -> Void
    private let operationLock = NSLock()

    init(
        fileManager: FileManager = .default,
        extensionBundleURL: URL? = nil,
        extensionDocumentsURL: URL? = nil,
        wallpaperStoreURL: URL? = nil,
        backupURL: URL? = nil,
        restartWallpaperAgentAction: @escaping () -> Void = WallpaperExtensionLockScreenInstaller.restartWallpaperAgent,
        notifyExtensionLibraryChangedAction: @escaping () -> Void = WallpaperExtensionLockScreenInstaller.notifyExtensionLibraryChanged,
        activateSelectionAction: @escaping () throws -> Void = WallpaperExtensionLockScreenInstaller.activateAuraFlowSelection
    ) {
        self.fileManager = fileManager
        self.extensionBundleURL = extensionBundleURL
            ?? Bundle.main.bundleURL
                .appendingPathComponent("Contents/Extensions/AuraFlowWallpaperExtension.appex", isDirectory: true)
        self.extensionDocumentsURL = extensionDocumentsURL
            // The extension is sandboxed. Its home directory is its own
            // container, so the host deploys media into that container's
            // Documents directory and the extension reads the same path.
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Containers/com.andrijvergeles.auraflow.wallpaper-extension/Data/Documents",
                    isDirectory: true
                )
        self.wallpaperStoreURL = wallpaperStoreURL
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/com.apple.wallpaper/Store/Index.plist",
                    isDirectory: false
                )
        self.backupURL = backupURL
            ?? WallpaperRuntimeStore.defaultAppSupportURL()
                .appendingPathComponent("wallpaper_extension_idle_backup.plist")
        self.restartWallpaperAgentAction = restartWallpaperAgentAction
        self.notifyExtensionLibraryChangedAction = notifyExtensionLibraryChangedAction
        self.activateSelectionAction = activateSelectionAction
    }

    var isAvailable: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
            && fileManager.fileExists(atPath: extensionBundleURL.path)
            && fileManager.fileExists(atPath: wallpaperStoreURL.path)
    }

    var isInstalled: Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return currentPropertyList().map { containsAuraFlowIdleSelection(in: $0) } ?? false
    }

    func install(videoURL: URL) throws {
        try install(videoURL: videoURL, activate: false)
    }

    func install(videoURL: URL, activate: Bool) throws {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard fileManager.fileExists(atPath: videoURL.path) else {
            throw WallpaperExtensionLockScreenInstallerError.videoMissing(videoURL.path)
        }
        guard fileManager.fileExists(atPath: extensionBundleURL.path) else {
            throw WallpaperExtensionLockScreenInstallerError.extensionNotBundled
        }

        var propertyList = try loadPropertyList()
        let activationMarkerURL = backupURL
            .deletingLastPathComponent()
            .appendingPathComponent("wallpaper_extension_activation_v2")
        let shouldActivate = activate
            && !fileManager.fileExists(atPath: activationMarkerURL.path)
        guard hasIdleSlot(in: propertyList) else {
            throw WallpaperExtensionLockScreenInstallerError.noLockScreenSlot
        }

        let deployedURL = try deploy(videoURL: videoURL)
        let choice = makeChoice(videoURL: deployedURL)
        let changed = replaceIdleSelections(in: &propertyList, with: choice)
        guard changed > 0 else {
            throw WallpaperExtensionLockScreenInstallerError.noLockScreenSlot
        }

        do {
            try propertyListData(propertyList).write(to: wallpaperStoreURL, options: .atomic)
        } catch {
            throw WallpaperExtensionLockScreenInstallerError.selectionWriteFailed
        }

        restartWallpaperAgentAction()
        guard currentPropertyList().map({ containsAuraFlowIdleSelection(in: $0) }) == true else {
            throw WallpaperExtensionLockScreenInstallerError.selectionWriteFailed
        }
        // Old releases kept a snapshot of Idle and restored it on Remove.
        // That snapshot commonly contains a macOS Aerial (for example Golden
        // Gate), so it must never participate in restoration again.
        try? fileManager.removeItem(at: backupURL)
        notifyExtensionLibraryChangedAction()
        if shouldActivate {
            do {
                try activateSelectionAction()
                try Data().write(to: activationMarkerURL, options: .atomic)
            } catch let error as WallpaperExtensionLockScreenInstallerError {
                throw error
            } catch {
                throw WallpaperExtensionLockScreenInstallerError.selectionActivationFailed(
                    error.localizedDescription
                )
            }
        }
    }

    func uninstall() throws {
        operationLock.lock()
        defer { operationLock.unlock() }

        var propertyList = try loadPropertyList()
        let activationMarkerURL = backupURL
            .deletingLastPathComponent()
            .appendingPathComponent("wallpaper_extension_activation_v2")
        let result = restoreAuraFlowIdleSelectionsFromDesktop(in: &propertyList)
        guard result.managed > 0 else {
            removeDeployment()
            try? fileManager.removeItem(at: backupURL)
            try? fileManager.removeItem(at: activationMarkerURL)
            return
        }

        // Never clear Idle and never fall back to a saved Aerial. Every
        // AuraFlow Idle slot must have the sibling Desktop descriptor that
        // macOS already uses for the same display/Space.
        guard result.restored == result.managed else {
            throw WallpaperExtensionLockScreenInstallerError.noLockScreenSlot
        }

        try propertyListData(propertyList).write(to: wallpaperStoreURL, options: .atomic)
        removeDeployment()
        try? fileManager.removeItem(at: backupURL)
        try? fileManager.removeItem(at: activationMarkerURL)
        restartWallpaperAgentAction()
    }

    private func deploy(videoURL: URL) throws -> URL {
        let videosURL = extensionDocumentsURL.appendingPathComponent("videos", isDirectory: true)
        let entryURL = videosURL.appendingPathComponent(entryID, isDirectory: true)
        try fileManager.createDirectory(at: entryURL, withIntermediateDirectories: true)

        let extensionName = videoURL.pathExtension.isEmpty ? "mov" : videoURL.pathExtension
        let filename = "lock_screen.\(extensionName)"
        let destinationURL = entryURL.appendingPathComponent(filename)
        let temporaryURL = entryURL.appendingPathComponent(".\(filename).tmp-\(UUID().uuidString)")
        try? fileManager.removeItem(at: temporaryURL)
        do {
            try fileManager.copyItem(at: videoURL, to: temporaryURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        // A deployment can change containers (for example mp4 → mov after
        // image/GIF preparation). Keep only the managed media for this entry;
        // otherwise a directory scan can select an older file at random.
        let managedExtensions = Set(["mov", "mp4", "m4v"])
        let deployedFiles = (try? fileManager.contentsOfDirectory(
            at: entryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        for fileURL in deployedFiles
            where fileURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path
                && managedExtensions.contains(fileURL.pathExtension.lowercased()) {
            try? fileManager.removeItem(at: fileURL)
        }

        let metadata = DeploymentMetadata(
            id: entryID,
            name: "AuraFlow Lock Screen",
            filename: filename,
            duration: 0,
            fps: 0,
            resolution: .zero,
            dateAdded: Date(),
            variants: nil
        )
        let metadataURL = entryURL.appendingPathComponent("metadata.json")
        try JSONEncoder().encode(metadata).write(to: metadataURL, options: .atomic)

        // AppViewModel prepares this frame before invoking the installer.
        // Supplying it here keeps WallpaperAgent's settings query fast and
        // prevents the sandboxed extension from blocking while AVFoundation
        // seeks a potentially large source video just to build its tile.
        let preparedStillURL = WallpaperRuntimeStore.defaultAppSupportURL()
            .appendingPathComponent("last_frame.png")
        let thumbnailURL = entryURL.appendingPathComponent("thumbnail.jpg")
        if fileManager.fileExists(atPath: preparedStillURL.path) {
            let temporaryThumbnailURL = entryURL.appendingPathComponent(
                ".thumbnail.tmp-\(UUID().uuidString)"
            )
            try? fileManager.removeItem(at: temporaryThumbnailURL)
            do {
                try fileManager.copyItem(at: preparedStillURL, to: temporaryThumbnailURL)
                if fileManager.fileExists(atPath: thumbnailURL.path) {
                    _ = try fileManager.replaceItemAt(
                        thumbnailURL,
                        withItemAt: temporaryThumbnailURL
                    )
                } else {
                    try fileManager.moveItem(at: temporaryThumbnailURL, to: thumbnailURL)
                }
            } catch {
                try? fileManager.removeItem(at: temporaryThumbnailURL)
                // The video remains valid; a missing thumbnail must not turn
                // Start into a failure.
            }
        }
        return destinationURL
    }

    private func removeDeployment() {
        let entryURL = extensionDocumentsURL
            .appendingPathComponent("videos", isDirectory: true)
            .appendingPathComponent(entryID, isDirectory: true)
        try? fileManager.removeItem(at: entryURL)
    }

    private func makeChoice(videoURL: URL) -> [String: Any] {
        [
            "Provider": extensionBundleID,
            "Files": [["relative": videoURL.absoluteString]],
            "Configuration": Data(entryID.utf8),
        ]
    }

    private func loadPropertyList() throws -> [String: Any] {
        try loadPropertyList(from: wallpaperStoreURL)
    }

    private func loadPropertyList(from url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else {
            throw WallpaperExtensionLockScreenInstallerError.wallpaperStoreUnavailable
        }
        guard let value = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ), let dictionary = value as? [String: Any] else {
            throw WallpaperExtensionLockScreenInstallerError.wallpaperStoreMalformed
        }
        return dictionary
    }

    private func propertyListData(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .binary,
            options: 0
        )
    }

    private func currentPropertyList() -> [String: Any]? {
        try? loadPropertyList()
    }

    private func hasIdleSlot(in dictionary: [String: Any]) -> Bool {
        if dictionary["Idle"] is [String: Any] {
            return true
        }
        return dictionary.values
            .compactMap { $0 as? [String: Any] }
            .contains(where: { hasIdleSlot(in: $0) })
    }

    @discardableResult
    private func replaceIdleSelections(
        in dictionary: inout [String: Any],
        with choice: [String: Any]
    ) -> Int {
        var changed = 0
        if var idle = dictionary["Idle"] as? [String: Any] {
            var content = idle["Content"] as? [String: Any] ?? [:]
            content["Choices"] = [choice]
            content.removeValue(forKey: "Shuffle")
            content.removeValue(forKey: "EncodedOptionValues")
            idle["Content"] = content
            idle["LastSet"] = Date()
            dictionary["Idle"] = idle
            changed += 1
        }

        for key in dictionary.keys where key != "Idle" {
            guard var child = dictionary[key] as? [String: Any] else { continue }
            changed += replaceIdleSelections(in: &child, with: choice)
            dictionary[key] = child
        }
        return changed
    }

    private func restoreAuraFlowIdleSelectionsFromDesktop(
        in dictionary: inout [String: Any]
    ) -> (managed: Int, restored: Int) {
        var managed = 0
        var restored = 0
        if let idle = dictionary["Idle"] as? [String: Any],
           containsAuraFlowSelection(in: idle) {
            managed += 1
            if let desktop = dictionary["Desktop"] as? [String: Any] {
                // Copy the complete macOS-owned descriptor verbatim. This
                // preserves provider, files, configuration, shuffle data,
                // timestamps, and any future fields for this exact Space.
                dictionary["Idle"] = desktop
                restored += 1
            }
        }

        for key in dictionary.keys where key != "Idle" && key != "Desktop" {
            guard var child = dictionary[key] as? [String: Any] else { continue }
            let childResult = restoreAuraFlowIdleSelectionsFromDesktop(in: &child)
            managed += childResult.managed
            restored += childResult.restored
            dictionary[key] = child
        }
        return (managed, restored)
    }

    private func containsAuraFlowIdleSelection(in dictionary: [String: Any]) -> Bool {
        if let idle = dictionary["Idle"] as? [String: Any],
           containsAuraFlowSelection(in: idle) {
            return true
        }
        return dictionary.values
            .compactMap { $0 as? [String: Any] }
            .contains(where: { containsAuraFlowIdleSelection(in: $0) })
    }

    private func containsAuraFlowSelection(in mode: [String: Any]) -> Bool {
        guard let content = mode["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]
              ] else {
            return false
        }
        return choices.contains { choice in
            choice["Provider"] as? String == extensionBundleID
        }
    }

    private static func restartWallpaperAgent() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        try? task.run()
        task.waitUntilExit()
    }

    private static func notifyExtensionLibraryChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName("com.andrijvergeles.auraflow.libraryChanged" as CFString),
            nil,
            nil,
            true
        )
    }

    /// Index.plist is only WallpaperAgent's persisted cache. The active
    /// Lock Screen provider is committed by the system-owned Screen Saver
    /// sheet. This runs once per AuraFlow session; Remove never uses this UI
    /// and restores Idle directly from the matching Desktop descriptor.
    private static func activateAuraFlowSelection() throws {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
            throw WallpaperExtensionLockScreenInstallerError.selectionActivationFailed(
                "Allow AuraFlow in System Settings → Privacy & Security → Accessibility, then press Start again."
            )
        }

        guard let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension?ScreenSaver"
        ) else {
            throw WallpaperExtensionLockScreenInstallerError.selectionActivationFailed(
                "The Screen Saver settings URL is unavailable."
            )
        }
        NSWorkspace.shared.open(settingsURL)

        let deadline = Date().addingTimeInterval(15)
        var pressedScreenSaverButton = false
        while Date() < deadline {
            guard let settings = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.systempreferences"
            ).first else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                continue
            }
            settings.activate(options: [.activateIgnoringOtherApps])
            let root = AXUIElementCreateApplication(settings.processIdentifier)

            if !pressedScreenSaverButton,
               let screenSaver = firstElement(in: root, matching: "Screen Saver") {
                // The Wallpaper page can expose AuraFlow as a regular
                // wallpaper card. Enter the Screen Saver sheet first so a
                // matching AuraFlow label can never change Desktop.
                pressedScreenSaverButton = AXUIElementPerformAction(
                    screenSaver,
                    kAXPressAction as CFString
                ) == .success
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                continue
            }

            guard pressedScreenSaverButton,
                  let sheet = firstElement(in: root, role: kAXSheetRole as String),
                  let auraTile = firstElement(
                      in: sheet,
                      matching: "AuraFlow Lock Screen",
                      exact: true
                  ) else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                continue
            }

            guard AXUIElementPerformAction(auraTile, kAXPressAction as CFString) == .success else {
                throw WallpaperExtensionLockScreenInstallerError.selectionActivationFailed(
                    "macOS rejected the AuraFlow Lock Screen selection."
                )
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            if let done = firstElement(
                in: sheet,
                matching: "Done",
                exact: true
            ) {
                _ = AXUIElementPerformAction(done, kAXPressAction as CFString)
            }
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            return
        }

        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        throw WallpaperExtensionLockScreenInstallerError.selectionActivationFailed(
            "AuraFlow Lock Screen was not listed in Screen Saver settings."
        )
    }

    private static func firstElement(
        in root: AXUIElement,
        matching needle: String = "",
        exact: Bool = false,
        role: String? = nil
    ) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            if depth > 12 { continue }
            var roleMatches = true
            if let role {
                var roleValue: CFTypeRef?
                roleMatches = AXUIElementCopyAttributeValue(
                    element,
                    kAXRoleAttribute as CFString,
                    &roleValue
                ) == .success && roleValue as? String == role
            }
            if roleMatches, !needle.isEmpty {
                for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(
                        element,
                        attribute as CFString,
                        &value
                    ) == .success,
                       let text = value as? String,
                       exact
                           ? text.caseInsensitiveCompare(needle) == .orderedSame
                           : text.localizedCaseInsensitiveContains(needle) {
                        return element
                    }
                }
            }

            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXChildrenAttribute as CFString,
                &childrenValue
            ) == .success,
            let children = childrenValue as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return nil
    }

}
