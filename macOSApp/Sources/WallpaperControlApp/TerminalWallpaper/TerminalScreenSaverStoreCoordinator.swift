import AuraWallpaperCore
import AuraTerminalWallpaperCore
import Darwin
import Foundation

/// macOS 26+ selects the Lock Screen's Idle route from WallpaperAgent's store.
/// The legacy com.apple.screensaver moduleDict is still written for older macOS,
/// but changing it alone does not select the saver in modern System Settings.
protocol TerminalScreenSaverStoreCoordinating {
    func activate() throws
    func restoreIfOwned() throws
}

final class TerminalScreenSaverStoreCoordinator: TerminalScreenSaverStoreCoordinating {
    enum StoreError: LocalizedError {
        case unavailable
        case malformed
        case changedDuringUpdate
        case wallpaperAgentUnavailable

        var errorDescription: String? {
            switch self {
            case .unavailable: "The macOS Screen Saver store is unavailable."
            case .malformed: "The macOS Screen Saver store has an unknown format."
            case .changedDuringUpdate: "The macOS Screen Saver selection changed; try again."
            case .wallpaperAgentUnavailable: "macOS could not refresh the Screen Saver selection."
            }
        }
    }

    private struct SavedRoute: Codable {
        let path: String
        let type: String?
        let linked: Data?
        let idle: Data?
    }

    private struct Journal: Codable {
        let routes: [SavedRoute]
    }

    private let storeURL: URL
    private let journalURL: URL
    private let saverURL: URL
    private let stopWallpaperAgent: () throws -> Void
    private let startWallpaperAgent: () throws -> Void

    init(
        storeURL: URL = WallpaperPlatformConstants.wallpaperStoreURL(
            homeURL: FileManager.default.homeDirectoryForCurrentUser
        ),
        journalURL: URL = TerminalWallpaperRuntimeStore.defaultAppSupportURL()
            .appendingPathComponent("screen-saver-wallpaper-store-backup.json"),
        saverURL: URL,
        stopWallpaperAgent: @escaping () throws -> Void = {
            try TerminalScreenSaverStoreCoordinator.restartWallpaperAgent(stopOnly: true)
        },
        startWallpaperAgent: @escaping () throws -> Void = {
            try TerminalScreenSaverStoreCoordinator.restartWallpaperAgent(stopOnly: false)
        }
    ) {
        self.storeURL = storeURL
        self.journalURL = journalURL
        self.saverURL = saverURL
        self.stopWallpaperAgent = stopWallpaperAgent
        self.startWallpaperAgent = startWallpaperAgent
    }

    func activate() throws {
        let existingJournal = try loadJournal()
        guard try activationPlan(from: readStore(), journal: existingJournal) != nil else { return }
        try withStoppedWallpaperAgent {
            // WallpaperAgent may rewrite Index.plist while exiting. Build the
            // new Idle choice from the *post-exit* store, not the stale copy.
            let original = try readStore()
            guard let (updated, journal) = try activationPlan(
                from: original, journal: existingJournal
            ) else { return }
            try saveJournal(journal)
            do {
                guard try readStore() == original else { throw StoreError.changedDuringUpdate }
                try updated.write(to: storeURL, options: .atomic)
            } catch {
                if existingJournal == nil { try? FileManager.default.removeItem(at: journalURL) }
                throw error
            }
        }
    }

    func restoreIfOwned() throws {
        guard let journal = try loadJournal() else { return }
        guard try restorePlan(from: readStore(), journal: journal) != nil else {
            try FileManager.default.removeItem(at: journalURL)
            return
        }
        try withStoppedWallpaperAgent {
            let original = try readStore()
            if let updated = try restorePlan(from: original, journal: journal) {
                guard try readStore() == original else { throw StoreError.changedDuringUpdate }
                try updated.write(to: storeURL, options: .atomic)
            }
        }
        try FileManager.default.removeItem(at: journalURL)
    }

    private func activationPlan(
        from original: Data,
        journal: Journal?
    ) throws -> (Data, Journal)? {
        var root = try dictionary(original)
        var saved = journal?.routes ?? []
        let saverMode = try makeSaverMode()
        var changed = false
        root = mapContainers(in: root) { path, container in
            var result = container
            guard result["Linked"] != nil || result["Desktop"] != nil || result["Idle"] != nil else {
                return result
            }
            if isSelected(result["Idle"]), result["Linked"] == nil { return result }
            if !saved.contains(where: { $0.path == path }) {
                saved.append(SavedRoute(
                    path: path,
                    type: result["Type"] as? String,
                    linked: optionalPlistData(result["Linked"]),
                    idle: optionalPlistData(result["Idle"])
                ))
            }
            if let linked = result.removeValue(forKey: "Linked") {
                result["Desktop"] = linked
            }
            result["Idle"] = saverMode
            result["Type"] = "individual"
            changed = true
            return result
        }
        return changed ? (try encodedPlist(root), Journal(routes: saved)) : nil
    }

    private func restorePlan(from original: Data, journal: Journal) throws -> Data? {
        var root = try dictionary(original)
        var changed = false
        root = mapContainers(in: root) { path, container in
            guard isSelected(container["Idle"]), container["Linked"] == nil else { return container }
            var result = container
            if let saved = journal.routes.first(where: { $0.path == path }) {
                if let linked = propertyList(saved.linked) as? NSDictionary,
                   let desktop = result["Desktop"] as? NSDictionary,
                   desktop.isEqual(linked) {
                    result["Linked"] = linked
                    result.removeValue(forKey: "Desktop")
                    result.removeValue(forKey: "Idle")
                    if let type = saved.type { result["Type"] = type }
                } else if let idle = propertyList(saved.idle) {
                    result["Idle"] = idle
                } else {
                    result.removeValue(forKey: "Idle")
                }
            } else {
                // A display created during the session may inherit our Idle.
                // Removing it lets the system's default selection take over.
                result.removeValue(forKey: "Idle")
            }
            changed = true
            return result
        }
        return changed ? try encodedPlist(root) : nil
    }

    private func withStoppedWallpaperAgent(_ operation: () throws -> Void) throws {
        try stopWallpaperAgent()
        do {
            try operation()
            try startWallpaperAgent()
        } catch {
            try? startWallpaperAgent()
            throw error
        }
    }

    private func makeSaverMode() throws -> [String: Any] {
        let configuration = ["module": ["relative": canonicalModuleURL.absoluteString]]
        let data = try encodedPlist(configuration)
        let now = Date()
        return [
            "LastSet": now,
            "LastUse": now,
            "Content": [
                "Choices": [[
                    "Provider": WallpaperPlatformConstants.screenSaverProviderID,
                    "Files": [],
                    "Configuration": data,
                ]],
                "Shuffle": "$null",
                "EncodedOptionValues": "$null",
            ],
        ]
    }

    private func isSelected(_ mode: Any?) -> Bool {
        guard let mode = mode as? [String: Any],
              let content = mode["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first,
              choice["Provider"] as? String == WallpaperPlatformConstants.screenSaverProviderID,
              let data = choice["Configuration"] as? Data,
              let config = try? dictionary(data),
              let module = config["module"] as? [String: Any],
              let relative = module["relative"] as? String,
              let url = URL(string: relative) else { return false }
        return url.absoluteString == canonicalModuleURL.absoluteString
    }

    private var canonicalModuleURL: URL {
        // WallpaperAgent's screen-saver provider expects the bundle file URL
        // without a trailing slash; a directory URL loads but is not shown
        // as a selected saver in System Settings.
        URL(fileURLWithPath: saverURL.standardizedFileURL.path, isDirectory: false)
    }

    private func mapContainers(
        in root: [String: Any],
        transform: (String, [String: Any]) -> [String: Any]
    ) -> [String: Any] {
        var result = root
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            if let container = result[key] as? [String: Any] {
                result[key] = transform(key, container)
            }
        }
        if let displays = result["Displays"] as? [String: Any] {
            var updatedDisplays = displays
            for (displayID, value) in displays {
                guard let container = value as? [String: Any] else { continue }
                updatedDisplays[displayID] = transform("Displays.\(displayID)", container)
            }
            result["Displays"] = updatedDisplays
        }
        if let spaces = result["Spaces"] as? [String: Any] {
            var updatedSpaces = spaces
            for (spaceID, value) in spaces {
                guard var space = value as? [String: Any] else { continue }
                if let container = space["Default"] as? [String: Any] {
                    space["Default"] = transform("Spaces.\(spaceID).Default", container)
                }
                if let displays = space["Displays"] as? [String: Any] {
                    var updatedDisplays = displays
                    for (displayID, value) in displays {
                        guard let container = value as? [String: Any] else { continue }
                        updatedDisplays[displayID] = transform(
                            "Spaces.\(spaceID).Displays.\(displayID)", container
                        )
                    }
                    space["Displays"] = updatedDisplays
                }
                updatedSpaces[spaceID] = space
            }
            result["Spaces"] = updatedSpaces
        }
        return result
    }

    private func readStore() throws -> Data {
        guard let data = try? Data(contentsOf: storeURL) else { throw StoreError.unavailable }
        return data
    }

    private func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = value as? [String: Any] else { throw StoreError.malformed }
        return dictionary
    }

    private func optionalPlistData(_ value: Any?) -> Data? {
        guard let value else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private func encodedPlist(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private func propertyList(_ data: Data?) -> Any? {
        guard let data else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    private func loadJournal() throws -> Journal? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
    }

    private func saveJournal(_ journal: Journal) throws {
        try FileManager.default.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
    }

    private static func restartWallpaperAgent(stopOnly: Bool) throws {
        let oldPIDs = stopOnly ? wallpaperAgentPIDs() : []
        let process = Process()
        process.executableURL = URL(fileURLWithPath: stopOnly ? "/usr/bin/killall" : "/usr/bin/open")
        process.arguments = stopOnly
            ? [WallpaperPlatformConstants.wallpaperAgentProcessName]
            : ["-gja", WallpaperPlatformConstants.wallpaperAgentApplicationPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if stopOnly {
            let deadline = Date().addingTimeInterval(2)
            while oldPIDs.contains(where: { kill($0, 0) == 0 }) {
                guard Date() < deadline else { throw StoreError.wallpaperAgentUnavailable }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if !stopOnly && process.terminationStatus != 0 {
            throw StoreError.wallpaperAgentUnavailable
        }
    }

    private static func wallpaperAgentPIDs() -> [pid_t] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = [
            "-u", String(getuid()), "-x", WallpaperPlatformConstants.wallpaperAgentProcessName,
        ]
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0) } ?? []
    }
}
