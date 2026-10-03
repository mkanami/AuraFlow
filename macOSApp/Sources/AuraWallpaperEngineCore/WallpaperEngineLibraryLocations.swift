import Foundation

public struct WallpaperEngineCollectionLocation: Equatable, Sendable {
    public let url: URL
    public let nestedCollections: Bool
}

public struct WallpaperEngineLibraryLocations: Sendable {
    public private(set) var collections: [WallpaperEngineCollectionLocation] = []
    public private(set) var warnings: [String] = []

    /// Shared by the read-only catalog and both native file panels. No whole-disk traversal.
    public static func resolve(steamRoots: [URL], additionalDirectories: [URL] = [],
                               confirmedCollection: URL? = nil,
                               excludedDirectories: [URL] = [WallpaperEngineLibrary.defaultRoot],
                               fileManager: FileManager = .default,
                               cancelled: () -> Bool = { false }) -> Self {
        var result = Self()
        var seen = Set<String>()
        let excluded = excludedDirectories.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        func isExcluded(_ url: URL) -> Bool {
            excluded.contains { url.path == $0 || url.path.hasPrefix($0 + "/") }
        }
        func add(_ directory: URL, nested: Bool, knownCollection: Bool) {
            guard !cancelled() else { return }
            let root = directory.standardizedFileURL.resolvingSymlinksInPath()
            guard !isExcluded(root), !seen.contains(root.path) else { return }
            do {
                guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return }
                let children = try fileManager.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                guard fileManager.isReadableFile(atPath: root.path) else {
                    result.warnings.append("Cannot read library folder: \(root.path)"); return
                }
                if !knownCollection {
                    func hasProject(_ url: URL) -> Bool {
                        !isExcluded(url.standardizedFileURL.resolvingSymlinksInPath())
                            && fileManager.fileExists(atPath: url.appendingPathComponent("project.json").path)
                    }
                    var containsProject = hasProject(root)
                    for child in children where !containsProject && !cancelled() {
                        guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                              values.isDirectory == true, values.isSymbolicLink != true, !isExcluded(child) else { continue }
                        containsProject = hasProject(child)
                        if !containsProject, let grandchildren = try? fileManager.contentsOfDirectory(at: child,
                            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                            containsProject = grandchildren.contains { grandchild in
                                guard let values = try? grandchild.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                                      values.isDirectory == true, values.isSymbolicLink != true else { return false }
                                return hasProject(grandchild)
                            }
                        }
                    }
                    guard containsProject else { return }
                }
                seen.insert(root.path)
                result.collections.append(WallpaperEngineCollectionLocation(url: root, nestedCollections: nested))
            } catch {
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain,
                   [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return }
                result.warnings.append("Cannot read \(root.path): \(error.localizedDescription)")
            }
        }
        let additionalSteamRoots = additionalDirectories.map {
            $0.lastPathComponent.lowercased() == "steamapps" ? $0.deletingLastPathComponent() : $0
        }
        for steam in WallpaperEngineImportLocation.steamLibraries(steamRoots: steamRoots + additionalSteamRoots,
                                                                   fileManager: fileManager) {
            guard !cancelled() else { return Self() }
            add(steam.appendingPathComponent("steamapps/workshop/content/431960"), nested: false, knownCollection: true)
            let common = steam.appendingPathComponent("steamapps/common")
            let manifest = steam.appendingPathComponent("steamapps/appmanifest_431960.acf")
            let installDirectory: String?
            if let size = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
               let text = try? String(contentsOf: manifest, encoding: .utf8) {
                installDirectory = WallpaperEngineImportLocation.installationDirectory(in: text)
            } else { installDirectory = nil }
            // The conventional folder remains a compatibility fallback for copied/offline installs.
            for name in Set([installDirectory, "wallpaper_engine"].compactMap { $0 }).sorted() {
                add(common.appendingPathComponent(name).appendingPathComponent("projects"), nested: true, knownCollection: true)
            }
        }
        for directory in additionalDirectories {
            let name = directory.lastPathComponent.lowercased()
            let confirmed = confirmedCollection?.standardizedFileURL.resolvingSymlinksInPath() == directory.standardizedFileURL.resolvingSymlinksInPath()
                && name != "steamapps" && !fileManager.fileExists(atPath: directory.appendingPathComponent("steamapps").path)
            // Previously connected empty Workshop/project collections are still valid locations.
            add(directory, nested: true, knownCollection: confirmed || name == "431960" || name == "projects")
        }
        return cancelled() ? Self() : result
    }

    public static func preferredDirectory(in locations: Self, lastDirectory: URL?) -> URL? {
        if let last = lastDirectory?.standardizedFileURL.resolvingSymlinksInPath(),
           locations.collections.contains(where: { $0.url == last }) { return last }
        return locations.collections.count == 1 ? locations.collections.first?.url : nil
    }

    public static func isAccessibleDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              fileManager.isReadableFile(atPath: url.path) else { return false }
        return (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) != nil
    }
}
