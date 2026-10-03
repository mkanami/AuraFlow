import Foundation

public struct WallpaperEngineLocalSnapshot: Sendable {
    public var candidates: [WallpaperEngineCandidate] = []
    public var warnings: [String] = []
    public var collectionDirectories: [URL] = []
    public init() {}
}

/// Lightweight, read-only catalog. Assets are copied only when the user previews a project.
public enum WallpaperEngineLocalLibrary {
    public static func scan(steamRoots: [URL], additionalDirectories: [URL] = [],
                            confirmedCollection: URL? = nil,
                            excludedDirectories: [URL] = [WallpaperEngineLibrary.defaultRoot],
                            cancelled: () -> Bool = { false }) -> WallpaperEngineLocalSnapshot {
        let manager = FileManager.default
        let reader = WallpaperEngineLibrary()
        var result = WallpaperEngineLocalSnapshot()
        let locations = WallpaperEngineLibraryLocations.resolve(steamRoots: steamRoots,
            additionalDirectories: additionalDirectories, confirmedCollection: confirmedCollection,
            excludedDirectories: excludedDirectories, cancelled: cancelled)
        result.collectionDirectories = locations.collections.map(\.url)
        result.warnings = locations.warnings
        let excluded = excludedDirectories.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        var seenDirectories = Set<String>(), seenProjects = Set<String>()

        func scanDirectory(_ directory: URL, nestedCollections: Bool = false) {
            guard !cancelled() else { return }
            let root = directory.standardizedFileURL.resolvingSymlinksInPath()
            guard !excluded.contains(where: { root.path == $0 || root.path.hasPrefix($0 + "/") }) else { return }
            guard seenDirectories.insert(root.path).inserted else { return }
            do {
                let attributes = try root.resourceValues(forKeys: [.isDirectoryKey])
                guard attributes.isDirectory == true else { return }
                if manager.fileExists(atPath: root.appendingPathComponent("project.json").path) {
                    for candidate in try reader.candidates(at: root) where seenProjects.insert(candidate.id).inserted {
                        result.candidates.append(candidate)
                    }
                    return
                }
                let children = try manager.contentsOfDirectory(at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
                for child in children.sorted(by: { $0.path < $1.path }) {
                    guard !cancelled() else { return }
                    // Don't traverse project links or arbitrary hierarchies. Library-root aliases are fine.
                    guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                        result.warnings.append("Cannot read \(child.lastPathComponent).")
                        continue
                    }
                    guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    if nestedCollections || manager.fileExists(atPath: child.appendingPathComponent("project.json").path) {
                        scanDirectory(child)
                    }
                }
            } catch {
                let code = (error as NSError).code
                if (error as NSError).domain == NSCocoaErrorDomain,
                   [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(code) { return }
                result.warnings.append("Cannot read \(root.lastPathComponent): \(error.localizedDescription)")
            }
        }

        for collection in locations.collections {
            guard !cancelled() else { return WallpaperEngineLocalSnapshot() }
            scanDirectory(collection.url, nestedCollections: collection.nestedCollections)
        }
        guard !cancelled() else { return WallpaperEngineLocalSnapshot() }
        result.candidates.sort {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return result
    }
}
