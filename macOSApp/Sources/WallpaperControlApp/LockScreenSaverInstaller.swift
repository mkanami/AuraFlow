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
        var wallpaperStoreData: Data?
    }

    private let fileManager: FileManager
    private let preferences: ScreenSaverPreferenceManaging
    private let destinationURL: URL
    private let backupURL: URL
    private let wallpaperStoreURL: URL?

    init(
        fileManager: FileManager,
        preferences: ScreenSaverPreferenceManaging,
        destinationURL: URL,
        backupURL: URL,
        wallpaperStoreURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.preferences = preferences
        self.destinationURL = destinationURL
        self.backupURL = backupURL
        self.wallpaperStoreURL = wallpaperStoreURL
    }

    func activate() throws {
        let previousModule = preferences.selectedModule
        let previousIdleTime = preferences.idleTime
        let previousWallpaperStoreData = try currentWallpaperStoreData()
        var createdBackup = false
        if previousModule?.pointsTo(destinationURL) != true,
           !fileManager.fileExists(atPath: backupURL.path) {
            let backup = Backup(
                module: previousModule,
                idleTime: previousIdleTime,
                wallpaperStoreData: previousWallpaperStoreData
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
        do {
            guard accepted,
                  preferences.selectedModule?.pointsTo(destinationURL) == true,
                  preferences.idleTime > 0
            else {
                throw LockScreenSaverInstallerError.preferenceUpdateFailed
            }
            try writeAuraFlowWallpaperStoreIfAvailable()
            guard wallpaperStoreSelectsAuraFlowIfAvailable() else {
                throw LockScreenSaverInstallerError.preferenceUpdateFailed
            }
        } catch {
            _ = preferences.apply(
                module: previousModule,
                idleTime: previousIdleTime
            )
            restoreWallpaperStore(previousWallpaperStoreData)
            if createdBackup {
                try? fileManager.removeItem(at: backupURL)
            }
            throw error
        }
    }

    func restoreIfNeeded() throws {
        let preferencesSelectAuraFlow =
            preferences.selectedModule?.pointsTo(destinationURL) == true
        let storeSelectsAuraFlow = wallpaperStoreSelectsAuraFlowIfAvailable()
        guard preferencesSelectAuraFlow || storeSelectsAuraFlow else {
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
        let currentModule = preferences.selectedModule
        let currentIdleTime = preferences.idleTime
        let currentWallpaperStoreData = try currentWallpaperStoreData()
        do {
            guard preferences.apply(
                module: previousModule,
                idleTime: previousIdleTime
            ),
            preferences.selectedModule == previousModule,
            preferences.idleTime == previousIdleTime
            else {
                throw LockScreenSaverInstallerError.preferenceUpdateFailed
            }
            try restoreManagedWallpaperStore(
                savedData: backup?.wallpaperStoreData,
                currentData: currentWallpaperStoreData,
                isManaged: storeSelectsAuraFlow
            )
        } catch {
            _ = preferences.apply(
                module: currentModule,
                idleTime: currentIdleTime
            )
            if let currentWallpaperStoreData,
               let wallpaperStoreURL {
                try? currentWallpaperStoreData.write(
                    to: wallpaperStoreURL,
                    options: .atomic
                )
            }
            throw error
        }
        try? fileManager.removeItem(at: backupURL)
    }

    private func currentWallpaperStoreData() throws -> Data? {
        guard let wallpaperStoreURL,
              fileManager.fileExists(atPath: wallpaperStoreURL.path)
        else {
            return nil
        }
        return try Data(contentsOf: wallpaperStoreURL)
    }

    private func writeAuraFlowWallpaperStoreIfAvailable() throws {
        guard let wallpaperStoreURL,
              fileManager.fileExists(atPath: wallpaperStoreURL.path)
        else {
            return
        }
        let data = try Data(contentsOf: wallpaperStoreURL)
        guard let root = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
        else {
            throw LockScreenSaverInstallerError.preferenceUpdateFailed
        }
        guard let updatedRoot = replaceIdleModes(in: root) as? [String: Any]
        else {
            throw LockScreenSaverInstallerError.preferenceUpdateFailed
        }
        let updatedData = try PropertyListSerialization.data(
            fromPropertyList: updatedRoot,
            format: .binary,
            options: 0
        )
        try updatedData.write(to: wallpaperStoreURL, options: .atomic)
    }

    private func restoreWallpaperStore(_ data: Data?) {
        guard let data,
              let wallpaperStoreURL
        else {
            return
        }
        try? data.write(to: wallpaperStoreURL, options: .atomic)
    }

    private func restoreManagedWallpaperStore(
        savedData: Data?,
        currentData: Data?,
        isManaged: Bool
    ) throws {
        guard isManaged,
              let wallpaperStoreURL
        else {
            return
        }
        if let savedData {
            try savedData.write(to: wallpaperStoreURL, options: .atomic)
            return
        }
        guard let currentData,
              let root = try PropertyListSerialization.propertyList(
                  from: currentData,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let restoredRoot = restoreAuraFlowIdleModes(in: root) as? [String: Any]
        else {
            throw LockScreenSaverInstallerError.preferenceUpdateFailed
        }
        let restoredData = try PropertyListSerialization.data(
            fromPropertyList: restoredRoot,
            format: .binary,
            options: 0
        )
        try restoredData.write(to: wallpaperStoreURL, options: .atomic)
    }

    private func wallpaperStoreSelectsAuraFlowIfAvailable() -> Bool {
        guard let wallpaperStoreURL,
              fileManager.fileExists(atPath: wallpaperStoreURL.path),
              let data = try? Data(contentsOf: wallpaperStoreURL),
              let root = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              )
        else {
            return wallpaperStoreURL == nil
                || !fileManager.fileExists(
                    atPath: wallpaperStoreURL?.path ?? ""
                )
        }
        return containsAuraFlowReference(root)
    }

    private func replaceIdleModes(in value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            if dictionary["Desktop"] != nil || dictionary["Idle"] != nil {
                dictionary["Idle"] = auraFlowScreenSaverMode()
                dictionary["Type"] = "individual"
            }
            for key in dictionary.keys where key != "Desktop" && key != "Idle" {
                if let nested = dictionary[key] {
                    dictionary[key] = replaceIdleModes(in: nested)
                }
            }
            return dictionary
        }
        if let array = value as? [Any] {
            return array.map { replaceIdleModes(in: $0) }
        }
        return value
    }

    private func restoreAuraFlowIdleModes(in value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            if let idle = dictionary["Idle"] as? [String: Any],
               containsAuraFlowReference(idle) {
                if let desktop = dictionary["Desktop"] as? [String: Any] {
                    dictionary["Idle"] = desktop
                } else {
                    dictionary["Idle"] = defaultScreenSaverMode()
                }
            }
            for key in dictionary.keys where key != "Desktop" && key != "Idle" {
                if let nested = dictionary[key] {
                    dictionary[key] = restoreAuraFlowIdleModes(in: nested)
                }
            }
            return dictionary
        }
        if let array = value as? [Any] {
            return array.map { restoreAuraFlowIdleModes(in: $0) }
        }
        return value
    }

    private func auraFlowScreenSaverMode() -> [String: Any] {
        let configuration: [String: Any] = [
            "module": [
                "relative": destinationURL.standardizedFileURL.absoluteString,
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
            "LastSet": Date(),
            "LastUse": Date(),
            "Content": [
                "Choices": [[
                    "Provider": "com.apple.wallpaper.choice.screen-saver",
                    "Files": [],
                    "Configuration": configurationData,
                ]],
                "Shuffle": "$null",
                "EncodedOptionValues": "$null",
            ],
        ]
    }

    private func defaultScreenSaverMode() -> [String: Any] {
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
            "LastSet": Date(),
            "LastUse": Date(),
            "Content": [
                "Choices": [[
                    "Provider": "com.apple.wallpaper.choice.screen-saver",
                    "Files": [],
                    "Configuration": configurationData,
                ]],
                "Shuffle": "$null",
                "EncodedOptionValues": "$null",
            ],
        ]
    }

    private func containsAuraFlowReference(_ value: Any) -> Bool {
        if let string = value as? String {
            return string.localizedCaseInsensitiveContains("AuraFlow")
        }
        if let data = value as? Data,
           let propertyList = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ) {
            return containsAuraFlowReference(propertyList)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.contains {
                containsAuraFlowReference($0.key)
                    || containsAuraFlowReference($0.value)
            }
        }
        if let array = value as? [Any] {
            return array.contains(where: containsAuraFlowReference)
        }
        return false
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
            backupURL: resolvedBackupURL,
            wallpaperStoreURL: fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/com.apple.wallpaper/Store/Index.plist"
                )
        )
    }

    var isInstalled: Bool {
        fileManager.fileExists(atPath: destinationURL.path)
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
        var trashedURL: NSURL?
        try fileManager.trashItem(
            at: destinationURL,
            resultingItemURL: &trashedURL
        )
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
