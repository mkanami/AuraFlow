import AuraTerminalWallpaperCore
import Foundation

/// Only stable, reviewed catalog IDs are saved. Paths and install commands are
/// always resolved again, never trusted from a writable library file.
actor TerminalAnimationLibraryStore {
    private struct Record: Codable {
        var version = 1
        var animationIDs: [String]
    }
    private let url: URL?
    private var ids: [String]?

    init(url: URL? = nil) { self.url = url }

    static var defaultURL: URL {
        TerminalWallpaperRuntimeStore.defaultAppSupportURL().appendingPathComponent("animation-library.json")
    }

    func load() throws -> [String] {
        if let ids { return ids }
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            ids = []; return []
        }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        var seen = Set<String>()
        let loaded = record.animationIDs.filter {
            TerminalWallpaperPreset.preset(id: $0) != nil && seen.insert($0).inserted
        }
        ids = loaded
        return loaded
    }

    func add(_ id: String) throws -> [String] {
        guard TerminalWallpaperPreset.preset(id: id) != nil else {
            throw TerminalWallpaperInstallError.invalidPreset
        }
        var updated = try load()
        guard !updated.contains(id) else { return updated }
        updated.append(id)
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Record(animationIDs: updated)).write(to: url, options: .atomic)
        }
        ids = updated
        return updated
    }

    func remove(_ id: String) throws -> [String] {
        let updated = try load().filter { $0 != id }
        if let url {
            try JSONEncoder().encode(Record(animationIDs: updated)).write(to: url, options: .atomic)
        }
        ids = updated
        return updated
    }
}
