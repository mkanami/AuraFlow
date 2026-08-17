import CoreFoundation
import Foundation

enum WallpaperExtensionLockScreenInstallerError: LocalizedError {
    case extensionNotBundled
    case videoMissing(String)
    case wallpaperStoreUnavailable
    case wallpaperStoreMalformed
    case noLockScreenSlot
    case backupWriteFailed
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
        case .backupWriteFailed:
            return "AuraFlow could not save the previous Lock Screen wallpaper."
        case .selectionWriteFailed:
            return "macOS did not accept AuraFlow as the Lock Screen wallpaper."
        case .selectionActivationFailed(let detail):
            return "AuraFlow could not commit the Lock Screen selection in System Settings: \(detail)"
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
    private let deactivateSelectionAction: () throws -> Void
    private let operationLock = NSLock()

    init(
        fileManager: FileManager = .default,
        extensionBundleURL: URL? = nil,
        extensionDocumentsURL: URL? = nil,
        wallpaperStoreURL: URL? = nil,
        backupURL: URL? = nil,
        restartWallpaperAgentAction: @escaping () -> Void = WallpaperExtensionLockScreenInstaller.restartWallpaperAgent,
        notifyExtensionLibraryChangedAction: @escaping () -> Void = WallpaperExtensionLockScreenInstaller.notifyExtensionLibraryChanged,
        activateSelectionAction: @escaping () throws -> Void = WallpaperExtensionLockScreenInstaller.activateAuraFlowSelection,
        deactivateSelectionAction: @escaping () throws -> Void = WallpaperExtensionLockScreenInstaller.deactivateAuraFlowSelection
    ) {
        self.fileManager = fileManager
        self.extensionBundleURL = extensionBundleURL
            ?? Bundle.main.bundleURL
                .appendingPathComponent("Contents/Extensions/AuraFlowWallpaperExtension.appex", isDirectory: true)
        self.extensionDocumentsURL = extensionDocumentsURL
            ?? URL(fileURLWithPath: "/Users/Shared/AuraFlow/Lock Screen", isDirectory: true)
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
        self.deactivateSelectionAction = deactivateSelectionAction
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
        try install(videoURL: videoURL, activate: true)
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
        guard hasIdleSlot(in: propertyList) else {
            throw WallpaperExtensionLockScreenInstallerError.noLockScreenSlot
        }

        if !fileManager.fileExists(atPath: backupURL.path) {
            let backupData = try propertyListData(propertyList)
            do {
                try fileManager.createDirectory(
                    at: backupURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try backupData.write(to: backupURL, options: .atomic)
            } catch {
                throw WallpaperExtensionLockScreenInstallerError.backupWriteFailed
            }
        }

        try deploy(videoURL: videoURL)
        let choice = makeChoice(videoURL: deployedVideoURL())
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
        notifyExtensionLibraryChangedAction()
        if activate {
            do {
                try activateSelectionAction()
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
        let changed = removeAuraFlowIdleSelections(in: &propertyList)
        guard changed > 0 else {
            removeDeployment()
            try? fileManager.removeItem(at: backupURL)
            return
        }

        if fileManager.fileExists(atPath: backupURL.path),
           let backup = try? loadPropertyList(from: backupURL) {
            restoreIdleSelections(
                in: &propertyList,
                from: backup
            )
        } else {
            clearAuraFlowIdleSelections(in: &propertyList)
        }

        try propertyListData(propertyList).write(to: wallpaperStoreURL, options: .atomic)
        removeDeployment()
        try? fileManager.removeItem(at: backupURL)
        restartWallpaperAgentAction()
        do {
            try deactivateSelectionAction()
        } catch let error as WallpaperExtensionLockScreenInstallerError {
            throw error
        } catch {
            throw WallpaperExtensionLockScreenInstallerError.selectionActivationFailed(
                error.localizedDescription
            )
        }
    }

    private func deploy(videoURL: URL) throws {
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
    }

    private func removeDeployment() {
        let entryURL = extensionDocumentsURL
            .appendingPathComponent("videos", isDirectory: true)
            .appendingPathComponent(entryID, isDirectory: true)
        try? fileManager.removeItem(at: entryURL)
    }

    private func deployedVideoURL() -> URL {
        let entryURL = extensionDocumentsURL
            .appendingPathComponent("videos", isDirectory: true)
            .appendingPathComponent(entryID, isDirectory: true)
        let contents = (try? fileManager.contentsOfDirectory(
            at: entryURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )) ?? []
        return contents.first(where: { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) })
            ?? entryURL.appendingPathComponent("lock_screen.mov")
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

    @discardableResult
    private func removeAuraFlowIdleSelections(in dictionary: inout [String: Any]) -> Int {
        var changed = 0
        if let idle = dictionary["Idle"] as? [String: Any],
           containsAuraFlowSelection(in: idle) {
            changed += 1
        }

        for key in dictionary.keys where key != "Idle" {
            guard var child = dictionary[key] as? [String: Any] else { continue }
            changed += removeAuraFlowIdleSelections(in: &child)
            dictionary[key] = child
        }
        return changed
    }

    private func clearAuraFlowIdleSelections(in dictionary: inout [String: Any]) {
        if var idle = dictionary["Idle"] as? [String: Any],
           containsAuraFlowSelection(in: idle) {
            var content = idle["Content"] as? [String: Any] ?? [:]
            content["Choices"] = []
            idle["Content"] = content
            dictionary["Idle"] = idle
        }

        for key in dictionary.keys where key != "Idle" {
            guard var child = dictionary[key] as? [String: Any] else { continue }
            clearAuraFlowIdleSelections(in: &child)
            dictionary[key] = child
        }
    }

    private func restoreIdleSelections(
        in dictionary: inout [String: Any],
        from backup: [String: Any]
    ) {
        if let currentIdle = dictionary["Idle"] as? [String: Any],
           containsAuraFlowSelection(in: currentIdle),
           let originalIdle = backup["Idle"] as? [String: Any] {
            dictionary["Idle"] = originalIdle
        }

        for key in dictionary.keys where key != "Idle" {
            guard var child = dictionary[key] as? [String: Any],
                  let originalChild = backup[key] as? [String: Any]
            else { continue }
            restoreIdleSelections(in: &child, from: originalChild)
            dictionary[key] = child
        }
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

    /// WallpaperExtensionKit exposes the provider to System Settings, but
    /// macOS keeps the active screen-saver choice in WallpaperAgent's settings
    /// manager. Writing Index.plist alone only changes a cache and is ignored
    /// on the next lock. The settings sheet is the system-owned commit path.
    private static func activateAuraFlowSelection() throws {
        try commitSystemScreenSaverSelection(clickOffset: (x: 75, y: 475))
    }

    private static func deactivateAuraFlowSelection() throws {
        // The Automatic radio button is the system's safe fallback. It clears
        // AuraFlow from the active Lock Screen without changing Desktop.
        try commitSystemScreenSaverSelection(clickOffset: (x: 310, y: 197))
    }

    private static func commitSystemScreenSaverSelection(clickOffset: (x: Int, y: Int)) throws {
        let script = """
        tell application "System Settings"
            open location "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension?ScreenSaver"
        end tell
        tell application "System Events"
            tell process "System Settings"
                repeat 40 times
                    if exists sheet 1 of window 1 then exit repeat
                    delay 0.15
                end repeat
                if not (exists sheet 1 of window 1) then error "Screen Saver settings did not open"
                set saverSheet to sheet 1 of window 1
                set sheetPosition to position of saverSheet
                click at {(item 1 of sheetPosition) + \(clickOffset.x), (item 2 of sheetPosition) + \(clickOffset.y)}
                delay 0.35
                click button 1 of group 1 of saverSheet
            end tell
        end tell
        """

        let task = Process()
        let output = Pipe()
        let error = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = output
        task.standardError = error
        do {
            try task.run()
        } catch {
            throw WallpaperExtensionLockScreenInstallerError.selectionActivationFailed(
                error.localizedDescription
            )
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WallpaperExtensionLockScreenInstallerError.selectionActivationFailed(
                detail?.isEmpty == false ? detail! : "System Settings rejected the selection"
            )
        }
    }
}
