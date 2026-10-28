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
    func restoreCurrentDesktopIfOwned() throws
}

extension TerminalScreenSaverStoreCoordinating {
    func restoreCurrentDesktopIfOwned() throws { try restoreIfOwned() }
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
        try routeRecovery.withExclusiveAccess { try activateLocked() }
    }

    private var routeRecovery: ScreenSaverRouteRecovery {
        ScreenSaverRouteRecovery(storeURL: storeURL, journalURL: journalURL, saverURL: saverURL)
    }

    private func activateLocked() throws {
        let existingJournal = try loadJournal()
        // Validate the store before interrupting WallpaperAgent, but do not
        // return early when our saver is already selected. Like the regular
        // wallpaper Start path, every real activation must re-arm the system
        // agent because it can keep a stale secure-surface provider in memory.
        _ = try activationPlan(from: readStore(), journal: existingJournal)
        try withStoppedWallpaperAgent {
            // WallpaperAgent may rewrite Index.plist while exiting. Build the
            // new Idle choice from the *post-exit* store, not the stale copy.
            let original = try readStore()
            guard let (updated, journal) = try activationPlan(from: original, journal: existingJournal) else {
                // The desired route is already present. The deliberate stop /
                // start above is still required to refresh WallpaperAgent.
                return
            }
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
        try restoreIfOwned(preferCurrentDesktop: false)
    }

    func restoreCurrentDesktopIfOwned() throws {
        try restoreIfOwned(preferCurrentDesktop: true)
    }

    private func restoreIfOwned(preferCurrentDesktop: Bool) throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        try routeRecovery.withExclusiveAccess { try restoreLocked(preferCurrentDesktop: preferCurrentDesktop) }
    }

    private func restoreLocked(preferCurrentDesktop: Bool) throws {
        guard let journal = try loadJournal() else { return }
        guard try restorePlan(from: readStore(), journal: journal, preferCurrentDesktop: preferCurrentDesktop) != nil else {
            try FileManager.default.removeItem(at: journalURL)
            try? FileManager.default.removeItem(at: journalURL.appendingPathExtension("suspended"))
            return
        }
        try withStoppedWallpaperAgent {
            let original = try readStore()
            if let updated = try restorePlan(from: original, journal: journal, preferCurrentDesktop: preferCurrentDesktop) {
                guard try readStore() == original else { throw StoreError.changedDuringUpdate }
                try updated.write(to: storeURL, options: .atomic)
            }
        }
        try FileManager.default.removeItem(at: journalURL)
        try? FileManager.default.removeItem(at: journalURL.appendingPathExtension("suspended"))
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

    private func restorePlan(from original: Data, journal: Journal, preferCurrentDesktop: Bool) throws -> Data? {
        var root = try dictionary(original)
        var changed = false
        root = mapContainers(in: root) { path, container in
            guard isSelected(container["Idle"]), container["Linked"] == nil else { return container }
            var result = container
            if preferCurrentDesktop, let desktop = result["Desktop"] {
                result["Idle"] = desktop
                result["Type"] = "individual"
                changed = true
                return result
            }
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
        } catch {
            try? startWallpaperAgent()
            throw error
        }
        try startWallpaperAgent()
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
        let oldPIDs = wallpaperAgentPIDs()
        let oldSaverPIDs = legacyScreenSaverPIDs()
        // WallpaperAgent can be relaunched by macOS while Index.plist is being
        // updated. Stop that generation too before asking it to read the new
        // Screen Saver route.
        if stopOnly || !oldPIDs.isEmpty {
            runProcess(
                "/usr/bin/killall",
                [WallpaperPlatformConstants.wallpaperAgentProcessName]
            )
            guard waitForProcessesToExit(oldPIDs, timeout: 2) else {
                throw StoreError.wallpaperAgentUnavailable
            }
        }
        // This route is hosted by the legacy Screen Saver extension. A live
        // extension can retain the previous module even after WallpaperAgent
        // has reread its store, so drain it before the next owner starts.
        if !oldSaverPIDs.isEmpty {
            runProcess("/usr/bin/pkill", ["-x", "legacyScreenSaver"])
            guard waitForProcessesToExit(oldSaverPIDs, timeout: 2) else {
                throw StoreError.wallpaperAgentUnavailable
            }
        }
        guard !stopOnly else { return }

        // `open` hands the request to Launch Services. Its exit code does not
        // tell us whether WallpaperAgent actually started; the new PID does.
        runProcess(
            "/usr/bin/open",
            ["-gja", WallpaperPlatformConstants.wallpaperAgentApplicationPath]
        )
        guard waitForFreshWallpaperAgent(excluding: oldPIDs) else {
            throw StoreError.wallpaperAgentUnavailable
        }
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { process.terminate() }
    }

    private static func waitForProcessesToExit(_ processIDs: Set<pid_t>, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while processIDs.contains(where: { kill($0, 0) == 0 || errno == EPERM }) {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }

    static func waitForFreshWallpaperAgent(
        excluding oldPIDs: Set<pid_t>,
        timeout: TimeInterval = 5,
        processIDs: () -> Set<pid_t> = wallpaperAgentPIDs,
        sleep: (TimeInterval) -> Void = Thread.sleep
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let currentPIDs = processIDs()
            if !currentPIDs.isEmpty && currentPIDs.isDisjoint(with: oldPIDs) {
                return true
            }
            sleep(0.1)
        } while Date() < deadline
        return false
    }

    private static func wallpaperAgentPIDs() -> Set<pid_t> {
        processIdentifiers(named: WallpaperPlatformConstants.wallpaperAgentProcessName)
    }

    private static func legacyScreenSaverPIDs() -> Set<pid_t> {
        processIdentifiers(named: "legacyScreenSaver")
    }

    private static func processIdentifiers(named name: String) -> Set<pid_t> {
        // Match the working Lock Screen re-arm: enumerate process paths
        // directly instead of launching pgrep during a system handoff.
        let bufferSize = proc_listallpids(nil, 0)
        guard bufferSize > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bufferSize) / MemoryLayout<pid_t>.stride)
        let bytesUsed = proc_listallpids(&pids, bufferSize)
        guard bytesUsed > 0 else { return [] }

        var matches = Set<pid_t>()
        let count = min(Int(bytesUsed) / MemoryLayout<pid_t>.stride, pids.count)
        for pid in pids.prefix(count) where pid > 0 {
            var path = [Int8](repeating: 0, count: 4_096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            if URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).lastPathComponent
                == name {
                matches.insert(pid)
            }
        }
        return matches
    }
}
