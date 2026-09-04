import Foundation

internal enum AerialWallpaperStoreScope: Equatable {
    case sharedWallpaper
    case lockScreenOnly

    var includesDesktop: Bool {
        self == .sharedWallpaper
    }
}

internal enum LockOnlySystemWallpaperURLUpdate {
    case preserve
    case set(String)
    case clear
}

internal struct LockOnlyRemovalStorePlan {
    var storeData: Data
    var desktopRoutes: [String: Data]
    var routeCount: Int
    var spaceRouteCount: Int
    var displayRouteCount: Int
    var systemWallpaperURLUpdate: LockOnlySystemWallpaperURLUpdate
}

/// Owns the plist transformations used by the modern Lock Screen installer.
///
/// The transaction deliberately does not write the live wallpaper store. The
/// installer remains responsible for the surrounding commit/rollback and
/// provider hand-off, while this type keeps store topology and route
/// semantics in one place.
internal final class WallpaperStoreTransaction {
    private let fileManager: FileManager
    private let wallpaperStoreURL: URL
    private let spacesPreferencesURL: URL
    private let aerialVideosURL: URL
    private let latestUserWallpaperStoreURL: URL?

    init(
        fileManager: FileManager = .default,
        wallpaperStoreURL: URL,
        spacesPreferencesURL: URL,
        aerialVideosURL: URL? = nil,
        latestUserWallpaperStoreURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.wallpaperStoreURL = wallpaperStoreURL
        self.spacesPreferencesURL = spacesPreferencesURL
        self.aerialVideosURL = aerialVideosURL
            ?? WallpaperPlatformConstants.wallpaperSupportURL(
                homeURL: fileManager.homeDirectoryForCurrentUser
            )
            .appendingPathComponent(
                WallpaperPlatformConstants.aerialVideosRelativePath,
                isDirectory: true
            )
        self.latestUserWallpaperStoreURL = latestUserWallpaperStoreURL
    }

    func propertyListDictionary(from data: Data) throws -> [String: Any]? {
        try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any]
    }

    func cleanedWallpaperStoreData(from data: Data) throws -> Data {
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
                   var displays = space["Displays"] as? [String: Any] {
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
        return try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
    }

    func aerialWallpaperStoreData(
        from data: Data,
        assetID: String,
        scope: AerialWallpaperStoreScope
    ) throws -> Data {
        guard var root = try propertyListDictionary(from: data) else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }
        let now = Date()
        let aerialMode = makeMode(
            provider: WallpaperPlatformConstants.aerialProviderID,
            configuration: ["assetID": assetID],
            date: now
        )
        root = mapWallpaperContainers(in: root) { container in
            var result = container
            if let linked = result["Linked"] as? [String: Any] {
                if scope.includesDesktop {
                    result["Linked"] = aerialMode
                    result["Type"] = "linked"
                } else {
                    // Split macOS's shared Linked route without changing the
                    // visible Desktop choice. WallpaperAgent can then prewarm
                    // Aura in Idle before loginwindow raises the lock shield.
                    result.removeValue(forKey: "Linked")
                    result["Desktop"] = linked
                    result["Idle"] = aerialMode
                    result["Type"] = "individual"
                }
                return result
            }
            if scope.includesDesktop, result["Desktop"] != nil {
                result["Desktop"] = aerialMode
            }
            if result["Idle"] != nil {
                result["Idle"] = aerialMode
            }
            if result["Desktop"] != nil || result["Idle"] != nil {
                result["Type"] = "individual"
            }
            return result
        }
        return try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
    }

    func currentDesktopRouteData(
        in root: [String: Any],
        managedAssetID: String
    ) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for (path, container) in wallpaperContainersWithPaths(in: root) {
            guard let route = currentUserDesktopRoute(
                in: container,
                managedAssetID: managedAssetID
            ) else {
                continue
            }
            guard let data = propertyListData(route.mode) else {
                throw AerialLockScreenInstallerError.malformedWallpaperStore
            }
            result[path + "." + route.key] = data
        }
        return result
    }

    func currentUserDesktopRoute(
        in container: [String: Any],
        managedAssetID: String
    ) -> (key: String, mode: [String: Any])? {
        func userMode(_ key: String) -> [String: Any]? {
            guard let mode = container[key] as? [String: Any],
                  !modeIsManaged(mode, assetID: managedAssetID)
            else {
                return nil
            }
            return mode
        }

        if (container["Type"] as? String) == "linked",
           let linked = userMode("Linked") {
            return ("Linked", linked)
        }
        if let desktop = userMode("Desktop") {
            return ("Desktop", desktop)
        }
        if let linked = userMode("Linked") {
            return ("Linked", linked)
        }
        return nil
    }

    func normalizedDesktopRoutesForComparison(
        _ routes: [String: Data]
    ) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: routes.map { key, data in
            let normalizedKey: String
            if key.hasSuffix(".Linked") {
                normalizedKey = String(key.dropLast(".Linked".count))
            } else if key.hasSuffix(".Desktop") {
                normalizedKey = String(key.dropLast(".Desktop".count))
            } else {
                normalizedKey = key
            }
            return (normalizedKey, data)
        })
    }

    func lockOnlyRemovalStorePlan(
        from currentStoreData: Data,
        managedAssetID: String
    ) throws -> LockOnlyRemovalStorePlan {
        guard let root = try propertyListDictionary(from: currentStoreData)
        else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }

        let desktopRoutes = try currentDesktopRouteData(
            in: root,
            managedAssetID: managedAssetID
        )
        guard !desktopRoutes.isEmpty else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }

        var invalidRoute = false
        var selectedModes: [[String: Any]] = []
        var routeCount = 0
        let updatedRoot = mapWallpaperContainers(in: root) { container in
            guard let route = currentUserDesktopRoute(
                in: container,
                managedAssetID: managedAssetID
            ) else {
                if containerContainsManagedWallpaper(
                    container,
                    managedAssetID: managedAssetID
                ) {
                    invalidRoute = true
                }
                return container
            }

            var updated = container
            selectedModes.append(route.mode)
            routeCount += 1
            switch route.key {
            case "Linked":
                // A user-selected Linked route already means Desktop and Lock
                // Screen are identical. Keep that descriptor byte-for-byte.
                if let idle = updated["Idle"] as? [String: Any],
                   modeIsManaged(idle, assetID: managedAssetID) {
                    updated.removeValue(forKey: "Idle")
                }
                if let desktop = updated["Desktop"] as? [String: Any],
                   modeIsManaged(desktop, assetID: managedAssetID) {
                    updated.removeValue(forKey: "Desktop")
                }
                updated["Type"] = "linked"
            default:
                // Desktop is the source of truth. Do not normalize, replace,
                // or timestamp it; copy it only into the ordinary Idle route.
                updated["Idle"] = route.mode
                if let linked = updated["Linked"] as? [String: Any],
                   modeIsManaged(linked, assetID: managedAssetID) {
                    updated.removeValue(forKey: "Linked")
                }
                updated["Type"] = "individual"
            }
            return updated
        }

        guard !invalidRoute, routeCount == desktopRoutes.count else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }
        let updatedData = try PropertyListSerialization.data(
            fromPropertyList: updatedRoot,
            format: .binary,
            options: 0
        )
        let updatedDesktopRoutes = try currentDesktopRouteData(
            in: updatedRoot,
            managedAssetID: managedAssetID
        )
        guard updatedDesktopRoutes == desktopRoutes else {
            throw AerialLockScreenInstallerError.wallpaperStoreUpdateFailed
        }

        return LockOnlyRemovalStorePlan(
            storeData: updatedData,
            desktopRoutes: desktopRoutes,
            routeCount: routeCount,
            spaceRouteCount: desktopRoutes.keys.filter {
                $0.hasPrefix("Spaces.")
            }.count,
            displayRouteCount: desktopRoutes.keys.filter {
                $0.hasPrefix("Displays.") || $0.contains(".Displays.")
            }.count,
            systemWallpaperURLUpdate: lockOnlySystemWallpaperURLUpdate(
                for: selectedModes.first
            )
        )
    }

    func lockOnlyRemovalStoreIsValid(
        _ storeData: Data,
        preserving expectedDesktopRoutes: [String: Data],
        managedAssetID: String
    ) -> Bool {
        guard let root = try? propertyListDictionary(from: storeData),
              let desktopRoutes = try? currentDesktopRouteData(
                in: root,
                managedAssetID: managedAssetID
              ),
              desktopRoutes == expectedDesktopRoutes
        else {
            return false
        }

        for (_, container) in wallpaperContainersWithPaths(in: root) {
            guard let route = currentUserDesktopRoute(
                in: container,
                managedAssetID: managedAssetID
            ) else {
                if containerContainsManagedWallpaper(
                    container,
                    managedAssetID: managedAssetID
                ) {
                    return false
                }
                continue
            }
            if route.key == "Linked" {
                if containerContainsManagedWallpaper(
                    container,
                    managedAssetID: managedAssetID
                ) {
                    return false
                }
                continue
            }
            guard let idle = container["Idle"] as? [String: Any],
                  !modeIsManaged(idle, assetID: managedAssetID),
                  propertyListData(idle) == propertyListData(route.mode)
            else {
                return false
            }
        }
        return true
    }

    func wallpaperStoreDataByPreservingUserDesktops(
        from latestData: Data,
        restoringManagedModesFrom originalData: Data,
        managedAssetID: String
    ) throws -> Data {
        guard var latest = try propertyListDictionary(from: latestData),
              let original = try propertyListDictionary(from: originalData)
        else {
            throw AerialLockScreenInstallerError.malformedWallpaperStore
        }
        let fallbackOriginal =
            original["AllSpacesAndDisplays"] as? [String: Any]
            ?? original["SystemDefault"] as? [String: Any]
            ?? [:]

        func isManaged(_ mode: [String: Any]) -> Bool {
            modeReferencesAuraFlow(mode)
                || modeFullySelectsAerial(
                    mode,
                    assetID: managedAssetID
                )
        }

        func newestMode(
            _ candidates: [[String: Any]]
        ) -> [String: Any]? {
            guard var newest = candidates.first else { return nil }
            func timestamp(_ mode: [String: Any]) -> Date {
                [mode["LastSet"], mode["LastUse"]]
                    .compactMap { $0 as? Date }
                    .max() ?? .distantPast
            }
            for candidate in candidates.dropFirst()
                where timestamp(candidate) > timestamp(newest) {
                newest = candidate
            }
            return newest
        }

        func cleanContainer(
            _ latestValue: Any?,
            original originalValue: Any?
        ) -> Any? {
            guard var result = latestValue as? [String: Any] else {
                return latestValue
            }
            let originalContainer = originalValue as? [String: Any]
                ?? fallbackOriginal
            let originalWasLinked = originalContainer["Linked"] != nil
                || (originalContainer["Type"] as? String) == "linked"

            // Lock-only installation splits a user's Linked route into
            // Desktop=user and Idle=Aura so WallpaperAgent can prewarm Aura.
            // On Remove, collapse that synthetic split back to Linked using
            // the latest user Desktop (not the stale pre-install choice).
            if originalWasLinked,
               let idle = result["Idle"] as? [String: Any],
               isManaged(idle) {
                let latestUserMode = newestMode([
                    result["Desktop"] as? [String: Any],
                    result["Linked"] as? [String: Any],
                    originalContainer["Linked"] as? [String: Any],
                ].compactMap { mode in
                    guard let mode, !isManaged(mode) else { return nil }
                    return mode
                })
                if let latestUserMode {
                    result.removeValue(forKey: "Desktop")
                    result.removeValue(forKey: "Idle")
                    result["Linked"] = normalizeImageModeFiles(latestUserMode)
                    result["Type"] = "linked"
                    return result
                }
            }
            if let desktop = result["Desktop"] as? [String: Any] {
                if isManaged(desktop),
                   let originalDesktop = originalContainer["Desktop"] {
                    result["Desktop"] = originalDesktop
                } else {
                    result["Desktop"] = normalizeImageModeFiles(desktop)
                }
            }
            if let linked = result["Linked"] as? [String: Any] {
                if isManaged(linked),
                   let originalLinked = originalContainer["Linked"] {
                    result["Linked"] = originalLinked
                } else {
                    result["Linked"] = normalizeImageModeFiles(linked)
                }
            }
            if let idle = result["Idle"] as? [String: Any],
               isManaged(idle) {
                if let originalIdle = originalContainer["Idle"] {
                    result["Idle"] = originalIdle
                } else {
                    result.removeValue(forKey: "Idle")
                }
            }
            return result
        }

        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            latest[key] = cleanContainer(latest[key], original: original[key])
        }

        if var latestDisplays = latest["Displays"] as? [String: Any] {
            let originalDisplays = original["Displays"] as? [String: Any]
                ?? [:]
            for (displayID, latestContainer) in latestDisplays {
                latestDisplays[displayID] = cleanContainer(
                    latestContainer,
                    original: originalDisplays[displayID]
                )
            }
            latest["Displays"] = latestDisplays
        }

        if var latestSpaces = latest["Spaces"] as? [String: Any] {
            let originalSpaces = original["Spaces"] as? [String: Any] ?? [:]
            for (spaceID, latestSpaceValue) in latestSpaces {
                guard var latestSpace = latestSpaceValue as? [String: Any]
                else { continue }
                let originalSpace = originalSpaces[spaceID]
                    as? [String: Any] ?? [:]
                latestSpace["Default"] = cleanContainer(
                    latestSpace["Default"],
                    original: originalSpace["Default"]
                )
                if var latestDisplays =
                    latestSpace["Displays"] as? [String: Any] {
                    let originalDisplays =
                        originalSpace["Displays"] as? [String: Any] ?? [:]
                    for (displayID, latestContainer) in latestDisplays {
                        latestDisplays[displayID] = cleanContainer(
                            latestContainer,
                            original: originalDisplays[displayID]
                        )
                    }
                    latestSpace["Displays"] = latestDisplays
                }
                latestSpaces[spaceID] = latestSpace
            }
            latest["Spaces"] = latestSpaces
        }

        return try PropertyListSerialization.data(
            fromPropertyList: latest,
            format: .binary,
            options: 0
        )
    }

    /// Captures the newest user-owned wallpaper topology independently from
    /// Aura's temporary Desktop/Idle routes. If a journal URL was supplied at
    /// initialization, it is read and updated with the same semantics used by
    /// the installer; otherwise the operation remains an in-memory transform.
    func captureLatestUserWallpaperStoreData(
        from currentData: Data,
        fallbackData: Data,
        managedAssetID: String
    ) throws -> Data {
        let previousData = latestUserWallpaperStoreURL.flatMap {
            try? Data(contentsOf: $0)
        } ?? fallbackData
        // Older journal revisions could retain Aura's temporary Idle route.
        // Sanitize the journal against the real pre-Aura store before using
        // it as a fallback, otherwise that managed Idle route survives every
        // later capture and Remove restores Aura instead of the user's latest
        // wallpaper on the Lock Screen.
        let sanitizedPreviousData = try
            wallpaperStoreDataByPreservingUserDesktops(
                from: previousData,
                restoringManagedModesFrom: fallbackData,
                managedAssetID: managedAssetID
            )
        let latestData = try wallpaperStoreDataByPreservingUserDesktops(
            from: currentData,
            restoringManagedModesFrom: sanitizedPreviousData,
            managedAssetID: managedAssetID
        )
        if let latestUserWallpaperStoreURL {
            try latestData.write(
                to: latestUserWallpaperStoreURL,
                options: .atomic
            )
        }
        return latestData
    }

    func wallpaperStoreHasUserDesktop(
        _ data: Data,
        managedAssetID: String
    ) -> Bool {
        guard let root = try? propertyListDictionary(from: data) else {
            return false
        }
        var foundUserDesktop = false
        _ = mapWallpaperContainers(in: root) { container in
            if let desktop = container["Desktop"] as? [String: Any],
               !modeReferencesAuraFlow(desktop),
               !modeFullySelectsAerial(
                    desktop,
                    assetID: managedAssetID
               ) {
                foundUserDesktop = true
            }
            if let linked = container["Linked"] as? [String: Any],
               !modeReferencesAuraFlow(linked),
               !modeFullySelectsAerial(
                    linked,
                    assetID: managedAssetID
               ) {
                foundUserDesktop = true
            }
            return container
        }
        return foundUserDesktop
    }

    func wallpaperStoreHasManagedDesktop(
        _ data: Data,
        managedAssetID: String
    ) -> Bool {
        guard let root = try? propertyListDictionary(from: data) else {
            return false
        }
        var foundManagedDesktop = false
        _ = mapWallpaperContainers(in: root) { container in
            if let desktop = container["Desktop"] as? [String: Any],
               modeReferencesAuraFlow(desktop)
                || modeFullySelectsAerial(
                    desktop,
                    assetID: managedAssetID
                ) {
                foundManagedDesktop = true
            }
            if let linked = container["Linked"] as? [String: Any],
               modeReferencesAuraFlow(linked)
                || modeFullySelectsAerial(
                    linked,
                    assetID: managedAssetID
                ) {
                foundManagedDesktop = true
            }
            return container
        }
        return foundManagedDesktop
    }

    func wallpaperStoreFullySelectsAerial(
        assetID: String,
        scope: AerialWallpaperStoreScope
    ) -> Bool {
        guard let data = try? Data(contentsOf: wallpaperStoreURL),
              let root = try? propertyListDictionary(from: data)
        else {
            return false
        }
        return wallpaperStoreFullySelectsAerial(
            in: root,
            assetID: assetID,
            scope: scope
        )
    }

    func wallpaperStoreFullySelectsAerial(
        in root: [String: Any],
        assetID: String,
        scope: AerialWallpaperStoreScope
    ) -> Bool {
        var containers: [[String: Any]] = []
        if let allSpacesAndDisplays =
            root["AllSpacesAndDisplays"] as? [String: Any] {
            containers.append(allSpacesAndDisplays)
        }
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
                if let displays = space["Displays"] as? [String: Any] {
                    containers.append(contentsOf: displays.values.compactMap {
                        $0 as? [String: Any]
                    })
                }
            }
        }

        var inspectedContainers = 0
        for container in containers {
            guard container["Linked"] != nil
                || container["Desktop"] != nil
                || container["Idle"] != nil
            else {
                continue
            }
            inspectedContainers += 1

            if scope.includesDesktop {
                if let linked = container["Linked"] as? [String: Any] {
                    guard modeFullySelectsAerial(
                        linked,
                        assetID: assetID
                    ) else { return false }
                } else {
                    guard let desktop = container["Desktop"] as? [String: Any],
                          let idle = container["Idle"] as? [String: Any],
                          modeFullySelectsAerial(
                              desktop,
                              assetID: assetID
                          ),
                          modeFullySelectsAerial(idle, assetID: assetID)
                    else { return false }
                }
            } else {
                // A lock-only installation must have an Aura Idle route and
                // must never leave Aura in Desktop or Linked.
                guard let idle = container["Idle"] as? [String: Any],
                      modeFullySelectsAerial(idle, assetID: assetID),
                      container["Linked"] == nil
                else { return false }
                if let desktop = container["Desktop"] as? [String: Any] {
                    guard !modeFullySelectsAerial(
                        desktop,
                        assetID: assetID
                    ) else { return false }
                }
            }
        }
        return inspectedContainers > 0
    }

    func wallpaperStoreContainsAuraInDesktop(
        _ root: [String: Any],
        assetID: String
    ) -> Bool {
        wallpaperContainersWithPaths(in: root).contains { _, container in
            if let linked = container["Linked"] as? [String: Any],
               modeFullySelectsAerial(linked, assetID: assetID) {
                return true
            }
            if let desktop = container["Desktop"] as? [String: Any],
               modeFullySelectsAerial(desktop, assetID: assetID) {
                return true
            }
            return false
        }
    }

    func wallpaperStoreSemanticallyMatches(
        currentData: Data,
        expectedData: Data
    ) -> Bool {
        guard let currentRoot = try? propertyListDictionary(from: currentData),
              let expectedRoot = try? propertyListDictionary(from: expectedData),
              let currentComparable = try? PropertyListSerialization.data(
                fromPropertyList: wallpaperStoreComparableValue(currentRoot),
                format: .xml,
                options: 0
              ),
              let expectedComparable = try? PropertyListSerialization.data(
                fromPropertyList: wallpaperStoreComparableValue(expectedRoot),
                format: .xml,
                options: 0
              )
        else {
            return false
        }
        return currentComparable == expectedComparable
    }

    func wallpaperStoreSemanticallyMatches(expectedData: Data) -> Bool {
        guard let currentData = try? Data(contentsOf: wallpaperStoreURL) else {
            return false
        }
        return wallpaperStoreSemanticallyMatches(
            currentData: currentData,
            expectedData: expectedData
        )
    }

    /// Resolves the fallback URL that WallpaperAgent uses in addition to
    /// Index.plist. On current macOS, changing a split Desktop route can update
    /// Index without updating SystemWallpaperURL; restarting WallpaperAgent
    /// would then visually resurrect the previous wallpaper.
    func latestUserSystemWallpaperURL(
        from storeData: Data,
        managedAssetID: String
    ) -> String? {
        guard let root = try? propertyListDictionary(from: storeData) else {
            return nil
        }
        var candidates: [(date: Date, url: String)] = []
        _ = mapWallpaperContainers(in: root) { container in
            for key in ["Linked", "Desktop"] {
                guard let mode = container[key] as? [String: Any],
                      !modeReferencesAuraFlow(mode),
                      !modeFullySelectsAerial(
                          mode,
                          assetID: managedAssetID
                      ),
                      let url = systemWallpaperURL(from: mode)
                else {
                    continue
                }
                let date = [mode["LastSet"], mode["LastUse"]]
                    .compactMap { $0 as? Date }
                    .max() ?? .distantPast
                candidates.append((date, url))
            }
            return container
        }
        return candidates.max { $0.date < $1.date }?.url
    }

    private func mapWallpaperContainers(
        in root: [String: Any],
        transform: ([String: Any]) -> [String: Any]
    ) -> [String: Any] {
        var result = root
        if let allSpacesAndDisplays =
            result["AllSpacesAndDisplays"] as? [String: Any] {
            result["AllSpacesAndDisplays"] = transform(allSpacesAndDisplays)
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
                if let displays = space["Displays"] as? [String: Any] {
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

    private func wallpaperContainersWithPaths(
        in root: [String: Any]
    ) -> [(String, [String: Any])] {
        var result: [(String, [String: Any])] = []
        func append(_ path: String, _ value: Any?) {
            if let container = value as? [String: Any] {
                result.append((path, container))
            }
        }

        append("AllSpacesAndDisplays", root["AllSpacesAndDisplays"])
        append("SystemDefault", root["SystemDefault"])
        if let displays = root["Displays"] as? [String: Any] {
            for displayID in displays.keys.sorted() {
                append("Displays.\(displayID)", displays[displayID])
            }
        }
        if let spaces = root["Spaces"] as? [String: Any] {
            for spaceID in spaces.keys.sorted() {
                guard let space = spaces[spaceID] as? [String: Any] else {
                    continue
                }
                append("Spaces.\(spaceID).Default", space["Default"])
                if let displays = space["Displays"] as? [String: Any] {
                    for displayID in displays.keys.sorted() {
                        append(
                            "Spaces.\(spaceID).Displays.\(displayID)",
                            displays[displayID]
                        )
                    }
                }
            }
        }
        return result
    }

    private func propertyListData(_ value: Any) -> Data? {
        try? PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
    }

    private func lockOnlySystemWallpaperURLUpdate(
        for mode: [String: Any]?
    ) -> LockOnlySystemWallpaperURLUpdate {
        guard let mode,
              let content = mode["Content"] as? [String: Any],
              let choice = (content["Choices"] as? [[String: Any]])?.first
        else {
            return .clear
        }
        if choice["Provider"] as? String == "default" {
            return .preserve
        }
        if let url = systemWallpaperURL(from: mode) {
            return .set(url)
        }
        // Explicit Apple providers such as Sequoia own their descriptor.
        // Keeping a stale file URL here can resurrect a previous Desktop.
        return .clear
    }

    private func containerContainsManagedWallpaper(
        _ container: [String: Any],
        managedAssetID: String
    ) -> Bool {
        for key in ["Linked", "Desktop", "Idle"] {
            if let mode = container[key] as? [String: Any],
               modeIsManaged(mode, assetID: managedAssetID) {
                return true
            }
        }
        return false
    }

    private func modeIsManaged(
        _ mode: [String: Any],
        assetID: String
    ) -> Bool {
        // Modern lock-only installation owns exactly the reserved Aerial
        // route recorded in its marker. A user's ordinary image can legally
        // live under AuraFlow/Restored Wallpapers; treating the directory
        // name itself as ownership makes a successful Remove look malformed.
        modeFullySelectsAerial(mode, assetID: assetID)
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
                    == WallpaperPlatformConstants.aerialProviderID,
                  let data = choice["Configuration"] as? Data,
                  let configuration =
                    try? propertyListDictionary(from: data)
            else {
                return false
            }
            return configuration["assetID"] as? String == assetID
        }
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
            ?? WallpaperPlatformConstants.fallbackDesktopImagePath
        return makeMode(
            provider: WallpaperPlatformConstants.imageProviderID,
            configuration: [
                "type": "imageFile",
                "url": [
                    "relative": URL(fileURLWithPath: wallpaperPath)
                        .absoluteString,
                ],
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
            provider: WallpaperPlatformConstants.screenSaverProviderID,
            configuration: [
                "module": [
                    "relative":
                        URL(fileURLWithPath:
                            WallpaperPlatformConstants.fallbackScreenSaverPath
                        ).absoluteString,
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
        if provider == WallpaperPlatformConstants.imageProviderID,
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
            guard choice["Provider"] as? String
                    == WallpaperPlatformConstants.imageProviderID,
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

    private func systemWallpaperURL(
        from mode: [String: Any]
    ) -> String? {
        guard let content = mode["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]]
        else {
            return nil
        }
        for choice in choices {
            let provider = choice["Provider"] as? String
            let configuration: [String: Any]? = {
                guard let data = choice["Configuration"] as? Data else {
                    return nil
                }
                return try? propertyListDictionary(from: data)
            }()
            if provider == WallpaperPlatformConstants.aerialProviderID,
               let assetID = configuration?["assetID"] as? String {
                return aerialVideosURL
                    .appendingPathComponent(assetID)
                    .appendingPathExtension("mov")
                    .standardizedFileURL.absoluteString
            }
            if let url = configuration?["url"] as? [String: Any],
               let relative = url["relative"] as? String,
               let normalized = normalizedWallpaperURLString(relative) {
                return normalized
            }
            if let files = choice["Files"] as? [[String: Any]] {
                for file in files {
                    if let relative = file["relative"] as? String,
                       let normalized = normalizedWallpaperURLString(relative) {
                        return normalized
                    }
                }
            }
        }
        return nil
    }

    private func normalizedWallpaperURLString(
        _ value: String
    ) -> String? {
        if let url = URL(string: value), url.isFileURL {
            return url.standardizedFileURL.absoluteString
        }
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.absoluteString
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
}
