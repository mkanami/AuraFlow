import Foundation

/// Finds local Steam content without downloading anything or scanning entire disks.
public enum WallpaperEngineImportLocation {
    public static func defaultSteamRoots(fileManager: FileManager = .default) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        var roots = [home.appendingPathComponent("Library/Application Support/Steam"),
                     home.appendingPathComponent(".steam/steam"),
                     home.appendingPathComponent(".local/share/Steam")]
        let volumes = (try? fileManager.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for volume in volumes {
            roots.append(volume)
            // Bounded checks for common external/Windows Steam installations.
            for path in ["SteamLibrary", "Steam", "Program Files (x86)/Steam", "Program Files/Steam"] {
                roots.append(volume.appendingPathComponent(path))
            }
        }
        let bottles = home.appendingPathComponent("Library/Application Support/CrossOver/Bottles")
        let prefixes = [home.appendingPathComponent(".wine")]
            + ((try? fileManager.contentsOfDirectory(at: bottles, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? [])
        for prefix in prefixes {
            for path in ["drive_c/Program Files (x86)/Steam", "drive_c/Program Files/Steam"] {
                roots.append(prefix.appendingPathComponent(path))
            }
        }
        return roots
    }

    public static func steamLibraries(steamRoots: [URL], fileManager: FileManager = .default) -> [URL] {
        var libraries = [URL]()
        var seen = Set<String>()
        func append(_ url: URL) {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if seen.insert(canonical.path).inserted { libraries.append(canonical) }
        }
        steamRoots.forEach(append)
        var index = 0
        while index < libraries.count {
            let root = libraries[index]; index += 1
            for relative in ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"] {
                let manifest = root.appendingPathComponent(relative)
                // A malformed or inaccessible Steam manifest must not block manual import.
                guard let size = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 1_048_576,
                      let data = try? Data(contentsOf: manifest),
                      let text = String(data: data, encoding: .utf8) else { continue }
                for path in libraryPaths(in: text) {
                    if path.hasPrefix("/") { append(URL(fileURLWithPath: path)) }
                    else {
                        // A Windows library manifest on a mounted disk uses drive letters.
                        // Resolve only against detected volume roots, never arbitrary paths.
                        let normalized = path.replacingOccurrences(of: "\\", with: "/")
                        guard normalized.count >= 3, normalized.dropFirst().hasPrefix(":/"),
                              !normalized.split(separator: "/").contains("..") else { continue }
                        let relative = String(normalized.dropFirst(3))
                        guard !relative.hasPrefix("/") else { continue }
                        var driveRoots = steamRoots.filter { $0.deletingLastPathComponent().path == "/Volumes" }
                        for source in steamRoots {
                            if let range = source.path.range(of: "/drive_c/") {
                                let prefix = URL(fileURLWithPath: String(source.path[..<range.lowerBound]))
                                let drive = String(normalized.prefix(1)).lowercased()
                                driveRoots.append(prefix.appendingPathComponent("drive_" + drive))
                                driveRoots.append(prefix.appendingPathComponent("dosdevices/" + drive + ":"))
                            }
                        }
                        for driveRoot in driveRoots {
                            let candidate = driveRoot.appendingPathComponent(relative)
                            if fileManager.fileExists(atPath: candidate.appendingPathComponent("steamapps").path) { append(candidate) }
                        }
                    }
                }
            }
        }
        return libraries
    }

    public static func preferredDirectory(steamRoots: [URL], lastDirectory: URL? = nil,
                                          fileManager: FileManager = .default) -> URL? {
        let libraries = steamLibraries(steamRoots: steamRoots, fileManager: fileManager)
        func isDirectory(_ url: URL) -> Bool {
            var directory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
        }
        for library in libraries {
            let workshop = library.appendingPathComponent("steamapps/workshop/content/431960")
            if isDirectory(workshop) { return workshop }
        }
        for library in libraries {
            let authored = library.appendingPathComponent("steamapps/common/wallpaper_engine/projects/myprojects")
            if isDirectory(authored) { return authored }
        }
        if let lastDirectory, isDirectory(lastDirectory) { return lastDirectory }
        // Without downloaded WE content, start in Steam's library rather than an arbitrary folder.
        return libraries.map { $0.appendingPathComponent("steamapps") }.first(where: isDirectory)
    }

    /// Read both modern { "path" "…" } and legacy numeric-library VDF entries.
    /// Parse the structure so comments, app IDs and unrelated "path" fields aren't mistaken for libraries.
    public static func libraryPaths(in text: String) -> [String] {
        guard text.utf8.count <= 1_048_576 else { return [] }
        var parser = VDFParser(text)
        guard let root = parser.object(), parser.atEnd,
              case .object(let libraries)? = root.first(where: { $0.0.lowercased() == "libraryfolders" })?.1 else { return [] }
        return libraries.compactMap { key, value in
            guard Int(key) != nil else { return nil }
            switch value {
            case .string(let path): return path
            case .object(let entry):
                guard case .string(let path)? = entry.first(where: { $0.0.lowercased() == "path" })?.1 else { return nil }
                return path
            }
        }
    }
}

private indirect enum VDFValue {
    case string(String)
    case object([(String, VDFValue)])
}

private struct VDFParser {
    let characters: [Character]
    var index = 0
    var entries = 0
    init(_ text: String) { characters = Array(text) }
    var atEnd: Bool { mutating get { skipWhitespace(); return index == characters.count } }

    mutating func skipWhitespace() {
        while index < characters.count {
            if characters[index].isWhitespace { index += 1 }
            else if characters[index] == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else { break }
        }
    }
    mutating func token() -> String? {
        skipWhitespace()
        guard index < characters.count, characters[index] != "{", characters[index] != "}" else { return nil }
        var value = ""
        if characters[index] == "\"" {
            index += 1
            while index < characters.count {
                let character = characters[index]; index += 1
                if character == "\"" { return value }
                if character == "\\", index < characters.count,
                   characters[index] == "\\" || characters[index] == "\"" {
                    value.append(characters[index]); index += 1
                } else { value.append(character) }
            }
            return nil
        }
        while index < characters.count, !characters[index].isWhitespace,
              characters[index] != "{", characters[index] != "}" {
            value.append(characters[index]); index += 1
        }
        return value.isEmpty ? nil : value
    }
    mutating func object(depth: Int = 0) -> [(String, VDFValue)]? {
        guard depth < 16 else { return nil }
        var result = [(String, VDFValue)]()
        while true {
            skipWhitespace()
            if index == characters.count { return depth == 0 ? result : nil }
            if characters[index] == "}" {
                guard depth > 0 else { return nil }
                index += 1; return result
            }
            guard let key = token() else { return nil }
            entries += 1; guard entries <= 20_000 else { return nil }
            skipWhitespace()
            if index < characters.count, characters[index] == "{" {
                index += 1
                guard let nested = object(depth: depth + 1) else { return nil }
                result.append((key, .object(nested)))
            } else {
                guard let value = token() else { return nil }
                result.append((key, .string(value)))
            }
        }
    }
}
