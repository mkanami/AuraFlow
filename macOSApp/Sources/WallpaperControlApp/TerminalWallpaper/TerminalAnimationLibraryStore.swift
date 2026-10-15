import AuraTerminalWallpaperCore
import Foundation

/// Version 1 IDs stay readable. Version 2 also stores validated program
/// descriptors; availability and package identities are checked again on use.
actor TerminalAnimationLibraryStore {
    private struct Record: Codable {
        var version = 2
        var animationIDs: [String]
        var programs: [TerminalWallpaperPreset]? = nil
    }
    private let url: URL?
    private var ids: [String]?
    private var programs: [TerminalWallpaperPreset] = []

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
        guard record.version == 1 || record.version == 2 else { throw CocoaError(.coderReadCorrupt) }
        programs = (record.programs ?? []).filter { $0.isValid && !$0.isReviewedAnimation }
            .map { $0.program?.name == "lolcat" ? $0.program!.preset : $0 }
        var seen = Set<String>()
        let loaded = record.animationIDs.filter { id in
            (TerminalWallpaperPreset.preset(id: id) != nil || programs.contains(where: { $0.id == id })) && seen.insert(id).inserted
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
            try JSONEncoder().encode(Record(animationIDs: updated, programs: programs)).write(to: url, options: .atomic)
        }
        ids = updated
        return updated
    }

    func remove(_ id: String) throws -> [String] {
        let updated = try load().filter { $0 != id }
        if let url {
            try JSONEncoder().encode(Record(animationIDs: updated, programs: programs.filter { $0.id != id })).write(to: url, options: .atomic)
        }
        ids = updated
        programs.removeAll { $0.id == id }
        return updated
    }

    func loadPrograms() throws -> [TerminalWallpaperPreset] {
        _ = try load()
        return programs
    }

    func add(_ preset: TerminalWallpaperPreset) throws -> [String] {
        guard preset.isValid else { throw TerminalWallpaperInstallError.invalidPreset }
        if preset.isReviewedAnimation { return try add(preset.id) }
        var updated = try load()
        if !updated.contains(preset.id) { updated.append(preset.id) }
        let descriptors = programs.filter { $0.id != preset.id } + [preset]
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Record(animationIDs: updated, programs: descriptors)).write(to: url, options: .atomic)
        }
        ids = updated; programs = descriptors
        return updated
    }
}
