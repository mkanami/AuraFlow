import CryptoKit
import Foundation

public enum WallpaperEngineType: String, Codable, Sendable {
    case video, web
}

public enum ProjectValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([ProjectValue]), object([String: ProjectValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([ProjectValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ProjectValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var object: [String: ProjectValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [ProjectValue]? { if case .array(let v) = self { return v }; return nil }
}

public struct WallpaperEngineProperty: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var definition: [String: ProjectValue]
    public var type: String { definition["type"]?.string ?? "unknown" }
    public var title: String { definition["text"]?.string ?? id }
    public var defaultValue: ProjectValue { definition["value"] ?? .null }
    public var editable: Bool { ["color", "slider", "bool", "combo", "textinput"].contains(type) }
    public var order: Double { definition["order"]?.number ?? 0 }
    public func validated(_ value: ProjectValue) -> ProjectValue {
        switch (type, value) {
        case ("slider", .number(let number)):
            let low = definition["min"]?.number ?? 0
            let high = max(low, definition["max"]?.number ?? 100)
            let clamped = min(max(number.isFinite ? number : low, low), high)
            return .number(definition["fraction"]?.bool == true ? clamped : min(max(clamped.rounded(), low), high))
        case ("bool", .bool), ("textinput", .string): return value
        case ("color", .string(let string)):
            let values = string.split(separator: " ").compactMap { Double($0) }
            return values.count == 3 && values.allSatisfy { $0.isFinite && (0...1).contains($0) } ? value : defaultValue
        case ("combo", _):
            return definition["options"]?.array?.contains(where: { $0.object?["value"] == value }) == true ? value : defaultValue
        default: return defaultValue
        }
    }
}

public struct WallpaperEngineProject: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var type: WallpaperEngineType
    public var title: String
    public var description: String
    public var rootPath: String
    public var entryPath: String
    public var previewPath: String?
    public var properties: [WallpaperEngineProperty]
    public var warnings: [String]
    public var importedAt: Date
    public var rootURL: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }
    public var entryURL: URL { rootURL.appendingPathComponent(entryPath) }
    public var previewURL: URL? { previewPath.map { rootURL.appendingPathComponent($0) } }
}

public struct WallpaperEngineCandidate: Identifiable, Sendable {
    public var id: String { url.path }
    public var url: URL
    public var title: String
    public var type: String
    public var error: String?
    public var supported: Bool { error == nil && ["video", "web"].contains(type) }
}

public enum WallpaperEngineError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public final class WallpaperEngineLibrary: @unchecked Sendable {
    public let rootURL: URL
    private let lock = NSRecursiveLock()
    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AuraFlow/wallpaper-engine")
    }
    public init(rootURL: URL = WallpaperEngineLibrary.defaultRoot) { self.rootURL = rootURL }
    public static let videoExtensions = ["mp4", "mov", "m4v", "webm", "mkv", "avi"]
    public static let webExtensions = ["html", "htm"]
    public func projects() -> [WallpaperEngineProject] {
        lock.lock(); defer { lock.unlock() }
        return (try? JSONDecoder().decode([WallpaperEngineProject].self, from: Data(contentsOf: rootURL.appendingPathComponent("library.json")))) ?? []
    }
    public func candidates(at url: URL) throws -> [WallpaperEngineCandidate] {
        let root = try projectRoot(for: url)
        let manager = FileManager.default
        let folders: [URL]
        if manager.fileExists(atPath: root.appendingPathComponent("project.json").path) { folders = [root] }
        else {
            folders = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                .filter { manager.fileExists(atPath: $0.appendingPathComponent("project.json").path) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard !folders.isEmpty else { throw WallpaperEngineError.invalid("No project.json found in this folder or its immediate subfolders.") }
        return folders.map { folder in
            do {
                let data = try metadata(folder)
                let type = data["type"]?.string?.lowercased() ?? "unknown"
                let title = data["title"]?.string ?? folder.lastPathComponent
                do { _ = try parse(folder); return .init(url: folder, title: title, type: type, error: nil) }
                catch { return .init(url: folder, title: title, type: type, error: error.localizedDescription) }
            } catch { return .init(url: folder, title: folder.lastPathComponent, type: "unknown", error: error.localizedDescription) }
        }
    }

    /// A user can select the wallpaper itself; metadata still defines its type and entry point.
    /// Only the nearest enclosing project is considered, never a sibling project or arbitrary MP4.
    private func projectRoot(for selection: URL) throws -> URL {
        let source = selection.standardizedFileURL
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        if values.isDirectory == true { return source.resolvingSymlinksInPath() }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw WallpaperEngineError.invalid("Choose a regular video file, web entry file, project folder, or project.json.")
        }
        if source.lastPathComponent.lowercased() == "project.json" {
            return source.deletingLastPathComponent().resolvingSymlinksInPath()
        }
        guard (Self.videoExtensions + Self.webExtensions).contains(source.pathExtension.lowercased()) else {
            throw WallpaperEngineError.invalid("Choose the wallpaper video, HTML entry file, project folder, or project.json.")
        }
        var folder = source.deletingLastPathComponent().resolvingSymlinksInPath()
        for _ in 0..<32 {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path) {
                let project = try parse(folder)
                guard project.entryURL.standardizedFileURL.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() else {
                    throw WallpaperEngineError.invalid("The selected file is not the wallpaper entry declared in project.json. Choose that entry or the project folder instead.")
                }
                return folder
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        throw WallpaperEngineError.invalid("No Wallpaper Engine project.json was found beside this file or in its enclosing folders. Choose the downloaded project folder. For a standalone video, use Choose video or image instead.")
    }
    public static func relativePath(_ path: String, in root: URL, mustExist: Bool = true) throws -> String {
        let path = path.replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"), !path.split(separator: "/").contains("..") else {
            throw WallpaperEngineError.invalid("An asset path leaves the project folder: \(path)")
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard target.path.hasPrefix(base.path + "/"), (!mustExist || (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true) else {
            throw WallpaperEngineError.invalid("An asset is missing or outside the project: \(path)")
        }
        return target.path.dropFirst(base.path.count + 1).description
    }
    private func metadata(_ root: URL) throws -> [String: ProjectValue] {
        let path = try Self.relativePath("project.json", in: root)
        do { return try JSONDecoder().decode([String: ProjectValue].self, from: Data(contentsOf: root.appendingPathComponent(path))) }
        catch { throw WallpaperEngineError.invalid("Invalid project.json: \(error.localizedDescription)") }
    }
    private func parse(_ root: URL) throws -> WallpaperEngineProject {
        let meta = try metadata(root)
        guard let type = WallpaperEngineType(rawValue: meta["type"]?.string?.lowercased() ?? "") else {
            throw WallpaperEngineError.invalid("Unsupported wallpaper type: \(meta["type"]?.string ?? "unknown"). Only Video and Web can be imported.")
        }
        let entry = try Self.relativePath(meta["file"]?.string ?? "", in: root)
        let ext = URL(fileURLWithPath: entry).pathExtension.lowercased()
        guard type == .web ? Self.webExtensions.contains(ext) : Self.videoExtensions.contains(ext) else {
            throw WallpaperEngineError.invalid("The entry file is not a supported \(type.rawValue) file.")
        }
        var warnings: [String] = []
        var preview: String?
        if let path = meta["preview"]?.string, !path.isEmpty {
            preview = try Self.relativePath(path, in: root)
        }
        let definitions: [String: ProjectValue] = meta["general"]?.object?["properties"]?.object ?? [:]
        let unsorted: [WallpaperEngineProperty] = definitions.map {
            WallpaperEngineProperty(id: $0.key, definition: $0.value.object ?? [:])
        }
        let properties = unsorted.sorted { a, b in a.order == b.order ? a.id < b.id : a.order < b.order }
        if meta["supportsaudioprocessing"]?.bool == true { warnings.append("System-audio visualization is not supported.") }
        if type == .web {
            warnings.append("Web: offline assets only; Lock Screen uses a still frame. Music metadata, RGB integrations and web workers are unavailable.")
            if properties.contains(where: { !$0.editable }) { warnings.append("File/directory and unknown property editors are unavailable.") }
        }
        return .init(id: "", type: type, title: meta["title"]?.string ?? root.lastPathComponent,
                     description: meta["description"]?.string ?? "", rootPath: root.path, entryPath: entry,
                     previewPath: preview, properties: properties, warnings: warnings, importedAt: Date())
    }
    public func importProject(at source: URL, cancelled: () -> Bool = { false }) throws -> WallpaperEngineProject {
        lock.lock(); defer { lock.unlock() }
        let manager = FileManager.default
        let root = try projectRoot(for: source)
        var project = try parse(root)
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey], options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw WallpaperEngineError.invalid("Could not read the project folder.")
        }
        var files: [(String, URL)] = []
        for case let url as URL in enumerator {
            if cancelled() { throw CancellationError() }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true else { throw WallpaperEngineError.invalid("Symlinks are not supported in imported projects: \(url.lastPathComponent)") }
            if values.isRegularFile == true {
                // Foundation's enumerator may expand /var to /private/var
                // while URL.path on the selected folder abbreviates it.
                let normalized = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard normalized.hasPrefix(root.path + "/") else { throw WallpaperEngineError.invalid("An asset leaves the project folder.") }
                let path = String(normalized.dropFirst(root.path.count + 1))
                _ = try Self.relativePath(path, in: root)
                files.append((path, url))
                guard files.count <= 20_000 else { throw WallpaperEngineError.invalid("Project has too many files (maximum 20,000).") }
            } else if values.isDirectory != true { throw WallpaperEngineError.invalid("Unsupported special file in the project.") }
        }
        if let enumerationError { throw enumerationError }
        try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let stage = rootURL.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: stage) }
        var hash = SHA256()
        for (path, url) in files.sorted(by: { $0.0 < $1.0 }) {
            if cancelled() { throw CancellationError() }
            hash.update(data: Data(path.utf8)); hash.update(data: Data([0]))
            let destination = stage.appendingPathComponent(path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.createFile(atPath: destination.path, contents: nil) else { throw WallpaperEngineError.invalid("Cannot copy an asset into the library.") }
            let input = try FileHandle(forReadingFrom: url)
            let output = try FileHandle(forWritingTo: destination)
            defer { try? input.close(); try? output.close() }
            var length: UInt64 = 0
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                if cancelled() { throw CancellationError() }
                length += UInt64(data.count); hash.update(data: data); try output.write(contentsOf: data)
            }
            hash.update(data: Data(String(length).utf8)); hash.update(data: Data([0]))
        }
        project = try parse(stage)
        project.id = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let manifest = rootURL.appendingPathComponent("library.json")
        let libraryData = manager.fileExists(atPath: manifest.path) ? try Data(contentsOf: manifest) : nil
        var library = try libraryData.map { try JSONDecoder().decode([WallpaperEngineProject].self, from: $0) } ?? []
        if let existing = library.first(where: { $0.id == project.id }), manager.fileExists(atPath: existing.entryURL.path) { return existing }
        let destination = rootURL.appendingPathComponent(project.id, isDirectory: true)
        // Recover an interrupted import only inside our explicitly owned hash directory.
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.moveItem(at: stage, to: destination)
        project.rootPath = destination.path
        library.removeAll { $0.id == project.id }; library.insert(project, at: 0)
        do {
            if cancelled() { throw CancellationError() }
            try JSONEncoder().encode(library).write(to: rootURL.appendingPathComponent("library.json"), options: .atomic)
        } catch { try? manager.removeItem(at: destination); throw error }
        return project
    }
    public func values(for project: WallpaperEngineProject) -> [String: ProjectValue] {
        lock.lock(); defer { lock.unlock() }
        let saved = (try? JSONDecoder().decode([String: ProjectValue].self, from: Data(contentsOf: rootURL.appendingPathComponent(project.id + "-properties.json")))) ?? [:]
        return Dictionary(uniqueKeysWithValues: project.properties.map { property in
            (property.id, property.validated(saved[property.id] ?? property.defaultValue))
        })
    }
    public func saveValues(_ values: [String: ProjectValue], for project: WallpaperEngineProject) throws {
        lock.lock(); defer { lock.unlock() }
        let valid = Dictionary(uniqueKeysWithValues: project.properties.map { ($0.id, $0.validated(values[$0.id] ?? $0.defaultValue)) })
        try JSONEncoder().encode(valid).write(to: rootURL.appendingPathComponent(project.id + "-properties.json"), options: .atomic)
    }
}
