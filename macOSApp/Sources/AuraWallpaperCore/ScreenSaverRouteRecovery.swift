import Foundation
import Darwin

/// Repairs a system fallback that replaced one of Aura's split Idle routes.
/// A remaining Aura route and the installation journal are both required;
/// unrelated user choices and every Desktop route are left intact.
public final class ScreenSaverRouteRecovery {
    private struct SavedRoute: Decodable {
        let path: String
        let idle: Data?
    }
    private struct Journal: Decodable { let routes: [SavedRoute] }
    private struct SuspendedRoute: Codable {
        let path: String
        let auraIdle: Data
        let fallbackIdle: Data
    }
    private var suspensionURL: URL { journalURL.appendingPathExtension("suspended") }
    private let storeURL: URL
    private let journalURL: URL
    private let saverURL: URL

    public init(storeURL: URL = WallpaperPlatformConstants.wallpaperStoreURL(homeURL: FileManager.default.homeDirectoryForCurrentUser),
                journalURL: URL, saverURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/AuraFlowLockScreen.saver")) {
        self.storeURL = storeURL
        self.journalURL = journalURL
        self.saverURL = saverURL
    }

    /// Shared with activation/removal in the app, so a helper cannot race
    /// Remove and write its repaired Idle route over the user's restoration.
    public func withExclusiveAccess<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(journalURL.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    @discardableResult
    public func recoverIfNeeded(shouldProceed: () -> Bool = { true }) throws -> Bool {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return false }
        return try withExclusiveAccess { try recoverLocked(shouldProceed: shouldProceed) }
    }

    private func recoverLocked(shouldProceed: () -> Bool) throws -> Bool {
        guard shouldProceed(), FileManager.default.fileExists(atPath: journalURL.path) else { return false }
        if FileManager.default.fileExists(atPath: suspensionURL.path) {
            let original = try Data(contentsOf: storeURL)
            let suspended = try JSONDecoder().decode([SuspendedRoute].self, from: Data(contentsOf: suspensionURL))
            guard let root = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any] else { return false }
            var changed = false
            let resumed = mapRoutes(root) { path, route in
                guard route["Linked"] == nil, let saved = suspended.first(where: { $0.path == path }),
                      let fallback = try? PropertyListSerialization.propertyList(from: saved.fallbackIdle, format: nil),
                      self.sameChoice(route["Idle"], fallback),
                      let aura = try? PropertyListSerialization.propertyList(from: saved.auraIdle, format: nil)
                else { return route }
                var updated = route
                updated["Idle"] = aura
                changed = true
                return updated
            }
            guard shouldProceed(), (try? Data(contentsOf: storeURL)) == original else { return false }
            if changed {
                try PropertyListSerialization.data(fromPropertyList: resumed, format: .binary, options: 0)
                    .write(to: storeURL, options: .atomic)
            }
            try FileManager.default.removeItem(at: suspensionURL)
            // A manual change made while Aura was inactive must not be treated
            // as drift and undone by the ordinary repair path in this pass.
            return changed
        }
        let journalData = try Data(contentsOf: journalURL)
        let original = try Data(contentsOf: storeURL)
        guard let updated = try repairedStore(original, journalData: journalData) else { return false }
        // Stop/OFF removes ownership; an intervening system write must be
        // reconsidered on the next pass rather than overwritten with a stale plan.
        guard shouldProceed(), (try? Data(contentsOf: journalURL)) == journalData,
              (try? Data(contentsOf: storeURL)) == original else { return false }
        try updated.write(to: storeURL, options: .atomic)
        return true
    }

    /// Restores each display/Space's actual Desktop provider while no Aura
    /// runtime owns the saver. Retain the install journal so a delayed login
    /// helper can resume its route without taking a new backup of our fallback.
    @discardableResult
    public func suspendIfNeeded(shouldProceed: () -> Bool) throws -> Bool {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return false }
        return try withExclusiveAccess {
            guard shouldProceed(), FileManager.default.fileExists(atPath: journalURL.path) else { return false }
            let original = try Data(contentsOf: storeURL)
            guard let root = try PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any] else { return false }
            var fallbackDesktop: Any?
            _ = mapRoutes(root) { _, route in
                if fallbackDesktop == nil,
                   let desktop = route["Desktop"] ?? route["Linked"], self.isUserDesktop(desktop) {
                    fallbackDesktop = desktop
                }
                return route
            }
            var suspended = (try? Data(contentsOf: suspensionURL)).flatMap {
                try? JSONDecoder().decode([SuspendedRoute].self, from: $0)
            } ?? []
            var changed = false
            let updated = mapRoutes(root) { path, route in
                guard route["Linked"] == nil, self.isAura(route["Idle"]),
                      let idle = route["Idle"], let desktop = route["Desktop"] ?? fallbackDesktop,
                      self.isUserDesktop(desktop),
                      let auraData = try? PropertyListSerialization.data(fromPropertyList: idle, format: .binary, options: 0),
                      let fallbackData = try? PropertyListSerialization.data(fromPropertyList: desktop, format: .binary, options: 0)
                else { return route }
                suspended.removeAll { $0.path == path }
                suspended.append(SuspendedRoute(path: path, auraIdle: auraData, fallbackIdle: fallbackData))
                changed = true
                var result = route
                result["Idle"] = desktop
                return result
            }
            guard changed, shouldProceed(), (try? Data(contentsOf: storeURL)) == original else { return false }
            try JSONEncoder().encode(suspended).write(to: suspensionURL, options: .atomic)
            guard shouldProceed(), (try? Data(contentsOf: storeURL)) == original else { return false }
            try PropertyListSerialization.data(fromPropertyList: updated, format: .binary, options: 0)
                .write(to: storeURL, options: .atomic)
            return true
        }
    }

    public func repairedStore(_ data: Data, journalData: Data) throws -> Data? {
        guard var root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let journal = try JSONDecoder().decode(Journal.self, from: journalData)
        if let global = root["AllSpacesAndDisplays"] as? [String: Any], !isAura(global["Idle"]) { return nil }
        var selected: [String: Any]?
        root = mapRoutes(root) { _, route in
            if selected == nil, self.isAura(route["Idle"]), route["Linked"] == nil {
                selected = route["Idle"] as? [String: Any]
            }
            return route
        }
        guard let selected else { return nil }
        var changed = false
        root = mapRoutes(root) { path, route in
            guard route["Linked"] == nil, !self.isAura(route["Idle"]),
                  let saved = journal.routes.first(where: { $0.path == path }) else { return route }
            let savedIdle = saved.idle.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
            // WallpaperAgent can restore the saved choice or its built-in
            // Ventura fallback on display/session reconstruction. A different
            // explicit choice is not evidence of system drift.
            guard self.sameChoice(route["Idle"], savedIdle) || self.isSystemFallback(route["Idle"]) else { return route }
            var updated = route
            var restored = selected
            restored["LastSet"] = Date()
            restored["LastUse"] = Date()
            updated["Idle"] = restored
            changed = true
            return updated
        }
        return changed ? try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0) : nil
    }

    private func choice(_ mode: Any?) -> [String: Any]? {
        let content = (mode as? [String: Any])?["Content"] as? [String: Any]
        return (content?["Choices"] as? [[String: Any]])?.first
    }
    private func isAura(_ mode: Any?) -> Bool {
        guard let choice = choice(mode), choice["Provider"] as? String == WallpaperPlatformConstants.screenSaverProviderID,
              let data = choice["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let module = configuration["module"] as? [String: Any], let relative = module["relative"] as? String,
              let url = URL(string: relative) else { return false }
        return url.standardizedFileURL.path == saverURL.standardizedFileURL.path
    }
    private func isSystemFallback(_ mode: Any?) -> Bool {
        guard let choice = choice(mode), choice["Provider"] as? String == WallpaperPlatformConstants.screenSaverProviderID,
              let data = choice["Configuration"] as? Data,
              let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let module = configuration["module"] as? [String: Any], let relative = module["relative"] as? String,
              let url = URL(string: relative) else { return false }
        return url.standardizedFileURL.path == WallpaperPlatformConstants.fallbackScreenSaverPath
    }
    private func sameChoice(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let left = (lhs as? [String: Any])?["Content"] as? [String: Any],
              let right = (rhs as? [String: Any])?["Content"] as? [String: Any]
        else { return lhs == nil && rhs == nil }
        return (left as NSDictionary).isEqual(to: right)
    }

    private func isUserDesktop(_ mode: Any) -> Bool {
        !isAura(mode) && WallpaperDesktopSupport.isUserWallpaperMode(mode)
    }
    private func mapRoutes(_ root: [String: Any], transform: (String, [String: Any]) -> [String: Any]) -> [String: Any] {
        var result = root
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            if let route = result[key] as? [String: Any] { result[key] = transform(key, route) }
        }
        if var displays = result["Displays"] as? [String: Any] {
            for (id, route) in displays {
                if let route = route as? [String: Any] { displays[id] = transform("Displays.\(id)", route) }
            }
            result["Displays"] = displays
        }
        if var spaces = result["Spaces"] as? [String: Any] {
            for (id, space) in spaces {
                guard var space = space as? [String: Any] else { continue }
                if let route = space["Default"] as? [String: Any] { space["Default"] = transform("Spaces.\(id).Default", route) }
                if var displays = space["Displays"] as? [String: Any] {
                    for (display, route) in displays {
                        if let route = route as? [String: Any] { displays[display] = transform("Spaces.\(id).Displays.\(display)", route) }
                    }
                    space["Displays"] = displays
                }
                spaces[id] = space
            }
            result["Spaces"] = spaces
        }
        return result
    }
}
