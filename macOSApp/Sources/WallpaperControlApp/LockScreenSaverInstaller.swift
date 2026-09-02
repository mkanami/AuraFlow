import CoreFoundation
import AuraWallpaperCore
import Foundation

enum LockScreenSaverInstallerError: LocalizedError {
    case componentNotBundled
    case videoMissing(String)
    case componentSignatureInvalid(String)
    case preferenceUpdateFailed
    case installationRollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .componentNotBundled:
            return "AuraFlow Lock Screen component is not bundled with this build."
        case .videoMissing(let path):
            return "Lock Screen video was not found: \(path)"
        case .componentSignatureInvalid(let detail):
            return "Lock Screen component has an invalid signature: \(detail)"
        case .preferenceUpdateFailed:
            return "macOS did not accept AuraFlow as the active screen saver."
        case .installationRollbackFailed(let detail):
            return "AuraFlow could not restore the previous screen saver component: \(detail)"
        }
    }
}

struct ScreenSaverModulePreference: Codable, Equatable {
    var moduleName: String
    var path: String
    var type: Int

    func pointsTo(_ url: URL) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path
            == url.standardizedFileURL.path
    }

    var propertyList: [String: Any] {
        [
            "moduleName": moduleName,
            "path": path,
            "type": type,
        ]
    }
}

protocol ScreenSaverPreferenceManaging: AnyObject {
    var selectedModule: ScreenSaverModulePreference? { get }
    var idleTime: Int { get }

    @discardableResult
    func apply(
        module: ScreenSaverModulePreference?,
        idleTime: Int?
    ) -> Bool
}

final class HostScreenSaverPreferences: ScreenSaverPreferenceManaging {
    private let applicationID = "com.apple.screensaver" as CFString

    var selectedModule: ScreenSaverModulePreference? {
        guard let dictionary = copyValue(forKey: "moduleDict") as? [String: Any],
              let moduleName = dictionary["moduleName"] as? String,
              let path = dictionary["path"] as? String
        else {
            return nil
        }

        let type = (dictionary["type"] as? NSNumber)?.intValue
            ?? dictionary["type"] as? Int
            ?? 0
        return ScreenSaverModulePreference(
            moduleName: moduleName,
            path: path,
            type: type
        )
    }

    var idleTime: Int {
        if let value = copyValue(forKey: "idleTime") as? NSNumber {
            return value.intValue
        }
        return copyValue(forKey: "idleTime") as? Int ?? 0
    }

    @discardableResult
    func apply(
        module: ScreenSaverModulePreference?,
        idleTime: Int?
    ) -> Bool {
        CFPreferencesSetValue(
            "moduleDict" as CFString,
            module?.propertyList as CFPropertyList?,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
        if let idleTime {
            CFPreferencesSetValue(
                "idleTime" as CFString,
                NSNumber(value: idleTime),
                applicationID,
                kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost
            )
        }
        return CFPreferencesSynchronize(
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
    }

    private func copyValue(forKey key: String) -> Any? {
        CFPreferencesCopyValue(
            key as CFString,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesCurrentHost
        )
    }
}

struct ScreenSaverSelectionCoordinator {
    private struct Backup: Codable {
        var module: ScreenSaverModulePreference?
        var idleTime: Int
    }

    private let fileManager: FileManager
    private let preferences: ScreenSaverPreferenceManaging
    private let destinationURL: URL
    private let backupURL: URL

    init(
        fileManager: FileManager,
        preferences: ScreenSaverPreferenceManaging,
        destinationURL: URL,
        backupURL: URL
    ) {
        self.fileManager = fileManager
        self.preferences = preferences
        self.destinationURL = destinationURL
        self.backupURL = backupURL
    }

    var isSelected: Bool {
        preferences.selectedModule?.pointsTo(destinationURL) == true
    }

    func activate() throws {
        let previousModule = preferences.selectedModule
        let previousIdleTime = preferences.idleTime
        var createdBackup = false
        if previousModule?.pointsTo(destinationURL) != true,
           !fileManager.fileExists(atPath: backupURL.path) {
            let backup = Backup(
                module: previousModule,
                idleTime: previousIdleTime
            )
            let data = try JSONEncoder.auraFlowPretty.encode(backup)
            try fileManager.createDirectory(
                at: backupURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: backupURL, options: .atomic)
            createdBackup = true
        }

        let desiredModule = ScreenSaverModulePreference(
            moduleName: "AuraFlowLockScreen",
            path: destinationURL.standardizedFileURL.path,
            type: 0
        )
        let desiredIdleTime = previousIdleTime > 0 ? nil : 300
        let accepted = preferences.apply(
            module: desiredModule,
            idleTime: desiredIdleTime
        )
        let verified = accepted
            && preferences.selectedModule?.pointsTo(destinationURL) == true
            && preferences.idleTime > 0
        guard verified else {
            _ = preferences.apply(
                module: previousModule,
                idleTime: previousIdleTime
            )
            if createdBackup {
                try? fileManager.removeItem(at: backupURL)
            }
            throw LockScreenSaverInstallerError.preferenceUpdateFailed
        }
    }

    func restoreIfNeeded() throws {
        let preferencesSelectAuraFlow =
            preferences.selectedModule?.pointsTo(destinationURL) == true
        guard preferencesSelectAuraFlow else {
            try? fileManager.removeItem(at: backupURL)
            return
        }

        let backup = (try? Data(contentsOf: backupURL))
            .flatMap { try? JSONDecoder().decode(Backup.self, from: $0) }
        let fallbackModule = ScreenSaverModulePreference(
            moduleName: "Ventura",
            path: "/System/Library/ExtensionKit/Extensions/Ventura.appex",
            type: 0
        )
        let previousModule = backup?.module ?? fallbackModule
        let previousIdleTime = backup?.idleTime ?? 300
        guard preferences.apply(
            module: previousModule,
            idleTime: previousIdleTime
        ),
        preferences.selectedModule == previousModule,
        preferences.idleTime == previousIdleTime
        else {
            throw LockScreenSaverInstallerError.preferenceUpdateFailed
        }
        try? fileManager.removeItem(at: backupURL)
    }
}

final class LockScreenSaverInstaller: LockScreenSaverInstalling {
    private let fileManager: FileManager
    private let templateURL: URL?
    private let destinationURL: URL
    private let selectionCoordinator: ScreenSaverSelectionCoordinator
    private let signatureVerifier: (URL) throws -> Void
    private let operationLock = NSLock()

    init(
        fileManager: FileManager = .default,
        templateURL: URL? = LockScreenSaverInstaller.bundledTemplateURL(),
        destinationURL: URL? = nil,
        preferences: ScreenSaverPreferenceManaging = HostScreenSaverPreferences(),
        preferenceBackupURL: URL? = nil,
        signatureVerifier: ((URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.templateURL = templateURL
        let resolvedDestinationURL = destinationURL
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Screen Savers", isDirectory: true)
                .appendingPathComponent("AuraFlowLockScreen.saver", isDirectory: true)
        self.destinationURL = resolvedDestinationURL
        self.signatureVerifier =
            signatureVerifier ?? Self.verifyBundleSignature
        let resolvedBackupURL = preferenceBackupURL
            ?? WallpaperRuntimeStore.defaultAppSupportURL()
                .appendingPathComponent("screen_saver_backup.json")
        self.selectionCoordinator = ScreenSaverSelectionCoordinator(
            fileManager: fileManager,
            preferences: preferences,
            destinationURL: resolvedDestinationURL,
            backupURL: resolvedBackupURL
        )
    }

    var isInstalled: Bool {
        fileManager.fileExists(atPath: destinationURL.path)
    }

    var installationConfirmed: Bool {
        isInstalled && selectionCoordinator.isSelected
    }

    func install(videoURL: URL) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try installLocked(videoURL: videoURL)
    }

    private func installLocked(videoURL: URL) throws {
        guard let templateURL,
              fileManager.fileExists(atPath: templateURL.path)
        else {
            throw LockScreenSaverInstallerError.componentNotBundled
        }
        guard fileManager.fileExists(atPath: videoURL.path) else {
            throw LockScreenSaverInstallerError.videoMissing(videoURL.path)
        }
        // The saver resolves the current video, fallback frame, and scale mode
        // from AuraFlow's Application Support runtime files. Never inject
        // per-wallpaper data into the bundle: changing a nested bundle after
        // release signing would invalidate its Developer ID/notarization.
        let parentURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )

        let stagingURL = parentURL.appendingPathComponent(
            ".AuraFlowLockScreen.\(UUID().uuidString).saver",
            isDirectory: true
        )
        let previousInstallationURL = parentURL.appendingPathComponent(
            ".AuraFlowLockScreen.previous.\(UUID().uuidString).saver",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: stagingURL)
            try? fileManager.removeItem(at: previousInstallationURL)
        }

        try fileManager.copyItem(at: templateURL, to: stagingURL)
        try signatureVerifier(stagingURL)

        let hadExistingInstallation =
            fileManager.fileExists(atPath: destinationURL.path)
        if hadExistingInstallation {
            try fileManager.moveItem(
                at: destinationURL,
                to: previousInstallationURL
            )
        }
        do {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        } catch {
            try restorePreviousInstallation(
                from: previousInstallationURL,
                hadExistingInstallation: hadExistingInstallation
            )
            throw error
        }
        do {
            try selectionCoordinator.activate()
            refreshScreenSaverHosts()
        } catch {
            try restorePreviousInstallation(
                from: previousInstallationURL,
                hadExistingInstallation: hadExistingInstallation
            )
            throw error
        }
    }

    func uninstall() throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        try selectionCoordinator.restoreIfNeeded()
        refreshScreenSaverHosts()
        guard fileManager.fileExists(atPath: destinationURL.path) else { return }
        // This is AuraFlow's own installed copy. Removing it directly avoids
        // asking Finder to process a Trash operation during Lock rollback.
        try fileManager.removeItem(at: destinationURL)
    }

    private static func verifyBundleSignature(at url: URL) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--verify",
            "--deep",
            "--strict",
            url.path,
        ]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "exit \(process.terminationStatus)"
            throw LockScreenSaverInstallerError.componentSignatureInvalid(detail)
        }
    }

    private func refreshScreenSaverHosts() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-x", "legacyScreenSaver"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private func restorePreviousInstallation(
        from previousInstallationURL: URL,
        hadExistingInstallation: Bool
    ) throws {
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            if hadExistingInstallation {
                try fileManager.moveItem(
                    at: previousInstallationURL,
                    to: destinationURL
                )
            }
        } catch {
            throw LockScreenSaverInstallerError.installationRollbackFailed(
                error.localizedDescription
            )
        }
    }

    private static func bundledTemplateURL() -> URL? {
        let candidates = [
            Bundle.main.builtInPlugInsURL?
                .appendingPathComponent(
                    "AuraFlowLockScreen.saver",
                    isDirectory: true
                ),
            Bundle.main.resourceURL?
                .appendingPathComponent(
                    "AuraFlowLockScreen.saver",
                    isDirectory: true
                ),
        ].compactMap { $0 }

        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

private extension JSONEncoder {
    static var auraFlowPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
